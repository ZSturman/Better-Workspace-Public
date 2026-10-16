"""v2's own work-session inference: start, continuation, switching, idle
close, resume-vs-duplicate, and completion scoring."""

from __future__ import annotations

import json
from datetime import datetime, timedelta, timezone
from pathlib import Path

from workspace_watcher.core_config import SessionsSettings
from workspace_watcher.core_events import EventTypes
from workspace_watcher.core_store import CoreStore
from workspace_watcher.projects_v2 import ProjectRef
from workspace_watcher.sessions_v2 import Sessionizer


def _iso(dt: datetime) -> str:
    return dt.isoformat()


def _now() -> datetime:
    return datetime(2026, 1, 1, tzinfo=timezone.utc)


def _sessionizer(tmp_path: Path, store: CoreStore, **overrides) -> Sessionizer:
    settings = SessionsSettings(**overrides)
    return Sessionizer(store, settings, tmp_path, git_probe=lambda _root: {})


FOO = ProjectRef(project_id="p-foo", name="Foo", path="Projects/Foo")
BAR = ProjectRef(project_id="p-bar", name="Bar", path="Projects/Bar")


def test_first_touch_opens_a_new_session(tmp_path):
    with CoreStore(tmp_path / "core.db") as store:
        sessionizer = _sessionizer(tmp_path, store)
        events = sessionizer.touch(FOO, "Projects/Foo/a.py", False, _iso(_now()))
        assert [e.type for e in events] == [EventTypes.SESSION_STARTED]
        rows = store.recent_sessions()
        assert len(rows) == 1 and rows[0]["status"] == "open" and rows[0]["project_id"] == "p-foo"


def test_repeated_touches_in_same_project_extend_not_duplicate(tmp_path):
    with CoreStore(tmp_path / "core.db") as store:
        sessionizer = _sessionizer(tmp_path, store)
        t0 = _now()
        events1 = sessionizer.touch(FOO, "Projects/Foo/a.py", False, _iso(t0))
        events2 = sessionizer.touch(FOO, "Projects/Foo/b.py", False, _iso(t0 + timedelta(seconds=30)))
        assert events2 == []  # no event for a mere continuation
        rows = store.recent_sessions()
        assert len(rows) == 1
        assert rows[0]["meaningful_event_count"] == 2
        assert sorted(__import__("json").loads(rows[0]["files_json"])) == ["Projects/Foo/a.py", "Projects/Foo/b.py"]
        assert events1[0].entity_id == rows[0]["id"]


def test_switching_projects_closes_previous_and_opens_new(tmp_path):
    with CoreStore(tmp_path / "core.db") as store:
        sessionizer = _sessionizer(tmp_path, store, minimum_events=1, minimum_active_seconds=1, minimum_confidence=0.0)
        t0 = _now()
        sessionizer.touch(FOO, "Projects/Foo/a.py", False, _iso(t0))
        events = sessionizer.touch(BAR, "Projects/Bar/a.py", False, _iso(t0 + timedelta(minutes=1)))
        assert [e.type for e in events] == [EventTypes.SESSION_CLOSED, EventTypes.SESSION_STARTED]
        rows = {row["project_id"]: row for row in store.recent_sessions()}
        assert rows["p-foo"]["status"] == "completed" and rows["p-foo"]["close_reason"] == "switched"
        assert rows["p-bar"]["status"] == "open"
        # Exactly one open session at any time.
        assert sum(1 for row in store.recent_sessions() if row["status"] == "open") == 1


def test_short_low_activity_session_closes_as_discarded(tmp_path):
    with CoreStore(tmp_path / "core.db") as store:
        sessionizer = _sessionizer(tmp_path, store)  # default thresholds: 3 events, 120s active, 0.55 confidence
        t0 = _now()
        sessionizer.touch(FOO, "Projects/Foo/a.py", False, _iso(t0))
        events = sessionizer.close_all(_iso(t0 + timedelta(seconds=5)), "test")
        assert events[0].type == EventTypes.SESSION_CLOSED
        assert events[0].payload["status"] == "discarded"


def test_legitimate_session_closes_as_completed(tmp_path):
    with CoreStore(tmp_path / "core.db") as store:
        sessionizer = _sessionizer(tmp_path, store)
        t0 = _now()
        for i in range(4):
            sessionizer.touch(FOO, f"Projects/Foo/f{i}.py", False, _iso(t0 + timedelta(seconds=i * 60)))
        events = sessionizer.close_all(_iso(t0 + timedelta(seconds=4 * 60)), "test")
        assert events[0].payload["status"] == "completed"
        row = store.session_by_id(events[0].entity_id)
        assert row["status"] == "completed"
        assert row["confidence"] >= 0.55


def test_commits_made_during_the_session_are_captured_as_evidence(tmp_path):
    import subprocess

    project_root = tmp_path / "Projects" / "Foo"
    project_root.mkdir(parents=True)
    subprocess.run(["git", "init", "-q"], cwd=project_root, check=True)
    subprocess.run(["git", "config", "user.email", "test@example.com"], cwd=project_root, check=True)
    subprocess.run(["git", "config", "user.name", "Test"], cwd=project_root, check=True)
    (project_root / "a.py").write_text("print(1)")
    subprocess.run(["git", "add", "."], cwd=project_root, check=True)
    subprocess.run(["git", "commit", "-q", "-m", "Initial commit"], cwd=project_root, check=True)

    with CoreStore(tmp_path / "core.db") as store:
        store.create_project(project_id="p-foo", path="Projects/Foo", root_path="Projects", name="Foo", device=None, inode=None, timestamp=_iso(_now()))
        sessionizer = Sessionizer(store, SessionsSettings(), tmp_path)  # real git_probe/commits_probe, no fakes
        t0 = _now() - timedelta(minutes=5)  # started before the commit above, so `--since` includes it
        sessionizer.touch(FOO, "Projects/Foo/a.py", False, _iso(t0))
        events = sessionizer.close_all(_iso(t0 + timedelta(minutes=1)), "test")
        row = store.session_by_id(events[0].entity_id)
        commits = json.loads(row["commits_json"])
        assert len(commits) == 1
        assert commits[0]["subject"] == "Initial commit"
        assert len(commits[0]["sha"]) == 12


def test_close_expired_closes_only_past_the_inactivity_timeout(tmp_path):
    with CoreStore(tmp_path / "core.db") as store:
        sessionizer = _sessionizer(tmp_path, store, inactivity_timeout_minutes=20.0)
        t0 = _now()
        sessionizer.touch(FOO, "Projects/Foo/a.py", False, _iso(t0))
        assert sessionizer.close_expired(_iso(t0 + timedelta(minutes=10))) == []
        assert store.open_session() is not None
        events = sessionizer.close_expired(_iso(t0 + timedelta(minutes=21)))
        assert len(events) == 1 and events[0].payload["close_reason"] == "inactivity"
        assert store.open_session() is None


def test_max_duration_closes_even_when_the_last_activity_is_recent(tmp_path):
    with CoreStore(tmp_path / "core.db") as store:
        sessionizer = _sessionizer(tmp_path, store, max_duration_minutes=480.0)
        t0 = _now()
        sessionizer.touch(FOO, "Projects/Foo/a.py", False, _iso(t0))
        sessionizer.touch(FOO, "Projects/Foo/b.py", False, _iso(t0 + timedelta(hours=7, minutes=59)))

        events = sessionizer.close_expired(_iso(t0 + timedelta(hours=8)))

        assert len(events) == 1
        assert events[0].payload["close_reason"] == "max_duration"
        assert store.open_session() is None


def test_touch_after_max_duration_starts_a_new_session_instead_of_resuming(tmp_path):
    with CoreStore(tmp_path / "core.db") as store:
        sessionizer = _sessionizer(tmp_path, store, max_duration_minutes=60.0, merge_nearby_minutes=45.0)
        t0 = _now()
        first = sessionizer.touch(FOO, "Projects/Foo/a.py", False, _iso(t0))[0]

        events = sessionizer.touch(FOO, "Projects/Foo/b.py", False, _iso(t0 + timedelta(hours=1)))

        assert [event.type for event in events] == [EventTypes.SESSION_CLOSED, EventTypes.SESSION_STARTED]
        assert events[0].entity_id == first.entity_id
        assert events[0].payload["close_reason"] == "max_duration"
        assert events[1].entity_id != first.entity_id
        assert store.open_session()["id"] == events[1].entity_id


def test_non_positive_max_duration_disables_the_hard_cap(tmp_path):
    with CoreStore(tmp_path / "core.db") as store:
        sessionizer = _sessionizer(tmp_path, store, max_duration_minutes=0.0, inactivity_timeout_minutes=3_000.0)
        t0 = _now()
        sessionizer.touch(FOO, "Projects/Foo/a.py", False, _iso(t0))

        assert sessionizer.close_expired(_iso(t0 + timedelta(hours=34))) == []
        assert store.open_session() is not None


def test_returning_within_merge_window_resumes_instead_of_duplicating(tmp_path):
    with CoreStore(tmp_path / "core.db") as store:
        sessionizer = _sessionizer(tmp_path, store, merge_nearby_minutes=45.0)
        t0 = _now()
        sessionizer.touch(FOO, "Projects/Foo/a.py", False, _iso(t0))
        closed = sessionizer.close_all(_iso(t0 + timedelta(minutes=1)), "switched")
        original_id = closed[0].entity_id

        resumed_events = sessionizer.touch(FOO, "Projects/Foo/b.py", False, _iso(t0 + timedelta(minutes=30)))
        assert [e.type for e in resumed_events] == [EventTypes.SESSION_RESUMED]
        assert resumed_events[0].entity_id == original_id
        rows = store.recent_sessions()
        assert len(rows) == 1  # reopened the same row, not a new one
        assert rows[0]["status"] == "open"
        # The touch that triggered the resume is real evidence, same as any
        # other touch -- it must not be silently dropped from the count or
        # from the file list just because it landed on a resume.
        assert rows[0]["meaningful_event_count"] == 2  # the original touch, plus this one
        assert json.loads(rows[0]["files_json"]) == ["Projects/Foo/a.py", "Projects/Foo/b.py"]


def test_returning_after_merge_window_creates_a_new_session(tmp_path):
    with CoreStore(tmp_path / "core.db") as store:
        sessionizer = _sessionizer(tmp_path, store, merge_nearby_minutes=45.0)
        t0 = _now()
        sessionizer.touch(FOO, "Projects/Foo/a.py", False, _iso(t0))
        closed = sessionizer.close_all(_iso(t0 + timedelta(minutes=1)), "switched")
        original_id = closed[0].entity_id

        later_events = sessionizer.touch(FOO, "Projects/Foo/b.py", False, _iso(t0 + timedelta(minutes=90)))
        assert [e.type for e in later_events] == [EventTypes.SESSION_STARTED]
        assert later_events[0].entity_id != original_id
        assert len(store.recent_sessions()) == 2


def test_close_all_is_a_noop_when_nothing_is_open(tmp_path):
    with CoreStore(tmp_path / "core.db") as store:
        sessionizer = _sessionizer(tmp_path, store)
        assert sessionizer.close_all(_iso(_now()), "watcher_stopped") == []


def test_burst_and_gap_evidence_tracks_within_session_interruptions(tmp_path):
    with CoreStore(tmp_path / "core.db") as store:
        sessionizer = _sessionizer(tmp_path, store, burst_gap_minutes=5.0)
        t0 = _now()
        sessionizer.touch(FOO, "Projects/Foo/a.py", False, _iso(t0))
        # Small gap -- same burst, no interruption.
        sessionizer.touch(FOO, "Projects/Foo/b.py", False, _iso(t0 + timedelta(minutes=1)))
        # Big gap (> burst_gap_minutes) -- a real interruption, starts burst 2.
        sessionizer.touch(FOO, "Projects/Foo/c.py", False, _iso(t0 + timedelta(minutes=20)))
        # Another small gap within burst 2.
        sessionizer.touch(FOO, "Projects/Foo/d.py", False, _iso(t0 + timedelta(minutes=21)))
        row = store.open_session()
        assert row["burst_count"] == 2
        assert abs(row["longest_gap_seconds"] - 19 * 60) < 1.0
        # Closing finalizes the still-open (second) burst.
        events = sessionizer.close_all(_iso(t0 + timedelta(minutes=21)), "test")
        closed = store.session_by_id(events[0].entity_id)
        assert closed["longest_burst_seconds"] >= 60  # burst 2 spanned at least 1 minute


def test_resuming_a_closed_session_counts_as_an_interruption_and_new_burst(tmp_path):
    with CoreStore(tmp_path / "core.db") as store:
        sessionizer = _sessionizer(tmp_path, store, merge_nearby_minutes=45.0)
        t0 = _now()
        sessionizer.touch(FOO, "Projects/Foo/a.py", False, _iso(t0))
        sessionizer.close_all(_iso(t0 + timedelta(minutes=1)), "switched")
        sessionizer.touch(FOO, "Projects/Foo/b.py", False, _iso(t0 + timedelta(minutes=30)))
        row = store.open_session()
        assert row["burst_count"] == 2  # the resume itself started a new burst
        assert row["longest_gap_seconds"] >= 28 * 60  # the ~29-minute closed gap dwarfs any in-session gap


def test_a_single_uninterrupted_session_has_one_burst_and_zero_gap(tmp_path):
    with CoreStore(tmp_path / "core.db") as store:
        sessionizer = _sessionizer(tmp_path, store, burst_gap_minutes=5.0)
        t0 = _now()
        sessionizer.touch(FOO, "Projects/Foo/a.py", False, _iso(t0))
        sessionizer.touch(FOO, "Projects/Foo/b.py", False, _iso(t0 + timedelta(seconds=30)))
        sessionizer.touch(FOO, "Projects/Foo/c.py", False, _iso(t0 + timedelta(minutes=1)))
        row = store.open_session()
        assert row["burst_count"] == 1
        assert row["longest_gap_seconds"] == 0.0


def test_disabled_sessions_setting_is_a_complete_noop(tmp_path):
    with CoreStore(tmp_path / "core.db") as store:
        sessionizer = _sessionizer(tmp_path, store, enabled=False)
        assert sessionizer.touch(FOO, "Projects/Foo/a.py", False, _iso(_now())) == []
        assert sessionizer.close_expired(_iso(_now())) == []
        assert store.recent_sessions() == []
