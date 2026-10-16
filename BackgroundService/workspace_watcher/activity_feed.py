"""Persistent human-readable summaries over raw normalized events."""

from __future__ import annotations

import hashlib
import time
from typing import Any

from .events import EventType, NormalizedEvent
from .store import WorkspaceStore


class ActivityFeed:
    def __init__(self, store: WorkspaceStore) -> None:
        self.store = store

    def process(self, event: NormalizedEvent) -> None:
        if event.type == EventType.PROJECT_ACTIVE_CHANGED:
            if event.project_id:
                self._add(event.ts, "project_active", f"{event.project_name} became active.", event.project_id, "projects", event.metadata)
            elif event.metadata.get("from_project_name"):
                self._add(event.ts, "project_idle", f"{event.metadata['from_project_name']} became idle.", event.metadata.get("from_project_id"), "projects", event.metadata)
        elif event.type == EventType.BULK_CHANGE and event.project_id:
            count = event.raw_event_count
            self._add(event.ts, "edit_burst", f"{event.project_name}: {count} files changed in a short burst.", event.project_id, "projects", {"raw_event_count": count})

    def tick(self, now: float | None = None) -> None:
        current = time.time() if now is None else now
        since = float(self.store.get_state("activity_feed.last_aggregate_at") or current - 600)
        if current <= since:
            return
        # One bounded grouped query is cheap and produces a useful timeline
        # without storing a second copy of every save.
        rows = self.store.conn.execute(
            """SELECT project_id, project_name, area_kind, COUNT(*) AS n, MIN(ts) AS first_ts, MAX(ts) AS last_ts
               FROM events WHERE meaningful=1 AND ts>? AND project_id IS NOT NULL
               GROUP BY project_id, project_name, area_kind""", (since,)
        ).fetchall()
        for row in rows:
            if int(row["n"]) < 2:
                continue
            minutes = max(1, round((float(row["last_ts"]) - float(row["first_ts"])) / 60))
            self._add(float(row["last_ts"]), "edit_summary", f"{row['project_name']}: {row['n']} files modified over {minutes} minute{'s' if minutes != 1 else ''}.", row["project_id"], row["area_kind"], {"event_count": row["n"], "window_started_at": row["first_ts"]})
        temp = self.store.conn.execute("SELECT COUNT(*) AS n FROM events WHERE meaningful=1 AND area_kind='scratch' AND ts>?", (since,)).fetchone()["n"]
        if temp:
            self._add(current, "temp_activity", f"TEMP changed: {temp} item event{'s' if temp != 1 else ''}.", None, "scratch", {"event_count": temp})
        self.store.set_state("activity_feed.last_aggregate_at", current)

    def record_status_change(self, change: dict[str, Any], now: float) -> None:
        if change["project_id"]:
            self._add(now, "folder_status", f"{change['path'].split('/')[-1]} status is now {change['status']}.", change["project_id"], "projects", {"status": change["status"], "reasons": change["reasons"]})

    def _add(self, ts: float, kind: str, summary: str, project_id: str | None, area_kind: str | None, details: dict[str, Any]) -> None:
        identity = f"{kind}|{project_id}|{summary}|{int(ts // 60)}"
        self.store.add_activity_feed(hashlib.sha1(identity.encode()).hexdigest(), ts, kind, summary, project_id=project_id, area_kind=area_kind, details=details)
