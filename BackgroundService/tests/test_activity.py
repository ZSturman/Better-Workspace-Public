import time

import pytest

from workspace_watcher.activity import ActivityTracker
from workspace_watcher.config import WatcherSettings
from workspace_watcher.events import EventType, NormalizedEvent
from workspace_watcher.store import WorkspaceStore


@pytest.fixture
def store(tmp_path):
    s = WorkspaceStore(tmp_path / "events.db")
    yield s
    s.close()


def settings(**overrides):
    s = WatcherSettings(active_project_recency_minutes=20, active_project_min_events=3, active_project_window_minutes=120)
    for k, v in overrides.items():
        setattr(s, k, v)
    return s


def fire(store, tracker, project_id, project_name, ts, path="Projects/X/file.py"):
    event = NormalizedEvent(
        type=EventType.MODIFIED, path=path, is_directory=False, area="Projects",
        area_kind="projects", meaningful=True, project_id=project_id, project_name=project_name, ts=ts,
    )
    store.insert_event(event)
    return tracker.after_project_event(event)


def test_no_active_project_below_min_events(store):
    store.create_project("p1", "Projects/X", "X", None, None, time.time())
    tracker = ActivityTracker(store, settings())
    now = time.time()
    fire(store, tracker, "p1", "X", now)
    fire(store, tracker, "p1", "X", now)  # only 2, threshold is 3
    assert tracker.active_project() is None


def test_active_project_after_enough_recent_events(store):
    store.create_project("p1", "Projects/X", "X", None, None, time.time())
    tracker = ActivityTracker(store, settings())
    now = time.time()
    transition = None
    for _ in range(3):
        transition = fire(store, tracker, "p1", "X", now)
    active = tracker.active_project()
    assert active is not None
    assert active.project_id == "p1"
    assert transition is not None
    assert transition.type == "project_active_changed"
    assert transition.metadata["to_project_id"] == "p1"
    assert transition.metadata["from_project_id"] is None


def test_transition_fires_when_active_project_switches(store):
    now = time.time()
    store.create_project("p1", "Projects/X", "X", None, None, now)
    store.create_project("p2", "Projects/Y", "Y", None, None, now)
    tracker = ActivityTracker(store, settings())

    for _ in range(3):
        fire(store, tracker, "p1", "X", now)
    assert tracker.active_project().project_id == "p1"

    transition = None
    for _ in range(3):
        transition = fire(store, tracker, "p2", "Y", now + 1)
    assert tracker.active_project().project_id == "p2"
    assert transition.metadata["from_project_id"] == "p1"
    assert transition.metadata["to_project_id"] == "p2"


def test_stale_activity_outside_recency_window_is_not_active(store):
    old_ts = time.time() - 3600  # an hour ago, recency window is 20 minutes
    store.create_project("p1", "Projects/X", "X", None, None, old_ts)
    tracker = ActivityTracker(store, settings())
    for _ in range(3):
        fire(store, tracker, "p1", "X", old_ts)
    assert tracker.active_project() is None
