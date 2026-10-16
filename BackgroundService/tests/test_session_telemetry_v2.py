"""The live during-a-session view: curated, real, and empty (never
fabricated) when nothing is happening."""

from __future__ import annotations

from datetime import datetime, timedelta, timezone

from workspace_watcher.core_events import EventTypes, WorkspaceEvent
from workspace_watcher.core_store import CoreStore
from workspace_watcher.session_telemetry_v2 import live_session_view

NOW = datetime(2026, 6, 1, 12, 0, tzinfo=timezone.utc)


def _iso(dt: datetime) -> str:
    return dt.isoformat()


def test_no_open_session_returns_a_real_inactive_state_not_a_fabricated_session(tmp_path):
    with CoreStore(tmp_path / "core.db") as store:
        view = live_session_view(store, now=NOW)
        assert view["active"] is False
        assert view["session"] is None
        assert view["goals"] == []
        assert view["recent_files"] == []


def test_an_open_session_reports_real_elapsed_time_and_goals(tmp_path):
    with CoreStore(tmp_path / "core.db") as store:
        store.create_project(project_id="p1", path="Projects/Alpha", root_path="Projects", name="Alpha", device=1, inode=1, timestamp=_iso(NOW))
        started = NOW - timedelta(minutes=43)
        store.upsert_session({
            "id": "s1", "project_id": "p1", "project_name": "Alpha", "started_at": _iso(started), "ended_at": _iso(NOW),
            "active_seconds": 1800, "meaningful_event_count": 12, "files": ["a.py", "b.py"], "burst_count": 2,
            "intensity": 0.5, "confidence": 0.7, "git": {}, "status": "open", "close_reason": None,
            "longest_gap_seconds": 0, "longest_burst_seconds": 900, "current_burst_started_at": None, "open_reason": "started",
            "created_at": _iso(started), "updated_at": _iso(NOW),
        })
        store.replace_project_goals("p1", ["Fix the bug", "Write docs"], session_id="s1", source="user", timestamp=_iso(NOW))
        goals = store.project_goals("p1")
        store.set_goal_completed(goals[0]["id"], True, _iso(NOW))

        view = live_session_view(store, now=NOW)
        assert view["active"] is True
        assert view["project"]["name"] == "Alpha"
        assert view["elapsed_seconds"] == 43 * 60
        assert view["goals_total"] == 2
        assert view["goals_completed"] == 1
        assert view["recent_files"] == ["a.py", "b.py"]


def test_duration_capped_view_never_shows_a_stale_open_session_as_active(tmp_path):
    with CoreStore(tmp_path / "core.db") as store:
        store.create_project(project_id="p1", path="Projects/Alpha", root_path="Projects", name="Alpha", device=1, inode=1, timestamp=_iso(NOW))
        started = NOW - timedelta(hours=34)
        store.upsert_session({
            "id": "s1", "project_id": "p1", "project_name": "Alpha", "started_at": _iso(started), "ended_at": _iso(NOW),
            "active_seconds": 1800, "meaningful_event_count": 12, "files": [], "burst_count": 2,
            "intensity": 0.5, "confidence": 0.7, "git": {}, "status": "open", "close_reason": None,
            "longest_gap_seconds": 0, "longest_burst_seconds": 900, "current_burst_started_at": None, "open_reason": "started",
            "created_at": _iso(started), "updated_at": _iso(NOW),
        })

        view = live_session_view(store, now=NOW, max_duration_minutes=480.0)

        assert view["active"] is False
        assert view["session"] is None
        assert view["elapsed_seconds"] == 0


def test_context_events_before_the_session_started_are_excluded(tmp_path):
    with CoreStore(tmp_path / "core.db") as store:
        store.create_project(project_id="p1", path="Projects/Alpha", root_path="Projects", name="Alpha", device=1, inode=1, timestamp=_iso(NOW))
        started = NOW - timedelta(minutes=10)
        store.upsert_session({
            "id": "s1", "project_id": "p1", "project_name": "Alpha", "started_at": _iso(started), "ended_at": _iso(NOW),
            "active_seconds": 600, "meaningful_event_count": 3, "files": [], "burst_count": 1, "intensity": 0.3, "confidence": 0.5,
            "git": {}, "status": "open", "close_reason": None, "longest_gap_seconds": 0, "longest_burst_seconds": 600,
            "current_burst_started_at": None, "open_reason": "started", "created_at": _iso(started), "updated_at": _iso(NOW),
        })
        store.record_event(WorkspaceEvent(type="hammerspoon.app_focused", entity_id=None, payload={"app": "OldApp"}, source="hammerspoon", occurred_at=_iso(started - timedelta(minutes=5))))
        store.record_event(WorkspaceEvent(type="hammerspoon.app_focused", entity_id=None, payload={"app": "Xcode"}, source="hammerspoon", occurred_at=_iso(NOW - timedelta(minutes=2))))

        view = live_session_view(store, now=NOW)
        apps = [e["payload"].get("app") for e in view["recent_context"]]
        assert "Xcode" in apps
        assert "OldApp" not in apps


def test_notifications_produced_during_the_session_are_surfaced(tmp_path):
    with CoreStore(tmp_path / "core.db") as store:
        store.create_project(project_id="p1", path="Projects/Alpha", root_path="Projects", name="Alpha", device=1, inode=1, timestamp=_iso(NOW))
        started = NOW - timedelta(minutes=10)
        store.upsert_session({
            "id": "s1", "project_id": "p1", "project_name": "Alpha", "started_at": _iso(started), "ended_at": _iso(NOW),
            "active_seconds": 600, "meaningful_event_count": 3, "files": [], "burst_count": 1, "intensity": 0.3, "confidence": 0.5,
            "git": {}, "status": "open", "close_reason": None, "longest_gap_seconds": 0, "longest_burst_seconds": 600,
            "current_burst_started_at": None, "open_reason": "started", "created_at": _iso(started), "updated_at": _iso(NOW),
        })
        store.create_notification({
            "id": "n1", "type": "info", "title": "Rule fired", "body": "Something happened", "entity_id": None,
            "source_event_id": None, "source_rule_id": None, "priority": "normal", "dedupe_key": None,
            "actions_json": "[]", "created_at": _iso(NOW - timedelta(minutes=1)), "expires_at": None,
        })
        view = live_session_view(store, now=NOW)
        assert view["recent_notifications"][0]["title"] == "Rule fired"
