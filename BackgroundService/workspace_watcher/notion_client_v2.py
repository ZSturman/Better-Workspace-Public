"""The one shared, low-level Notion glue layer: credential loading, the
bridge to the Notion HTTP client (``notion_api``), and generic property-value
decoding. There is one Notion HTTP client in this codebase, and this is the
only bridge to it.

v2-owned so v2's own modules (`notion_cache_v2.py`, `work_logs_v2.py`,
`reconciliation_v2.py`) never need to import anything from a v1-named
module. `notion_cache.py` (v1's own, separate-purpose project cache, still
live via `./run.sh activity notion-refresh` and the menu bar app) imports
these from here too, rather than v2 depending on v1.
"""

from __future__ import annotations

import os
from pathlib import Path
from typing import Any

# Deliberately untyped to a specific NotionSettings class: v1's own
# config.NotionSettings (still used by notion_cache.py's NotionProjectCache)
# and v2's core_config.NotionSettings are structurally identical for every
# field this module reads (token_env, env_file, timeout_seconds,
# projects_database_id) but are two distinct dataclasses.
# This module is genuinely shared by both -- accepting either via duck
# typing here, rather than importing one and pretending it's the only
# caller, is the honest description of what's actually going on.


class NotionCacheError(RuntimeError):
    """A recoverable integration error, safe to display without a token."""


def _project_root() -> Path:
    """Directory containing this project's ``config.toml`` and ``.env``."""
    return Path(__file__).resolve().parents[1]


def _dotenv_token(path: Path, key: str) -> str:
    """Read one conventional ``KEY=value`` entry without evaluating a shell.

    This intentionally supports only the small, predictable subset needed for
    a local secret file. It never mutates ``os.environ`` and never logs the
    value. The process environment remains the preferred deployment path.
    """
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except FileNotFoundError:
        return ""
    except OSError as exc:
        raise NotionCacheError(f"Could not read Notion credential file {path}: {exc}") from exc

    for raw_line in lines:
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[7:].lstrip()
        name, separator, value = line.partition("=")
        if separator != "=" or name.strip() != key:
            continue
        value = value.strip()
        if len(value) >= 2 and value[:1] == value[-1:] and value[:1] in {"'", '"'}:
            value = value[1:-1]
        return value
    return ""


def credential_token(settings: Any) -> str:
    """Return the configured Notion token without ever exposing it in output."""
    from_environment = os.environ.get(settings.token_env, "").strip()
    if from_environment:
        return from_environment
    env_file = Path(settings.env_file).expanduser()
    if not env_file.is_absolute():
        env_file = _project_root() / env_file
    return _dotenv_token(env_file, settings.token_env).strip()


def _normalized_path(value: str) -> str:
    return os.path.normcase(os.path.realpath(os.path.expanduser(value)))


def _property_value(raw: Any) -> Any:
    """Read the scalar/list value already returned in a Notion page property."""
    if not isinstance(raw, dict):
        return None
    kind = raw.get("type")
    if kind in {"title", "rich_text"}:
        return "".join(
            str(item.get("plain_text") or item.get("text", {}).get("content") or "")
            for item in raw.get(kind) or []
            if isinstance(item, dict)
        )
    if kind in {"select", "status"}:
        item = raw.get(kind) or {}
        return item.get("name") if isinstance(item, dict) else None
    if kind == "multi_select":
        return [str(item.get("name") or "") for item in raw.get(kind) or [] if isinstance(item, dict) and item.get("name")]
    if kind in {"number", "checkbox", "url", "email", "phone_number"}:
        return raw.get(kind)
    if kind == "date":
        value = raw.get("date") or {}
        return value.get("start") if isinstance(value, dict) else None
    if kind == "formula":
        return _property_value(raw.get("formula"))
    if kind == "rollup":
        value = raw.get("rollup") or {}
        rollup_kind = value.get("type") if isinstance(value, dict) else None
        if rollup_kind == "array":
            return [_property_value(item) for item in value.get("array") or []]
        return value.get(rollup_kind) if isinstance(value, dict) else None
    if kind == "relation":
        return [str(item.get("id")) for item in raw.get("relation") or [] if isinstance(item, dict) and item.get("id")]
    return None


def _lookup(properties: dict[str, Any], *names: str) -> Any:
    desired = {name.casefold() for name in names}
    for name, raw in properties.items():
        if str(name).casefold() in desired:
            return _property_value(raw)
    return None


class ExistingProjectsAdapter:
    """Thin bridge to the Notion client (``notion_api``, moved in from Task Management)."""

    def __init__(self, workspace_root: Path, settings: Any) -> None:
        self.workspace_root = workspace_root
        self.settings = settings

    def _client(self) -> Any:
        token = credential_token(self.settings)
        if not token:
            raise NotionCacheError(
                f"Notion is enabled but {self.settings.token_env} is unavailable. "
                f"Set it in the service environment or in {self.settings.env_file}; using the existing local cache."
            )
        from .notion_api import NotionClient
        return NotionClient(token, timeout_seconds=self.settings.timeout_seconds)

    def fetch_projects(self) -> list[dict[str, Any]]:
        client = self._client()
        try:
            source_id = client.data_source_id(self.settings.projects_database_id)
            return client.query(source_id, limit=500)
        except Exception as exc:  # noqa: BLE001 - preserve cache on any remote failure
            raise NotionCacheError(f"Projects refresh failed: {exc}") from exc

    def create_project(self, *, name: str, local_directory: str) -> dict[str, Any]:
        """Create one explicitly requested Projects page using the live schema.

        The Projects database is user-owned and its property names may evolve,
        so resolve the title and optional Local Directory fields from the
        data-source metadata rather than baking an assumed schema into the
        Workspace Watcher UI.
        """
        client = self._client()
        try:
            from .notion_api import property_value

            source_id = client.data_source_id(self.settings.projects_database_id)
            source = client.data_source(source_id)
            schema = source.get("properties") if isinstance(source.get("properties"), dict) else {}
            title_name = next((field for field, definition in schema.items()
                               if isinstance(definition, dict) and definition.get("type") == "title"), None)
            if not title_name:
                raise NotionCacheError("The configured Notion Projects data source has no title property.")

            properties = {title_name: property_value("title", name)}
            local_directory_name = next((field for field, definition in schema.items()
                                         if str(field).casefold() == "local directory"
                                         and isinstance(definition, dict)
                                         and definition.get("type") == "rich_text"), None)
            if local_directory_name:
                properties[local_directory_name] = property_value("rich_text", local_directory)
            return client.create_page(source_id, properties)
        except NotionCacheError:
            raise
        except Exception as exc:  # noqa: BLE001 - preserve a safe public error boundary
            raise NotionCacheError(f"Could not create the Notion project: {exc}") from exc
