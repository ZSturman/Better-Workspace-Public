import json
import logging
from pathlib import Path

from workspace_watcher.project_index import ProjectIndex
from workspace_watcher.projects import ProjectRegistry
from workspace_watcher.store import WorkspaceStore


def _write_project(folder: Path, project_id: str = "core-alpha") -> None:
    meta = folder / ".project"
    (meta / "tasks").mkdir(parents=True)
    (meta / "project.json").write_text(json.dumps({"id": project_id, "name": "Alpha", "revision": 1, "domain": "Technology"}))
    (meta / "tasks" / "task-1.json").write_text(json.dumps({"id": "task-1", "project_id": project_id, "title": "Index it", "status": "next"}))


def test_rebuild_indexes_unknown_folder_quietly_then_notifies_once_when_it_is_active(tmp_path):
    root = tmp_path / "Workspace"
    projects = root / "Projects"
    _write_project(projects / "Alpha")
    (projects / "Unmapped Folder").mkdir(parents=True)
    store = WorkspaceStore(tmp_path / "watcher.db")
    notifications = []
    registry = ProjectRegistry(store, root, "Projects")
    index = ProjectIndex(store, registry, root, "Projects", logging.getLogger("test"), lambda title, body: notifications.append((title, body)))

    first = index.rebuild(reason="test")
    second = index.rebuild(reason="test")

    rows = store.conn.execute("SELECT * FROM local_project_index ORDER BY name").fetchall()
    assert first["projects"] == 2 and second["generation"] == first["generation"] + 1
    assert [(row["name"], row["managed"]) for row in rows] == [("Alpha", 1), ("Unmapped Folder", 0)]
    assert store.conn.execute("SELECT COUNT(*) FROM local_project_entities").fetchone()[0] == 1
    assert len(store.reconciliation_issues("open")) == 1
    # Mere discovery is not notification-worthy. An unknown folder must first
    # become a meaningfully active project.
    unknown = store.get_project_by_path("Projects/Unmapped Folder")
    assert index.notify_if_actively_used(unknown["project_id"])
    assert not index.notify_if_actively_used(unknown["project_id"])
    assert len(notifications) == 1


def test_metadata_added_resolves_prior_unknown_issue_without_reusing_notification(tmp_path):
    root, projects = tmp_path / "Workspace", tmp_path / "Workspace" / "Projects"
    folder = projects / "Later Managed"
    folder.mkdir(parents=True)
    store = WorkspaceStore(tmp_path / "watcher.db")
    registry = ProjectRegistry(store, root, "Projects")
    index = ProjectIndex(store, registry, root, "Projects", logging.getLogger("test"))
    index.rebuild(reason="first")
    _write_project(folder, "later-managed")
    index.rebuild(reason="metadata_created")

    assert not store.reconciliation_issues("open")
    assert store.reconciliation_issues("resolved")[0]["kind"] == "unknown_local_folder"
