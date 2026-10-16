"""Read-only query API for downstream consumers.

This is the intended integration point for everything that isn't the
watcher itself: a future Hammerspoon poller, a Notion sync daemon, a
relevance/resurfacing agent, a Work Log generator, and so on. It only reads
-- it never runs alongside the watcher process and never needs to.

Nothing here is Claude/LM-Studio/Notion specific. It hands back plain dicts
and dataclasses of facts; what a consumer does with those facts (rank them,
summarize them, decide whether to notify about them) is deliberately out of
scope for the watcher itself.

Any language with a SQLite driver can read the same database directly --
see README.md's "Database schema" section for the table reference. This
class is a convenience for Python consumers, not the only way in.
"""

from __future__ import annotations

import json
import sqlite3
import time
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Any, Optional

from .store import WorkspaceStore


def _row_to_event_dict(row: sqlite3.Row) -> dict[str, Any]:
    d = dict(row)
    d["metadata"] = json.loads(d.pop("metadata_json", "{}") or "{}")
    d["is_directory"] = bool(d["is_directory"])
    d["meaningful"] = bool(d["meaningful"])
    return d


@dataclass
class ProjectSummary:
    project_id: str
    name: str
    path: str
    first_seen_at: float
    last_activity_at: Optional[float]
    meaningful_event_count: int
    status: str


@dataclass
class ActiveProject:
    project_id: str
    project_name: str
    active_since: float


@dataclass
class ProjectActivityContext:
    """The bundle a future relevance/summarization agent would consume:
    who the project is, what's happened recently, and what files were
    involved. Model-agnostic -- it's just data."""

    project: ProjectSummary
    window_hours: float
    recent_events: list[dict[str, Any]]
    files_touched: list[str]
    event_counts_by_type: dict[str, int]
    first_activity_in_window: Optional[float]
    last_activity_in_window: Optional[float]


class WorkspaceWatcherClient:
    def __init__(self, db_path: Path):
        self._store = WorkspaceStore(db_path, read_only=True)

    def close(self) -> None:
        self._store.close()

    def __enter__(self) -> "WorkspaceWatcherClient":
        return self

    def __exit__(self, *exc: Any) -> None:
        self.close()

    # -- events -----------------------------------------------------------

    def recent_events(
        self, limit: int = 50, area_kind: Optional[str] = None,
        project_id: Optional[str] = None, meaningful_only: bool = True,
        since_ts: Optional[float] = None,
    ) -> list[dict[str, Any]]:
        rows = self._store.recent_events(limit, area_kind, project_id, meaningful_only, since_ts)
        return [_row_to_event_dict(r) for r in rows]

    # -- projects -----------------------------------------------------------

    def _to_summary(self, row: sqlite3.Row) -> ProjectSummary:
        return ProjectSummary(
            project_id=row["project_id"], name=row["name"], path=row["path"],
            first_seen_at=row["first_seen_at"], last_activity_at=row["last_activity_at"],
            meaningful_event_count=row["meaningful_event_count"], status=row["status"],
        )

    def active_project(self) -> Optional[ActiveProject]:
        state = self._store.get_state("active_project")
        if not state:
            return None
        return ActiveProject(state["project_id"], state["project_name"], state["since"])

    def recently_active_projects(self, within_hours: float = 24.0, limit: int = 20) -> list[ProjectSummary]:
        cutoff = time.time() - within_hours * 3600
        rows = self._store.all_projects(status="active")
        summaries = [self._to_summary(r) for r in rows if r["last_activity_at"] and r["last_activity_at"] >= cutoff]
        summaries.sort(key=lambda p: p.last_activity_at or 0, reverse=True)
        return summaries[:limit]

    def all_projects(self, status: Optional[str] = "active") -> list[ProjectSummary]:
        return [self._to_summary(r) for r in self._store.all_projects(status=status)]

    def project_activity(self, project_id: str, window_hours: float = 24.0, event_limit: int = 200) -> Optional[ProjectActivityContext]:
        row = self._store.get_project(project_id)
        if row is None:
            return None
        since_ts = time.time() - window_hours * 3600
        rows = self._store.recent_events(limit=event_limit, project_id=project_id, meaningful_only=True, since_ts=since_ts)
        events = [_row_to_event_dict(r) for r in rows]
        files = []
        seen = set()
        counts: dict[str, int] = {}
        for e in events:
            counts[e["type"]] = counts.get(e["type"], 0) + 1
            if not e["is_directory"] and e["path"] not in seen:
                seen.add(e["path"])
                files.append(e["path"])
        timestamps = [e["ts"] for e in events]
        return ProjectActivityContext(
            project=self._to_summary(row),
            window_hours=window_hours,
            recent_events=events,
            files_touched=files,
            event_counts_by_type=counts,
            first_activity_in_window=min(timestamps) if timestamps else None,
            last_activity_in_window=max(timestamps) if timestamps else None,
        )

    # -- inbox / generic areas -----------------------------------------------

    def area_snapshot(self, area_kind: str, only_existing: bool = True) -> list[dict[str, Any]]:
        rows = self._store.fs_entries(area_kind, only_existing=only_existing)
        return [dict(r) for r in rows]

    def inbox_snapshot(self, only_existing: bool = True) -> list[dict[str, Any]]:
        return self.area_snapshot("inbox", only_existing=only_existing)

    # -- observability --------------------------------------------------------

    def recent_handler_errors(self, limit: int = 20) -> list[dict[str, Any]]:
        return [dict(r) for r in self._store.recent_handler_errors(limit)]

    # -- activity intelligence ------------------------------------------------

    def activity_sessions(
        self, start_ts: Optional[float] = None, *, project_id: Optional[str] = None,
        include_discarded: bool = False, limit: int = 100,
    ) -> list[dict[str, Any]]:
        return [_session_row(row) for row in self._store.recent_activity_sessions(
            start_ts, project_id=project_id, include_discarded=include_discarded, limit=limit,
        )]

    def fragmentation_metrics(self, limit: int = 100) -> list[dict[str, Any]]:
        result = []
        for row in self._store.recent_fragmentation_metrics(limit):
            item = dict(row)
            item["details"] = json.loads(item.pop("details_json") or "{}")
            result.append(item)
        return result

    def priority_alignment(self, limit: int = 100) -> list[dict[str, Any]]:
        result = []
        for row in self._store.recent_priority_alignment_snapshots(limit):
            item = dict(row)
            item["details"] = json.loads(item.pop("details_json") or "{}")
            result.append(item)
        return result

    def work_log_drafts(self, date_key: Optional[str] = None, limit: int = 100) -> list[dict[str, Any]]:
        result = []
        for row in self._store.work_log_drafts(date_key, limit):
            item = dict(row)
            item["session_ids"] = json.loads(item.pop("session_ids_json") or "[]")
            item["payload"] = json.loads(item.pop("payload_json") or "{}")
            result.append(item)
        return result

    def nudge_decisions(self, limit: int = 100) -> list[dict[str, Any]]:
        result = []
        for row in self._store.recent_nudge_decisions(limit):
            item = dict(row)
            item["evidence"] = json.loads(item.pop("evidence_json") or "{}")
            result.append(item)
        return result

    def daily_activity_summary(self, day_start_ts: float, day_end_ts: float) -> dict[str, Any]:
        sessions = self.activity_sessions(day_start_ts, limit=500)
        sessions = [item for item in sessions if item["started_at"] < day_end_ts]
        events = self._store.events_between(day_start_ts, day_end_ts)
        by_project: dict[str, dict[str, Any]] = {}
        for session in sessions:
            if session["status"] != "completed":
                continue
            target = by_project.setdefault(session["project_id"], {
                "project_id": session["project_id"], "project_name": session["project_name"],
                "sessions": 0, "active_seconds": 0.0, "event_count": 0,
            })
            target["sessions"] += 1
            target["active_seconds"] += session["active_seconds"]
            target["event_count"] += session["meaningful_event_count"]
        sequence = [row["project_id"] for row in events if row["project_id"]]
        switches = sum(current != previous for previous, current in zip(sequence, sequence[1:]))
        long_session = max((item for item in sessions if item["status"] == "completed"), key=lambda item: item["active_seconds"], default=None)
        date_key = datetime.fromtimestamp(day_start_ts).astimezone().date().isoformat()
        priority_snapshots = [
            item for item in self.priority_alignment(500)
            if day_start_ts <= item["evaluated_at"] < day_end_ts
        ]
        return {
            "projects": sorted(by_project.values(), key=lambda item: item["active_seconds"], reverse=True),
            "meaningful_sessions": sum(1 for item in sessions if item["status"] == "completed"),
            "project_switches": switches, "longest_focused_session": long_session,
            "work_logs": self.work_log_drafts(date_key, 200),
            "nudges": [item for item in self.nudge_decisions(500) if day_start_ts <= item["evaluated_at"] < day_end_ts],
            "priority_alignment": priority_snapshots[:1],
            "fragmentation": [item for item in self.fragmentation_metrics(500) if day_start_ts <= item["evaluated_at"] < day_end_ts],
        }


def _session_row(row: sqlite3.Row) -> dict[str, Any]:
    item = dict(row)
    item["files"] = json.loads(item.pop("files_json") or "[]")
    item["git"] = json.loads(item.pop("git_json") or "{}")
    return item
