import os
import time

import pytest

from workspace_watcher.projects import ProjectRegistry
from workspace_watcher.store import WorkspaceStore


@pytest.fixture
def workspace(tmp_path):
    (tmp_path / "Projects").mkdir()
    return tmp_path


@pytest.fixture
def store(tmp_path):
    s = WorkspaceStore(tmp_path / "data" / "events.db")
    yield s
    s.close()


def make_registry(store, workspace_root):
    return ProjectRegistry(store, workspace_root, "Projects")


def test_ensure_project_creates_new_identity(workspace, store):
    (workspace / "Projects" / "Alpha").mkdir()
    reg = make_registry(store, workspace)
    ref = reg.ensure_project("Projects/Alpha", workspace / "Projects" / "Alpha", time.time())
    assert ref.name == "Alpha"
    assert ref.project_id
    row = store.get_project_by_path("Projects/Alpha")
    assert row is not None
    assert row["project_id"] == ref.project_id


def test_resolve_for_relpath_resolves_nested_files_to_project_root(workspace, store):
    (workspace / "Projects" / "Alpha" / "src").mkdir(parents=True)
    reg = make_registry(store, workspace)
    root_ref = reg.ensure_project("Projects/Alpha", workspace / "Projects" / "Alpha", time.time())

    nested = reg.resolve_for_relpath("Projects/Alpha/src/main.py")
    assert nested is not None
    assert nested.project_id == root_ref.project_id


def test_resolve_for_relpath_outside_projects_is_none(workspace, store):
    reg = make_registry(store, workspace)
    assert reg.resolve_for_relpath("Unsorted/file.txt") is None
    assert reg.resolve_for_relpath("Projects") is None


def test_rename_preserves_project_identity(workspace, store):
    (workspace / "Projects" / "Alpha").mkdir()
    reg = make_registry(store, workspace)
    original = reg.ensure_project("Projects/Alpha", workspace / "Projects" / "Alpha", time.time())

    ref = reg.handle_root_moved("Projects/Alpha", "Projects/Beta", time.time())
    assert ref.project_id == original.project_id
    assert ref.name == "Beta"

    row = store.get_project(original.project_id)
    assert row["path"] == "Projects/Beta"
    assert row["name"] == "Beta"
    history = row["name_history_json"]
    assert "Alpha" in history and "Beta" in history


def test_delete_marks_status_deleted(workspace, store):
    (workspace / "Projects" / "Alpha").mkdir()
    reg = make_registry(store, workspace)
    ref = reg.ensure_project("Projects/Alpha", workspace / "Projects" / "Alpha", time.time())
    reg.handle_root_deleted("Projects/Alpha")

    assert store.get_project(ref.project_id)["status"] == "deleted"
    assert all(p["project_id"] != ref.project_id for p in store.all_projects(status="active"))


def test_reconcile_startup_detects_new_projects(workspace, store):
    (workspace / "Projects" / "Alpha").mkdir()
    (workspace / "Projects" / "Beta").mkdir()
    reg = make_registry(store, workspace)

    newly = reg.reconcile_startup()
    names = {r.name for r in newly}
    assert names == {"Alpha", "Beta"}
    assert len(store.all_projects(status="active")) == 2


def test_hidden_top_level_directories_are_not_projects(workspace, store):
    """Workspace-owned indexes must not leak into the user project registry."""
    (workspace / "Projects" / ".project-core").mkdir()
    (workspace / "Projects" / ".project-core" / "index.sqlite3").touch()
    (workspace / "Projects" / "Alpha" / ".git").mkdir(parents=True)
    reg = make_registry(store, workspace)

    newly = reg.reconcile_startup()

    assert [ref.name for ref in newly] == ["Alpha"]
    assert reg.resolve_for_relpath("Projects/.project-core/index.sqlite3") is None
    assert [row["name"] for row in store.all_projects(status="active")] == ["Alpha"]


def test_reconcile_startup_matches_offline_rename_by_inode(workspace, store):
    (workspace / "Projects" / "Alpha").mkdir()
    reg = make_registry(store, workspace)
    reg.reconcile_startup()
    original = store.get_project_by_path("Projects/Alpha")
    project_id = original["project_id"]

    # Simulate the watcher being down during a rename.
    os.rename(workspace / "Projects" / "Alpha", workspace / "Projects" / "Renamed")

    reg2 = make_registry(store, workspace)  # fresh registry, fresh cache load
    newly = reg2.reconcile_startup()

    assert newly == []  # matched by inode, not treated as a brand new project
    row = store.get_project(project_id)
    assert row["path"] == "Projects/Renamed"
    assert row["name"] == "Renamed"


def test_reconcile_startup_marks_removed_projects_deleted(workspace, store):
    (workspace / "Projects" / "Alpha").mkdir()
    reg = make_registry(store, workspace)
    reg.reconcile_startup()

    import shutil
    shutil.rmtree(workspace / "Projects" / "Alpha")

    reg2 = make_registry(store, workspace)
    reg2.reconcile_startup()

    assert store.all_projects(status="active") == []
    assert store.all_projects(status="deleted")[0]["name"] == "Alpha"
