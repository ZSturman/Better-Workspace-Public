from __future__ import annotations

import json

from workspace_watcher.project_documents import DOCUMENT_FILENAME, ensure_document, read_document
from workspace_watcher.core_store import CoreStore
from workspace_watcher.projects_v2 import ProjectRegistry


def test_document_is_created_in_the_project_folder_with_stable_workspace_identity(tmp_path):
    folder = tmp_path / "Projects" / "Alpha"
    folder.mkdir(parents=True)

    path = ensure_document(folder, workspace_project_id="workspace-alpha", title="Alpha", notion_project_id="notion-alpha")

    assert path == folder / DOCUMENT_FILENAME
    value = json.loads(path.read_text())
    assert value["formatVersion"] == 1
    assert value["workspaceProjectID"] == "workspace-alpha"
    assert value["notionProjectID"] == "notion-alpha"
    assert value["projectDirectoryPath"] == str(folder.resolve())
    assert read_document(folder) == value


def test_watcher_adopts_a_valid_better_projects_document_without_workspace_identity(tmp_path):
    folder = tmp_path / "Projects" / "Alpha"
    folder.mkdir(parents=True)
    path = folder / DOCUMENT_FILENAME
    path.write_text(json.dumps({
        "formatVersion": 1,
        "documentID": "document-alpha",
        "workspaceProjectID": None,
        "notionProjectID": "notion-alpha",
        "title": "Alpha",
        "projectDirectoryPath": str(folder),
        "selectedSection": "project",
    }), encoding="utf-8")

    refreshed = ensure_document(folder, workspace_project_id="workspace-alpha", title="Alpha", notion_project_id="notion-alpha")
    value = read_document(folder)

    assert refreshed == path
    assert value is not None
    assert value["documentID"] == "document-alpha"
    assert value["workspaceProjectID"] == "workspace-alpha"
    assert value["notionProjectID"] == "notion-alpha"


def test_directory_reconciliation_preserves_document_identity_and_user_section(tmp_path):
    old = tmp_path / "Projects" / "Alpha"
    old.mkdir(parents=True)
    path = ensure_document(old, workspace_project_id="workspace-alpha", title="Alpha", notion_project_id=None)
    first = json.loads(path.read_text())
    first["selectedSection"] = "tasks"
    path.write_text(json.dumps(first), encoding="utf-8")

    moved = tmp_path / "Projects" / "Renamed Alpha"
    old.rename(moved)
    refreshed = ensure_document(moved, workspace_project_id="workspace-alpha", title="Renamed Alpha", notion_project_id="notion-alpha")
    value = json.loads(refreshed.read_text())

    assert value["documentID"] == first["documentID"]
    assert value["selectedSection"] == "tasks"
    assert value["notionProjectID"] == "notion-alpha"
    assert value["projectDirectoryPath"] == str(moved.resolve())


def test_project_registry_creates_the_document_when_asked_to(tmp_path):
    folder = tmp_path / "Projects" / "Alpha"
    folder.mkdir(parents=True)

    with CoreStore(tmp_path / "events.db") as store:
        ProjectRegistry(store, tmp_path, "Projects", write_documents=True).rebuild()
        project = store.projects()[0]

    value = json.loads((folder / DOCUMENT_FILENAME).read_text())
    assert value["workspaceProjectID"] == project["id"]
    assert value["projectDirectoryPath"] == str(folder.resolve())


def test_by_default_discovery_writes_nothing_into_a_new_project_folder(tmp_path):
    # Better Workspace no longer needs the Better Projects bridge document; the
    # service must not put a file in every project someone creates.
    folder = tmp_path / "Projects" / "Alpha"
    folder.mkdir(parents=True)

    with CoreStore(tmp_path / "events.db") as store:
        ProjectRegistry(store, tmp_path, "Projects").rebuild()
        assert len(store.projects()) == 1

    assert list(folder.iterdir()) == []


def test_by_default_an_existing_document_is_left_byte_for_byte_through_a_rename(tmp_path):
    folder = tmp_path / "Projects" / "Alpha"
    folder.mkdir(parents=True)
    original = '{"formatVersion": 1, "documentID": "doc", "workspaceProjectID": null}'
    (folder / DOCUMENT_FILENAME).write_text(original)

    with CoreStore(tmp_path / "events.db") as store:
        registry = ProjectRegistry(store, tmp_path, "Projects")
        registry.rebuild()
        moved = tmp_path / "Projects" / "Beta"
        folder.rename(moved)
        registry.rebuild()

    assert (moved / DOCUMENT_FILENAME).read_text() == original
