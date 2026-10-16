"""v2's own project identity: discovery, rename survival, and deletion."""

from __future__ import annotations

import shutil
from pathlib import Path

from workspace_watcher.core_events import EventTypes
from workspace_watcher.core_store import CoreStore
from workspace_watcher.projects_v2 import ProjectRegistry


def _registry(tmp_path: Path, store: CoreStore) -> ProjectRegistry:
    return ProjectRegistry(store, tmp_path, "Projects")


def test_discovering_a_new_project_creates_one_row_and_an_event(tmp_path):
    (tmp_path / "Projects" / "Foo").mkdir(parents=True)
    with CoreStore(tmp_path / "core.db") as store:
        registry = _registry(tmp_path, store)
        summary = registry.rebuild()
        assert summary["discovered"] == 1
        rows = store.projects()
        assert len(rows) == 1 and rows[0]["name"] == "Foo" and rows[0]["path"] == "Projects/Foo"
        assert any(row["type"] == EventTypes.PROJECT_DISCOVERED for row in store.recent_events(20))


def test_rebuild_is_idempotent_and_creates_no_restart_noise(tmp_path):
    (tmp_path / "Projects" / "Foo").mkdir(parents=True)
    with CoreStore(tmp_path / "core.db") as store:
        registry = _registry(tmp_path, store)
        registry.rebuild()
        events_after_first = len(store.recent_events(100))
        registry.rebuild()
        assert len(store.recent_events(100)) == events_after_first


def test_rename_via_inode_match_preserves_identity_and_history(tmp_path):
    foo = tmp_path / "Projects" / "Foo"
    foo.mkdir(parents=True)
    with CoreStore(tmp_path / "core.db") as store:
        registry = _registry(tmp_path, store)
        registry.rebuild()
        project_id = store.projects()[0]["id"]

        # Simulate a rename that happened while nothing was watching: the
        # directory moves on disk, then a *new* ProjectRegistry (fresh cache,
        # same store) is asked to reconcile -- it must match by inode, not path.
        bar = tmp_path / "Projects" / "Bar"
        foo.rename(bar)
        restarted = _registry(tmp_path, store)
        summary = restarted.rebuild()
        assert summary["renamed"] == 1
        assert summary["discovered"] == 0

        rows = store.projects()
        assert len(rows) == 1
        assert rows[0]["id"] == project_id
        assert rows[0]["name"] == "Bar" and rows[0]["path"] == "Projects/Bar"
        history = __import__("json").loads(rows[0]["name_history_json"])
        assert history and history[0]["name"] == "Foo"
        assert any(row["type"] == EventTypes.PROJECT_RENAMED for row in store.recent_events(20))


def test_deep_file_resolves_to_its_top_level_project(tmp_path):
    (tmp_path / "Projects" / "Foo" / "src" / "lib").mkdir(parents=True)
    with CoreStore(tmp_path / "core.db") as store:
        registry = _registry(tmp_path, store)
        registry.rebuild()
        ref = registry.resolve_for_relpath("Projects/Foo/src/lib/x.ts")
        assert ref is not None
        assert ref.name == "Foo" and ref.path == "Projects/Foo"


def test_dotfile_prefixed_top_level_entry_is_never_a_project(tmp_path):
    (tmp_path / "Projects" / ".project-core").mkdir(parents=True)
    with CoreStore(tmp_path / "core.db") as store:
        registry = _registry(tmp_path, store)
        summary = registry.rebuild()
        assert summary["discovered"] == 0
        assert store.projects() == []
        assert registry.resolve_for_relpath("Projects/.project-core/x") is None


def test_delete_then_recreate_same_name_gets_a_new_identity(tmp_path):
    foo = tmp_path / "Projects" / "Foo"
    foo.mkdir(parents=True)
    with CoreStore(tmp_path / "core.db") as store:
        registry = _registry(tmp_path, store)
        registry.rebuild()
        original_id = store.projects()[0]["id"]

        # A managed project now contains its visible Project.betterproject
        # document, so model a Finder-style directory deletion rather than
        # relying on the former empty-folder implementation detail.
        shutil.rmtree(foo)
        registry.rebuild()
        assert store.projects() == []  # marked deleted, not returned by the active-only default
        deleted = store.projects(status="deleted")
        assert len(deleted) == 1 and deleted[0]["id"] == original_id
        assert any(row["type"] == EventTypes.PROJECT_DELETED for row in store.recent_events(20))

        foo.mkdir()
        registry.rebuild()
        rows = store.projects()
        assert len(rows) == 1
        assert rows[0]["id"] != original_id


def test_a_reused_name_after_rename_does_not_merge_identities(tmp_path):
    # Foo is renamed to Gamma, then a brand new directory is created named
    # "Foo" (the old name reappears). The new "Foo" must get its own fresh
    # identity, never be confused with the project that used to be called
    # that.
    foo = tmp_path / "Projects" / "Foo"
    foo.mkdir(parents=True)
    with CoreStore(tmp_path / "core.db") as store:
        registry = _registry(tmp_path, store)
        registry.rebuild()
        original_id = store.projects()[0]["id"]

        (tmp_path / "Projects" / "Foo").rename(tmp_path / "Projects" / "Gamma")
        registry.rebuild()
        (tmp_path / "Projects" / "Foo").mkdir()
        registry.rebuild()

        rows = {row["name"]: row for row in store.projects()}
        assert set(rows) == {"Gamma", "Foo"}
        assert rows["Gamma"]["id"] == original_id  # the renamed project kept its identity
        assert rows["Foo"]["id"] != original_id  # the new directory reusing the old name is a distinct project
        assert registry.resolve_for_relpath("Projects/Gamma/x").project_id == original_id
        assert registry.resolve_for_relpath("Projects/Foo/x").project_id == rows["Foo"]["id"]


def test_moving_a_project_out_of_the_tracked_root_is_treated_as_deletion(tmp_path):
    # A directory that stops being an immediate child of the tracked root
    # (moved deeper, or moved away entirely) is indistinguishable from
    # deletion from the registry's perspective -- it is no longer a project
    # by this model's own definition, regardless of whether the directory
    # still exists somewhere on disk.
    foo = tmp_path / "Projects" / "Foo"
    foo.mkdir(parents=True)
    with CoreStore(tmp_path / "core.db") as store:
        registry = _registry(tmp_path, store)
        registry.rebuild()
        original_id = store.projects()[0]["id"]

        nested_parent = tmp_path / "Projects" / "Archive"
        nested_parent.mkdir()
        foo.rename(nested_parent / "Foo")
        registry.rebuild()

        assert "Foo" not in {row["name"] for row in store.projects()}  # no longer active under its old name
        deleted = store.projects(status="deleted")
        assert len(deleted) == 1 and deleted[0]["id"] == original_id
        # "Archive" itself is now a real top-level project by the same rule
        # that made "Foo" one -- a path under it resolves to Archive, not to
        # Foo's old (now-deleted) identity, and never to nothing.
        archive_ref = registry.resolve_for_relpath("Projects/Archive/Foo/x")
        assert archive_ref is not None and archive_ref.name == "Archive" and archive_ref.project_id != original_id
