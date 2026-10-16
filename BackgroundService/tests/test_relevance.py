from __future__ import annotations

from workspace_watcher.client import ProjectActivityContext, ProjectSummary
from workspace_watcher.config import RelevanceSettings
from workspace_watcher.relevance import RelevanceEngine
from workspace_watcher.store import WorkspaceStore


def context() -> ProjectActivityContext:
    return ProjectActivityContext(ProjectSummary("p1", "Recipe Planner", "Projects/Recipe Planner", 0, 1, 3, "active"), 24, [], ["Projects/Recipe Planner/shopping-list.md"], {"modified": 3}, 0, 1)


def test_lexical_unlinked_relation_memory_and_snooze(tmp_path):
    store = WorkspaceStore(tmp_path / "events.db")
    store.create_project("p1", "Projects/Recipe Planner", "Recipe Planner", None, None, 0)
    store.replace_notion_project_cache([
        {"notion_project_id": "idea", "name": "Recipe shopping workflow", "current_work": ["plan grocery list"]},
        {"notion_project_id": "related", "local_project_id": "p1", "name": "Unrelated title", "current_work": ["archive"]},
    ], 1)
    engine = RelevanceEngine(store, RelevanceSettings(minimum_score=0.05, cooldown_hours=24, max_results=5))
    first = engine.run(context(), now=100)
    idea = next(item for item in first.candidates if item["candidate_id"] == "notion_project:idea")
    related = next(item for item in first.candidates if item["candidate_id"] == "notion_project:related")
    assert idea["decision"] == "surface" and idea["explanation"]["lexical_match"] > 0
    assert related["explanation"]["explicit_relation"] == 1
    assert store.set_relevance_feedback(idea["candidate_id"], idea["source"], "p1", "snooze", 101, 200)
    second = engine.run(context(), now=102)
    suppressed = next(item for item in second.candidates if item["candidate_id"] == idea["candidate_id"])
    assert suppressed["suppression_reason"] == "snoozed"
    assert len(store.relevance_runs()) == 2
    store.close()


def test_additive_schema_opens_database_with_prior_tables(tmp_path):
    import sqlite3
    path = tmp_path / "old.db"
    original = WorkspaceStore(path)
    original.conn.execute("INSERT INTO events (id, ts, ts_iso, type, path, is_directory, area, area_kind, meaningful, raw_event_count) VALUES ('old-event', 1, 'old', 'modified', 'Projects/A/a.txt', 0, 'Projects', 'projects', 1, 1)")
    original.conn.commit()
    original.close()
    conn = sqlite3.connect(path)
    for table in ("relevance_documents", "relevance_runs", "relevance_candidates", "relevance_item_memory", "project_detection_decisions"):
        conn.execute(f"DROP TABLE {table}")
    conn.commit(); conn.close()
    store = WorkspaceStore(path)
    assert store.conn.execute("SELECT id FROM events").fetchone()["id"] == "old-event"
    assert store.conn.execute("SELECT name FROM sqlite_master WHERE name='relevance_item_memory'").fetchone()
    store.close()
