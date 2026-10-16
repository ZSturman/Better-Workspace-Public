from __future__ import annotations

import time

from workspace_watcher.activity_feed import ActivityFeed
from workspace_watcher.events import EventType, NormalizedEvent
from workspace_watcher.store import WorkspaceStore


def test_feed_aggregates_file_saves_and_records_project_transition(tmp_path):
    store = WorkspaceStore(tmp_path / "events.db")
    now = time.time()
    for index in range(3):
        store.insert_event(NormalizedEvent(EventType.MODIFIED, f"Projects/Alpha/{index}.py", False, "Projects", "projects", True, project_id="alpha", project_name="Alpha", ts=now + index))
    feed = ActivityFeed(store)
    feed.tick(now + 10)
    feed.process(NormalizedEvent(EventType.PROJECT_ACTIVE_CHANGED, "Projects/Alpha", True, "Projects", "system", True, project_id="alpha", project_name="Alpha", ts=now + 11))
    summaries = [row["summary"] for row in store.recent_activity_feed()]
    assert any("3 files modified" in summary for summary in summaries)
    assert "Alpha became active." in summaries
    store.close()
