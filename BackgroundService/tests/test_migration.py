"""Proves a database created before intent folders existed opens cleanly:
new tables appear, and relevance_item_memory gains its three new columns
without losing any existing row."""

from __future__ import annotations

import sqlite3

from workspace_watcher.store import WorkspaceStore


def test_pre_intent_database_migrates_additively(tmp_path):
    path = tmp_path / "old.db"
    original = WorkspaceStore(path)
    original.create_project("p1", "Projects/Alpha", "Alpha", None, None, 0)
    original.upsert_relevance_memory({
        "candidate_id": "old:candidate", "source": "old_source", "project_id": "p1",
        "first_seen_at": 1, "last_considered_at": 2, "accepted_at": 3, "most_recent_score": 0.9,
    })
    original.close()

    # Simulate a database from before this change: drop the new tables and
    # the three columns relevance_item_memory gained.
    conn = sqlite3.connect(path)
    for table in ("items", "tags", "tag_aliases", "item_tags", "work_log_manual_entries"):
        conn.execute(f"DROP TABLE IF EXISTS {table}")
    conn.execute(
        """CREATE TABLE relevance_item_memory_old AS
           SELECT candidate_id, source, project_id, first_seen_at, last_considered_at,
                  last_surfaced_at, surfaced_count, last_dismissed_at, dismissal_count,
                  snoozed_until, accepted_at, most_recent_score, evidence_json
           FROM relevance_item_memory"""
    )
    conn.execute("DROP TABLE relevance_item_memory")
    conn.execute("ALTER TABLE relevance_item_memory_old RENAME TO relevance_item_memory")
    conn.commit()
    conn.close()

    migrated = WorkspaceStore(path)
    try:
        assert migrated.conn.execute("SELECT name FROM sqlite_master WHERE name='items'").fetchone()
        assert migrated.conn.execute("SELECT name FROM sqlite_master WHERE name='tags'").fetchone()
        row = migrated.get_relevance_memory("old:candidate", "old_source", "p1")
        assert row is not None
        assert row["accepted_at"] == 3  # pre-existing data survived
        assert row["status"] is None  # new column present, defaulted
        project = migrated.get_project_by_path("Projects/Alpha")
        assert project is not None and project["name"] == "Alpha"
    finally:
        migrated.close()
