"""The Notion HTTP client and property helpers the background service uses.

Moved here on 2026-09-30 from the separate Task Management project
(`src/task_management/notion.py` and `schema.py`, last modified 2026-09-12;
SHA-256 prefixes 1dd90dce222f3ff4 and f5deb1cea07699cb), which the service used to
load at runtime by putting that checkout on `sys.path` (`client_source`). Only what
the service calls came across: the client, property encoding/decoding, and the
alias-based schema lookup. The code is unchanged; Task Management's task planner,
workflow and models stayed behind. Standard library only.
"""

from __future__ import annotations

import json
import time
from dataclasses import dataclass
from typing import Any, Iterable
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import Request, urlopen


NOTION_VERSION = "2026-03-11"
MAX_TEXT_CHUNK = 1900


class NotionError(RuntimeError):
    pass


class NotionClient:
    def __init__(self, token: str, *, base_url: str = "https://api.notion.com/v1", timeout_seconds: int = 30) -> None:
        self.base_url = base_url.rstrip("/")
        self.timeout_seconds = timeout_seconds
        self.headers = {
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
            "Notion-Version": NOTION_VERSION,
        }
        self._next_request_at = 0.0

    def _request(self, method: str, path: str, payload: dict[str, Any] | None = None, *, params: dict[str, Any] | None = None) -> dict[str, Any]:
        suffix = f"?{urlencode(params)}" if params else ""
        body = json.dumps(payload).encode("utf-8") if payload is not None else None
        request = Request(f"{self.base_url}{path}{suffix}", data=body, headers=self.headers, method=method)
        last_error: Exception | None = None
        for attempt in range(4):
            try:
                delay = self._next_request_at - time.monotonic()
                if delay > 0:
                    time.sleep(delay)
                self._next_request_at = time.monotonic() + 0.35
                with urlopen(request, timeout=self.timeout_seconds) as response:
                    return json.loads(response.read().decode("utf-8"))
            except HTTPError as exc:
                detail = exc.read().decode("utf-8", errors="replace")[:500]
                last_error = NotionError(f"Notion HTTP {exc.code}: {detail}")
                if exc.code not in {429, 500, 502, 503, 504}:
                    break
            except (URLError, TimeoutError, json.JSONDecodeError) as exc:
                last_error = NotionError(f"Notion request failed: {exc}")
            time.sleep(min(4.0, 0.5 * (2**attempt)))
        raise last_error or NotionError("Notion request failed.")

    def database(self, database_id: str) -> dict[str, Any]:
        return self._request("GET", f"/databases/{database_id}")

    def data_source_id(self, database_or_source_id: str) -> str:
        try:
            self.data_source(database_or_source_id)
            return database_or_source_id
        except NotionError:
            database = self.database(database_or_source_id)
            sources = database.get("data_sources") or []
            source_id = str((sources[0] if sources else {}).get("id") or "")
            if not source_id:
                raise NotionError("The Notion database has no accessible data source.")
            return source_id

    def data_source(self, source_id: str) -> dict[str, Any]:
        return self._request("GET", f"/data_sources/{source_id}")

    def update_data_source(self, source_id: str, properties: dict[str, Any]) -> dict[str, Any]:
        return self._request("PATCH", f"/data_sources/{source_id}", {"properties": properties})

    def query(self, source_id: str, *, filter_payload: dict[str, Any] | None = None, sorts: list[dict[str, Any]] | None = None, limit: int = 200) -> list[dict[str, Any]]:
        rows: list[dict[str, Any]] = []
        cursor: str | None = None
        while len(rows) < limit:
            payload: dict[str, Any] = {"page_size": min(100, limit - len(rows))}
            if filter_payload:
                payload["filter"] = filter_payload
            if sorts:
                payload["sorts"] = sorts
            if cursor:
                payload["start_cursor"] = cursor
            response = self._request("POST", f"/data_sources/{source_id}/query", payload)
            rows.extend(item for item in response.get("results", []) if isinstance(item, dict))
            cursor = str(response.get("next_cursor") or "") or None
            if not response.get("has_more") or not cursor:
                break
        return rows[:limit]

    def page(self, page_id: str) -> dict[str, Any]:
        return self._request("GET", f"/pages/{page_id}")

    def update_page(self, page_id: str, properties: dict[str, Any]) -> dict[str, Any]:
        return self._request("PATCH", f"/pages/{page_id}", {"properties": properties})

    def create_page(self, source_id: str, properties: dict[str, Any], *, children: list[dict[str, Any]] | None = None) -> dict[str, Any]:
        payload: dict[str, Any] = {
            "parent": {"type": "data_source_id", "data_source_id": source_id},
            "properties": properties,
        }
        if children:
            payload["children"] = children
        return self._request("POST", "/pages", payload)

    def block_children(self, block_id: str, *, limit: int = 100) -> list[dict[str, Any]]:
        rows: list[dict[str, Any]] = []
        cursor: str | None = None
        while len(rows) < limit:
            params: dict[str, Any] = {"page_size": min(100, limit - len(rows))}
            if cursor:
                params["start_cursor"] = cursor
            response = self._request("GET", f"/blocks/{block_id}/children", params=params)
            rows.extend(item for item in response.get("results", []) if isinstance(item, dict))
            cursor = str(response.get("next_cursor") or "") or None
            if not response.get("has_more") or not cursor:
                break
        return rows[:limit]


def rich_text(value: str) -> list[dict[str, Any]]:
    return [{"type": "text", "text": {"content": value[i : i + MAX_TEXT_CHUNK]}} for i in range(0, len(value), MAX_TEXT_CHUNK)] or []


def property_value(kind: str, value: Any) -> dict[str, Any]:
    if kind == "title":
        return {"title": rich_text(str(value))}
    if kind == "rich_text":
        return {"rich_text": rich_text(str(value))}
    if kind in {"select", "status"}:
        return {kind: {"name": str(value)} if value else None}
    if kind == "checkbox":
        return {"checkbox": bool(value)}
    if kind == "date":
        return {"date": {"start": str(value)} if value else None}
    if kind == "relation":
        return {"relation": [{"id": str(item)} for item in value]}
    if kind == "multi_select":
        return {"multi_select": [{"name": str(item)} for item in value]}
    if kind == "number":
        return {"number": value}
    raise ValueError(f"Unsupported writable Notion type: {kind}")


def _text(parts: Any) -> str:
    if not isinstance(parts, list):
        return ""
    return "".join(str(item.get("plain_text") or item.get("text", {}).get("content") or "") for item in parts if isinstance(item, dict))


def decode_property(raw: dict[str, Any] | None) -> Any:
    if not raw:
        return None
    kind = raw.get("type")
    if kind in {"title", "rich_text"}:
        return _text(raw.get(kind))
    if kind in {"select", "status"}:
        value = raw.get(kind) or {}
        return value.get("name") if isinstance(value, dict) else None
    if kind == "checkbox":
        return bool(raw.get("checkbox"))
    if kind == "relation":
        return tuple(str(item.get("id")) for item in raw.get("relation", []) if isinstance(item, dict) and item.get("id"))
    if kind == "date":
        value = raw.get("date") or {}
        return value.get("start") if isinstance(value, dict) else None
    if kind == "number":
        return raw.get("number")
    return None


def page_property(page: dict[str, Any], name: str | None) -> dict[str, Any] | None:
    if not name:
        return None
    properties = page.get("properties") or {}
    value = properties.get(name)
    return value if isinstance(value, dict) else None


# --- From task_management/schema.py ---------------------------------------

def _normal(value: str) -> str:
    return "".join(character for character in value.casefold() if character.isalnum())


@dataclass(frozen=True)
class PropertyRef:
    name: str
    kind: str
    raw: dict[str, Any]

    @property
    def options(self) -> tuple[str, ...]:
        config = self.raw.get(self.kind)
        if not isinstance(config, dict):
            return ()
        return tuple(str(item.get("name")) for item in config.get("options", []) if isinstance(item, dict) and item.get("name"))


class SchemaMap:
    def __init__(self, source: dict[str, Any]) -> None:
        self.source = source
        self.properties: dict[str, PropertyRef] = {}
        for name, raw in (source.get("properties") or {}).items():
            if isinstance(raw, dict) and raw.get("type"):
                self.properties[str(name)] = PropertyRef(str(name), str(raw["type"]), raw)

    def find(self, aliases: Iterable[str], kinds: Iterable[str] = ()) -> PropertyRef | None:
        expected = set(kinds)
        normalized = {_normal(alias) for alias in aliases}
        matches = [value for name, value in self.properties.items() if _normal(name) in normalized]
        if expected:
            typed = [value for value in matches if value.kind in expected]
            if typed:
                return typed[0]
        return matches[0] if matches else None

    def title(self) -> PropertyRef | None:
        return next((property_ref for property_ref in self.properties.values() if property_ref.kind == "title"), None)
