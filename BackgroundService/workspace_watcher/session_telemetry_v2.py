"""The live "what is Workspace Watcher observing right now" view -- the
data behind the during-a-session GUI screen, the menu-bar dropdown, and the
Control Center control. Deliberately curated, not a diagnostics dump:
useful "what's happening" facts (elapsed time, recent activity, detected
app context, current goals, rules that fired, notifications produced), not
every row in the event journal. `GET /v1/diagnostics` remains the place for
deep diagnostics; this is the place for a person mid-session to glance at.
"""

from __future__ import annotations

import json
from datetime import datetime, timezone
from typing import Any

from .core_store import CoreStore

# Hammerspoon inbox event types worth showing as "detected context" --
# coarse OS-level signals already ingested into the event journal (see
# hammerspoon_inbox.py) but never before surfaced anywhere in the app.
CONTEXT_EVENT_TYPES = ("hammerspoon.app_focused", "hammerspoon.idle_started", "hammerspoon.idle_ended", "hammerspoon.system_resumed")
TELEMETRY_WINDOW_EVENTS = 30


def _parse(ts: str) -> datetime:
    value = datetime.fromisoformat(ts)
    return value if value.tzinfo else value.replace(tzinfo=timezone.utc)


def live_session_view(
    store: CoreStore,
    *,
    now: datetime | None = None,
    max_duration_minutes: float | None = None,
) -> dict[str, Any]:
    """None of this is invented: an absent open session returns
    `{"active": False, ...}` with real, empty collections -- never a
    fabricated "no session" placeholder session."""
    now = now or datetime.now(timezone.utc)
    open_row = store.open_session()
    if open_row is None or (
        max_duration_minutes is not None
        and max_duration_minutes > 0
        and (now - _parse(open_row["started_at"])).total_seconds() >= max_duration_minutes * 60
    ):
        return {"active": False, "session": None, "project": None, "elapsed_seconds": 0, "goals": [], "recent_files": [], "recent_context": [], "recent_notifications": [], "commits": []}

    project_id = open_row["project_id"]
    started = _parse(open_row["started_at"])
    elapsed_seconds = max(0.0, (now - started).total_seconds())
    goals = [dict(row) for row in store.project_goals(project_id, include_completed=True)]
    files = json.loads(open_row["files_json"] or "[]")
    commits = json.loads(open_row["commits_json"] or "[]") if "commits_json" in open_row.keys() else []
    context_events = store.recent_events(TELEMETRY_WINDOW_EVENTS, since=open_row["started_at"], types=CONTEXT_EVENT_TYPES)
    notifications = [row for row in store.notifications(limit=50) if row["created_at"] >= open_row["started_at"]]
    rule_events = store.recent_events(TELEMETRY_WINDOW_EVENTS, since=open_row["started_at"])
    rules_fired = [
        {"type": row["type"], "occurred_at": row["occurred_at"]}
        for row in rule_events
        if row["type"] in {"session.started", "session.resumed", "project.activated"} or row["type"].startswith("notification.")
    ]

    return {
        "active": True,
        "session": {
            "id": open_row["id"], "started_at": open_row["started_at"], "open_reason": open_row["open_reason"],
            "meaningful_event_count": open_row["meaningful_event_count"], "active_seconds": open_row["active_seconds"],
            "burst_count": open_row["burst_count"],
        },
        "project": {"id": project_id, "name": open_row["project_name"]},
        "elapsed_seconds": round(elapsed_seconds),
        "goals": goals,
        "goals_completed": sum(1 for g in goals if g["completed"]),
        "goals_total": len(goals),
        "recent_files": files[-10:],
        "commits": commits,
        "recent_context": [
            {"type": row["type"].removeprefix("hammerspoon."), "occurred_at": row["occurred_at"], "payload": json.loads(row["payload_json"] or "{}")}
            for row in context_events
        ],
        "recent_notifications": [{"title": row["title"], "body": row["body"], "created_at": row["created_at"]} for row in notifications[:10]],
        "rules_fired": rules_fired[:10],
    }
