from __future__ import annotations

import json

from workspace_watcher.config import default_config
from workspace_watcher.context_engine import ContextEngine
from workspace_watcher.intent import IntentItemIndex
from workspace_watcher.store import WorkspaceStore
import logging


def _setup(tmp_path):
    root = tmp_path
    (root / "For Inspiration" / "Dashboard Screenshots").mkdir(parents=True)
    (root / "For Inspiration" / "Dashboard Screenshots" / ".item.toml").write_text(
        'tags = ["Dashboard design", "Simplistic UX"]\n'
    )
    cfg = default_config(root)
    cfg.relevance.enabled = True
    cfg.relevance.minimum_score = 0.05
    store = WorkspaceStore(root / "events.db")
    store.create_project("p1", "Projects/Home Dashboard", "Home Dashboard", None, None, 0)
    IntentItemIndex(store, root).rebuild(cfg, reason="test")
    engine = ContextEngine(store, cfg, logging.getLogger("test"))
    return store, cfg, engine


def test_relevance_surfaces_intent_item_by_tag_overlap_with_project_activity(tmp_path):
    store, cfg, engine = _setup(tmp_path)
    engine.relevance.refresh_sources()
    from workspace_watcher.client import ProjectActivityContext, ProjectSummary

    context = ProjectActivityContext(
        ProjectSummary("p1", "Home Dashboard", "Projects/Home Dashboard", 0, 1, 3, "active"),
        24, [], ["Projects/Home Dashboard/dashboard-design-navigation.md"], {"modified": 1}, 0, 1,
    )
    result = engine.relevance.run(context, now=100)
    surfaced = [c for c in result.candidates if c["decision"] == "surface"]
    assert any(c["source"] == "intent:For Inspiration" for c in surfaced)
    store.close()


def test_record_relationship_useful_writes_work_log_and_suppresses_future_surfacing(tmp_path):
    store, cfg, engine = _setup(tmp_path)
    item = store.get_item_by_path("For Inspiration/Dashboard Screenshots")
    engine.record_relationship(item["item_id"], "p1", "useful", reason={"matched_tags": ["Dashboard design"]})
    entries = store.recent_work_log_manual_entries("p1")
    assert len(entries) == 1 and "useful" in entries[0]["kind"]
    memory = store.get_relevance_memory(f"intent:For Inspiration:{item['path']}", "intent:For Inspiration", "p1")
    assert memory["status"] == "useful" and memory["accepted_at"] is not None
    store.close()


def test_record_relationship_not_related_is_permanent_but_not_global(tmp_path):
    store, cfg, engine = _setup(tmp_path)
    item = store.get_item_by_path("For Inspiration/Dashboard Screenshots")
    store.create_project("p2", "Projects/Other App", "Other App", None, None, 0)
    engine.record_relationship(item["item_id"], "p1", "not_related")
    memory_p1 = store.get_relevance_memory(f"intent:For Inspiration:{item['path']}", "intent:For Inspiration", "p1")
    memory_p2 = store.get_relevance_memory(f"intent:For Inspiration:{item['path']}", "intent:For Inspiration", "p2")
    assert memory_p1["status"] == "not_related"
    assert memory_p2 is None  # never surfaced for p2, so no memory row yet -- not globally suppressed
    store.close()


def test_record_relationship_defer_next_session_blocks_until_new_session(tmp_path):
    store, cfg, engine = _setup(tmp_path)
    item = store.get_item_by_path("For Inspiration/Dashboard Screenshots")
    engine.relevance.refresh_sources()
    from workspace_watcher.client import ProjectActivityContext, ProjectSummary

    context = ProjectActivityContext(
        ProjectSummary("p1", "Home Dashboard", "Projects/Home Dashboard", 0, 1, 3, "active"),
        24, [], ["Projects/Home Dashboard/dashboard design.md"], {"modified": 1}, 0, 1,
    )
    engine.record_relationship(item["item_id"], "p1", "deferred", defer_next_session=True, now=200)
    result = engine.relevance.run(context, now=200)
    candidate = next(c for c in result.candidates if c["source"] == "intent:For Inspiration")
    assert candidate["decision"] == "suppressed" and candidate["suppression_reason"] == "deferred_until_next_session"

    store.upsert_activity_session({
        "session_id": "s1", "project_id": "p1", "project_name": "Home Dashboard",
        "started_at": 300, "ended_at": 310, "active_seconds": 200,
        "meaningful_event_count": 5, "status": "completed", "created_at": 300, "updated_at": 310,
    })
    result2 = engine.relevance.run(context, now=400)
    candidate2 = next(c for c in result2.candidates if c["source"] == "intent:For Inspiration")
    assert candidate2["decision"] == "surface"
    store.close()
