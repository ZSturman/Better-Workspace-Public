"""v1's own Notion Projects cache, against ``events.db`` -- unrelated to the
Work Log Notion-sync pipeline (see ``notion_cache_v2.py``/``work_logs_v2.py``
for that). Still live: `./run.sh activity notion-refresh` and the menu bar
app's status display both use ``NotionProjectCache`` below to mirror
priority/status/current-work fields from the existing Notion Projects
database into local project rows, for v1's nudge/priority-alignment
features. The low-level Notion client/credential bridge this reuses lives in
``notion_client_v2.py`` -- shared, not duplicated.
"""

from __future__ import annotations

import json
import time
from pathlib import Path
from typing import Any, Iterable

from .config import NotionSettings
from .notion_client_v2 import ExistingProjectsAdapter, NotionCacheError, _lookup, _normalized_path, _property_value, credential_token
from .store import WorkspaceStore

__all__ = [
    "NotionCacheError", "credential_token", "ExistingProjectsAdapter", "NotionProjectCache",
]

STATE_LAST_ATTEMPT = "intelligence.notion.last_attempt"
STATE_LAST_SUCCESS = "intelligence.notion.last_success"
STATE_LAST_ERROR = "intelligence.notion.last_error"


def _strings(value: Any) -> list[str]:
    if isinstance(value, list):
        items = value
    elif value is None:
        return []
    else:
        items = str(value).replace(";", "\n").replace(",", "\n").splitlines()
    return [str(item).strip().strip("'\"‘’“”") for item in items if str(item).strip()]


class NotionProjectCache:
    def __init__(self, store: WorkspaceStore, workspace_root: Path, settings: NotionSettings) -> None:
        self.store = store
        self.workspace_root = workspace_root
        self.settings = settings

    def is_due(self, now: float) -> bool:
        if not self.settings.enabled:
            return False
        last_attempt = self.store.get_state(STATE_LAST_ATTEMPT)
        if not isinstance(last_attempt, (int, float)):
            return True
        return now - float(last_attempt) >= self.settings.refresh_minutes * 60

    def refresh_if_due(self, now: float | None = None) -> dict[str, Any] | None:
        current = time.time() if now is None else now
        return self.refresh(current) if self.is_due(current) else None

    def refresh(self, now: float | None = None) -> dict[str, Any]:
        current = time.time() if now is None else now
        self.store.set_state(STATE_LAST_ATTEMPT, current)
        if not self.settings.enabled:
            return {"ok": False, "skipped": True, "reason": "notion_disabled"}
        try:
            pages = ExistingProjectsAdapter(self.workspace_root, self.settings).fetch_projects()
            records = self._records_with_local_mapping(pages)
            self.store.replace_notion_project_cache(records, current)
            self.store.set_state(STATE_LAST_SUCCESS, current)
            self.store.set_state(STATE_LAST_ERROR, None)
            return {"ok": True, "projects": len(records), "refreshed_at": current}
        except NotionCacheError as exc:
            self.store.set_state(STATE_LAST_ERROR, str(exc))
            return {"ok": False, "projects": len(self.store.cached_notion_projects()), "error": str(exc)}

    def status(self) -> dict[str, Any]:
        return {
            "enabled": self.settings.enabled,
            "cached_projects": len(self.store.cached_notion_projects()),
            "last_attempt": self.store.get_state(STATE_LAST_ATTEMPT),
            "last_success": self.store.get_state(STATE_LAST_SUCCESS),
            "last_error": self.store.get_state(STATE_LAST_ERROR),
        }

    def remap_local_projects(self) -> int:
        """Update local ID/path links without a Notion request.

        Project directories may be discovered after a successful cache refresh;
        their mapping should become usable immediately rather than waiting for
        another remote polling interval.
        """
        local_projects = list(self.store.all_projects(status=None))
        updated = 0
        for row in self.store.cached_notion_projects():
            metadata = _json_object(row["metadata_json"])
            local, reason = self._match_local_project(
                str(row["name"]), str(metadata.get("local_directory") or ""),
                [*_strings(metadata.get("path_prefixes")), *_strings(metadata.get("workspace_roots"))], local_projects,
            )
            local_id = local["project_id"] if local else None
            local_path = local["path"] if local else None
            if local_id == row["local_project_id"] and local_path == row["local_path"]:
                continue
            metadata["mapping_reason"] = reason
            self.store.update_notion_project_mapping(row["notion_project_id"], local_id, local_path, metadata)
            updated += 1
        return updated

    def _records_with_local_mapping(self, pages: Iterable[dict[str, Any]]) -> list[dict[str, Any]]:
        local_projects = list(self.store.all_projects(status=None))
        records: list[dict[str, Any]] = []
        for page in pages:
            properties = page.get("properties") if isinstance(page.get("properties"), dict) else {}
            name = str(_lookup(properties, "Name", "title") or "").strip()
            page_id = str(page.get("id") or "")
            if not page_id or not name:
                continue
            local_directory = str(_lookup(properties, "Local Directory") or "").strip()
            paths = _strings(_lookup(properties, "path prefixes"))
            workspace_roots = _strings(_lookup(properties, "workspace roots"))
            local, mapping_reason = self._match_local_project(
                name, local_directory, [*paths, *workspace_roots], local_projects
            )
            priority = _number(_lookup(properties, "tracking priority", "action severity", "asset action severity"))
            scores = {
                key: value for key, value in {
                    "tracking_priority": _number(_lookup(properties, "tracking priority")),
                    "action_severity": _number(_lookup(properties, "action severity")),
                    "asset_action_severity": _number(_lookup(properties, "asset action severity")),
                }.items() if value is not None
            }
            records.append({
                "notion_project_id": page_id,
                "local_project_id": local["project_id"] if local else None,
                "local_path": local["path"] if local else None,
                "name": name,
                "status": _lookup(properties, "Status"),
                "priority": priority,
                "current_work": _strings(_lookup(properties, "Current Work")),
                "recent_work": _strings(_lookup(properties, "Recent Work")),
                "next_work": _strings(_lookup(properties, "Next Work")),
                "scores": scores,
                "metadata": {
                    "local_directory": local_directory,
                    "path_prefixes": paths,
                    "workspace_roots": workspace_roots,
                    "project_slug": _lookup(properties, "project slug"),
                    "work_mode": _strings(_lookup(properties, "Work Mode")),
                    "status_details": _lookup(properties, "status details"),
                    "tracking_enabled": _lookup(properties, "tracking enabled"),
                    "mapping_reason": mapping_reason,
                },
            })
        return records

    def _match_local_project(
        self, name: str, local_directory: str, hints: list[str], local_projects: list[Any]
    ) -> tuple[Any | None, str | None]:
        candidates = [value for value in [local_directory, *hints] if value]
        for candidate in candidates:
            candidate_paths = [_normalized_path(candidate)]
            if not Path(candidate).expanduser().is_absolute():
                candidate_paths.append(_normalized_path(str(self.workspace_root / candidate)))
            for project in local_projects:
                project_path = _normalized_path(str(self.workspace_root / project["path"]))
                if project_path in candidate_paths:
                    return project, "notion_local_path"
        normalized_name = name.casefold().strip()
        matching = [project for project in local_projects if str(project["name"]).casefold().strip() == normalized_name]
        return (matching[0], "project_name") if len(matching) == 1 else (None, None)


def _number(value: Any) -> float | None:
    if isinstance(value, bool) or value in (None, ""):
        return None
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def _json_object(value: Any) -> dict[str, Any]:
    try:
        parsed = json.loads(value or "{}")
    except (TypeError, ValueError):
        return {}
    return parsed if isinstance(parsed, dict) else {}
