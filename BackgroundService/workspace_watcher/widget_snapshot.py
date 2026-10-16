"""A compact, read-only projection for the native WidgetKit extension.

The extension intentionally never opens the Workspace Watcher SQLite database
or starts Python. The runtime creates this cache atomically after semantic
changes and serves it through the existing versioned localhost API.
"""

from __future__ import annotations

import hashlib
import json
import os
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from .core_store import CoreStore
from .project_model_v2 import build_project_views
from .session_telemetry_v2 import live_session_view


SCHEMA_VERSION = 1
SNAPSHOT_FILENAME = "widget-snapshot.json"


def default_snapshot_path(database_path: Path | None = None) -> Path:
    """Return the runtime-owned cache path, with a test override.

    A signed App Group is intentionally not the producer boundary: macOS
    blocks an unsandboxed Python daemon from writing there. The WidgetKit
    extension obtains this small cache through `/v1/widgets/snapshot`.
    """
    override = os.environ.get("WORKSPACE_WATCHER_WIDGET_SNAPSHOT_PATH")
    if override:
        return Path(override).expanduser()
    return (database_path.parent if database_path else Path.cwd()) / SNAPSHOT_FILENAME


def _iso_today() -> str:
    return datetime.now(timezone.utc).date().isoformat()


def _health(store: CoreStore) -> dict[str, Any]:
    keys = ("watcher.health", "rules.health", "hammerspoon_inbox.health", "notion_projects.health", "work_logs.health", "lm_studio.health")
    states = {key.removesuffix(".health"): store.get_state(key) for key in keys}
    problems = [
        {"component": component, "state": value.get("state", "unknown"), "error": value.get("error")}
        for component, value in states.items()
        if value and value.get("state") in {"error", "invalid", "stopped"}
    ]
    return {"watcher_state": (states["watcher"] or {}).get("state", "unknown"), "problems": problems}


def _by_recent_activity(projects: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Most recently worked on first, never-touched last.

    Every widget reads this list in order and shows the front of it, so an
    unordered list is not a cosmetic problem: truncating 383 projects to 50
    without sorting meant "What Should I Work On?" answered with whatever came
    alphabetically first -- `_Articles`, `_Closed`, `A Brief History of
    Everything` -- none of which had ever been worked on.

    Recency is used rather than a blended score because it is the one thing
    actually measured for these projects (manual ratings and outcome facts are
    unknown for the entire portfolio), and because a single universal score is
    deliberately not part of this system.
    """
    def key(project: dict[str, Any]) -> tuple[int, float, str]:
        days = project.get("days_since_last_session")
        never = days is None
        return (1 if never else 0, float("inf") if never else float(days), str(project.get("name", "")).casefold())

    return sorted(projects, key=key)


def build_widget_snapshot(
    store: CoreStore,
    *,
    now: datetime | None = None,
    max_duration_minutes: float | None = None,
) -> dict[str, Any]:
    """Build a small, stable schema from existing authoritative read models."""
    now = now or datetime.now(timezone.utc)
    folders = list(store.folders())
    folder_names = {row["id"]: row["name"] for row in folders}
    items = list(store.items())
    projects = build_project_views(store, now=now)
    current_session = live_session_view(store, now=now, max_duration_minutes=max_duration_minutes)

    intent_rows = []
    for folder in folders:
        folder_items = [row for row in items if row["intent_folder_id"] == folder["id"] and row["status"] not in {"archived", "suppressed"}]
        folder_items.sort(key=lambda row: (str(row["updated_at"]), str(row["title"]).casefold()), reverse=True)
        intent_rows.append({
            "id": folder["id"], "name": folder["name"], "count": len(folder_items),
            "items": [{"id": row["id"], "title": row["title"], "status": row["status"], "updated_at": row["updated_at"]} for row in folder_items[:8]],
        })
    intent_rows.sort(key=lambda row: row["name"].casefold())

    resurfaced = []
    for row in store.conn.execute(
        """SELECT i.id, i.title, r.last_score, r.last_surfaced_at, r.last_reason_json
           FROM resurfacing_state r JOIN intent_items i ON i.id=r.item_id
           WHERE r.last_surfaced_at IS NOT NULL AND i.status NOT IN ('archived','suppressed')
           ORDER BY r.last_surfaced_at DESC, r.last_score DESC LIMIT 5"""
    ).fetchall():
        reason = json.loads(row["last_reason_json"] or "{}")
        resurfaced.append({
            "id": row["id"], "title": row["title"], "intent": reason.get("intent", ""),
            "score": row["last_score"], "surfaced_at": row["last_surfaced_at"],
            "why": "Relevant to the active project" if reason.get("active_project") else f"Resurfaced from [[{reason.get('intent', 'Workspace')}]]",
        })

    activity = []
    for row in store.recent_events(40):
        event_type = str(row["type"])
        if event_type == "schedule.tick" or event_type.startswith("filesystem."):
            continue
        payload = json.loads(row["payload_json"] or "{}")
        activity.append({"id": row["id"], "type": event_type, "at": row["occurred_at"], "project_id": row["entity_id"], "summary": _event_summary(event_type, payload, projects)})
        if len(activity) == 8:
            break

    today = _iso_today()
    today_sessions = [row for row in store.recent_sessions(limit=500) if str(row["ended_at"]).startswith(today) and row["status"] != "open"]
    return {
        "schema_version": SCHEMA_VERSION,
        "generated_at": now.isoformat(),
        "projects": _by_recent_activity(projects)[:50],
        "intents": intent_rows,
        "session": current_session,
        "resurfaced": resurfaced,
        "activity": activity,
        "today": {
            "session_count": len(today_sessions),
            "active_seconds": round(sum(float(row["active_seconds"]) for row in today_sessions)),
            "projects": sorted({str(row["project_name"]) for row in today_sessions}),
            "meaningful_events": sum(int(row["meaningful_event_count"]) for row in today_sessions),
        },
        "health": _health(store),
        "counts": {
            "projects": len(projects),
            "intent_items": sum(row["count"] for row in intent_rows),
            "attention_projects": sum(bool(row["needs_attention"]) for row in projects),
            # Two facts a portfolio overview can actually answer today: how
            # much of it saw real work this week, and how much is still
            # unfiled and therefore invisible to every organizational lens.
            "active_7d": sum(1 for row in projects if (row.get("days_since_last_session") is not None and row["days_since_last_session"] <= 7)),
            "unfiled_projects": sum(1 for row in projects if not row.get("domain")),
        },
        "intent_names": folder_names,
    }


def _event_summary(event_type: str, payload: dict[str, Any], projects: list[dict[str, Any]]) -> str:
    project = next((item["name"] for item in projects if item["id"] == payload.get("project_id")), None)
    labels = {
        "project.activated": "Project became active",
        "session.started": "Session started",
        "session.resumed": "Session resumed",
        "session.closed": "Session completed",
        "resurfacing.due": "Item resurfaced",
    }
    fallback = event_type.replace(".", " ").capitalize()
    return f"{project}: {labels.get(event_type, fallback)}" if project else labels.get(event_type, fallback)


class WidgetSnapshotPublisher:
    """Writes only when the projection materially changes, using replace()."""

    def __init__(
        self,
        path: Path | None = None,
        *,
        database_path: Path | None = None,
        max_duration_minutes: float | None = None,
    ) -> None:
        self.path = path or default_snapshot_path(database_path)
        self.max_duration_minutes = max_duration_minutes
        self._last_digest: str | None = None

    def publish(self, store: CoreStore, *, now: datetime | None = None) -> bool:
        snapshot = build_widget_snapshot(store, now=now, max_duration_minutes=self.max_duration_minutes)
        # `generated_at` should not cause a write/reload storm by itself.
        comparable = dict(snapshot)
        comparable.pop("generated_at", None)
        encoded_comparable = json.dumps(comparable, sort_keys=True, separators=(",", ":")).encode()
        digest = hashlib.sha256(encoded_comparable).hexdigest()
        if digest == self._last_digest and self.path.exists():
            return False
        try:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            temporary = self.path.with_suffix(".tmp")
            temporary.write_text(json.dumps(snapshot, sort_keys=True, separators=(",", ":")), encoding="utf-8")
            os.replace(temporary, self.path)
        except OSError:
            # Widgets are optional consumers: an unavailable cache location
            # must never interrupt filesystem sensing or session inference.
            return False
        self._last_digest = digest
        return True


def read_widget_snapshot(path: Path) -> dict[str, Any] | None:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None
    return payload if payload.get("schema_version") == SCHEMA_VERSION else None
