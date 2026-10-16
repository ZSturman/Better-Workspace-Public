"""Built-in saved views: seeded once, idempotent, distinguishable from
user-created ones, and never deletable through the store's own backstop."""

from __future__ import annotations

from workspace_watcher.core_store import CoreStore
from workspace_watcher.project_query_v2 import ensure_builtin_saved_views


def test_built_in_views_are_seeded(tmp_path):
    with CoreStore(tmp_path / "core.db") as store:
        ensure_builtin_saved_views(store)
        rows = store.saved_views()
        assert len(rows) == 7
        assert all(row["built_in"] == 1 for row in rows)


def test_seeding_twice_does_not_duplicate(tmp_path):
    with CoreStore(tmp_path / "core.db") as store:
        ensure_builtin_saved_views(store)
        ensure_builtin_saved_views(store)
        assert len(store.saved_views()) == 7


def test_a_built_in_view_cannot_be_deleted(tmp_path):
    with CoreStore(tmp_path / "core.db") as store:
        ensure_builtin_saved_views(store)
        view_id = store.saved_views()[0]["id"]
        assert store.delete_saved_view(view_id) is False
        assert store.saved_view_by_id(view_id) is not None


def test_a_user_created_view_can_be_created_updated_and_deleted(tmp_path):
    with CoreStore(tmp_path / "core.db") as store:
        row = store.create_saved_view({
            "id": "user-1", "name": "My View", "query_json": "{}", "sort_field": "score", "sort_direction": "desc",
            "group_by": None, "built_in": 0, "sort_order": 99, "created_at": "2026-01-01T00:00:00+00:00", "updated_at": "2026-01-01T00:00:00+00:00",
        })
        assert row["built_in"] == 0

        updated = store.update_saved_view("user-1", {"name": "Renamed View", "updated_at": "2026-01-02T00:00:00+00:00"})
        assert updated["name"] == "Renamed View"

        assert store.delete_saved_view("user-1") is True
        assert store.saved_view_by_id("user-1") is None


def test_built_in_and_user_views_are_distinguishable_in_a_combined_listing(tmp_path):
    with CoreStore(tmp_path / "core.db") as store:
        ensure_builtin_saved_views(store)
        store.create_saved_view({
            "id": "user-1", "name": "Mine", "query_json": "{}", "sort_field": "score", "sort_direction": "desc",
            "group_by": None, "built_in": 0, "sort_order": 0, "created_at": "2026-01-01T00:00:00+00:00", "updated_at": "2026-01-01T00:00:00+00:00",
        })
        rows = store.saved_views()
        assert sum(1 for r in rows if r["built_in"]) == 7
        assert sum(1 for r in rows if not r["built_in"]) == 1
