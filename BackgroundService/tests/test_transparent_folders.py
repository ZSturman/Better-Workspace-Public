from pathlib import Path

import pytest

from workspace_watcher.core_engine import IntentIndexer
from workspace_watcher.core_store import CoreStore
from workspace_watcher.ideas_v2 import list_ideas, register_idea, relocate_idea, update_idea
from workspace_watcher.intents import IntentFolderDetector, IntentFolderSettings
from workspace_watcher.private_items import load_record
from workspace_watcher.projects import ProjectRegistry
from workspace_watcher.projects_v2 import ProjectRegistry as ProjectRegistryV2
from workspace_watcher.store import WorkspaceStore
from workspace_watcher.transparent_folders import is_visible_child, visible_children


def test_idea_index_register_and_promotion_use_real_nested_paths(tmp_path):
    ideas, projects = tmp_path / "Ideas", tmp_path / "Projects"
    source = ideas / "_Group" / "_Nested" / "Studio"
    source.mkdir(parents=True); projects.mkdir()
    (source / "Original.txt").write_text("Keep the bytes")
    note = ideas / "_Group" / "_Note.md"; note.write_text("A file remains a file")
    (ideas / "_audit" / "Private").mkdir(parents=True)
    (ideas / "_Link").symlink_to(tmp_path, target_is_directory=True)
    settings = IntentFolderSettings(search_roots=(tmp_path,), declared=((ideas, "Ideas"),))
    with CoreStore(tmp_path / "core.db") as store:
        indexer = IntentIndexer(IntentFolderDetector(settings), store)
        indexer.rebuild()
        assert [Path(idea["path"]) for idea in list_ideas(store)] == [source]
        idea = register_idea(store, ideas, source)
        register_idea(store, ideas, note)
        planning = {"priority": 5, "ratings": {"qualityOfLife": 4}, "needsSetup": False}
        update_idea(store, idea["id"], {"planning": planning})
        indexer.rebuild()
        assert store.item_by_path(str(source))["id"] == idea["id"]
        assert len(list_ideas(store)) == 2
        destination = projects / "Studio"; source.rename(destination)
        result = relocate_idea(store, tmp_path, idea["id"], str(source), str(destination))
        assert relocate_idea(store, tmp_path, idea["id"], str(source), str(destination)) == result
        assert load_record(store, destination, prior=store.item_by_id(idea["id"])).planning == planning
        assert (destination / "Original.txt").read_text() == "Keep the bytes"
        destination.rename(source)
        restored = register_idea(store, ideas, source)
        if hasattr(source.stat(), "st_birthtime"):
            assert restored["id"] == idea["id"] and restored["planning"] == planning
        assert not list(tmp_path.rglob("watcher.item.toml"))


def test_visible_children_reject_metadata_symlinks_and_normal_nested_registration(tmp_path):
    ideas = tmp_path / "Ideas"; ideas.mkdir()
    ordinary = ideas / "Normal" / "Nested"; ordinary.mkdir(parents=True)
    (ideas / "_audit" / "Secret").mkdir(parents=True)
    (ideas / "_Link").symlink_to(ordinary, target_is_directory=True)
    assert visible_children(ideas) == [ideas / "Normal"]
    for path in [ordinary, ideas / "_audit" / "Secret", ideas / "_Link" / "File", ideas / ".." / "Escape"]:
        assert not is_visible_child(path, ideas)


def test_project_registry_skips_containers_and_keeps_child_identity(tmp_path):
    project = tmp_path / "Projects" / "_Group" / "_Nested" / "Studio"; project.mkdir(parents=True)
    (tmp_path / "Projects" / "_audit" / "Secret").mkdir(parents=True)
    (tmp_path / "Projects" / "_Link").symlink_to(tmp_path, target_is_directory=True)
    store = WorkspaceStore(tmp_path / "watcher.db")
    try:
        registry = ProjectRegistry(store, tmp_path, "Projects")
        refs = registry.reconcile_startup()
        assert [ref.path for ref in refs] == ["Projects/_Group/_Nested/Studio"]
        assert registry.project_root_relpath("Projects/_Group/_Nested/Studio/src/File.swift") == refs[0].path
        assert registry.project_root_relpath("Projects/_Group") is None
        assert registry.project_root_relpath("Projects/_audit/Secret") is None
        assert registry.resolve_for_relpath("Projects/_Link/Escape/File.swift") is None
    finally:
        store.close()


def test_v2_project_registry_preserves_project_identity_through_wrapper_move(tmp_path):
    source = tmp_path / "Projects" / "Studio"; source.mkdir(parents=True)
    with CoreStore(tmp_path / "core.db") as store:
        registry = ProjectRegistryV2(store, tmp_path, "Projects")
        registry.rebuild()
        original = store.projects()[0]["id"]
        target = tmp_path / "Projects" / "_Group" / "_Nested" / "Studio"
        target.parent.mkdir(parents=True); source.rename(target)
        assert registry.rebuild()["renamed"] == 1
        assert store.projects(status="active")[0]["id"] == original
        assert registry.resolve_for_relpath("Projects/_Group/_Nested/Studio/src/File.swift").project_id == original
        assert registry.project_root_relpath("Projects/_Group/_Nested") is None
        assert not (target / "Project.betterproject").exists()


def test_unreadable_wrapper_does_not_mark_previously_indexed_ideas_missing(tmp_path, monkeypatch):
    ideas = tmp_path / "Ideas"; source = ideas / "_Group" / "Studio"; source.mkdir(parents=True)
    settings = IntentFolderSettings(search_roots=(), declared=((ideas, "Ideas"),))
    with CoreStore(tmp_path / "core.db") as store:
        indexer = IntentIndexer(IntentFolderDetector(settings), store); indexer.rebuild()
        original = list_ideas(store)[0]["id"]
        iterdir = Path.iterdir
        def unreadable(path):
            if path == source.parent:
                raise PermissionError("Unavailable wrapper")
            return iterdir(path)
        monkeypatch.setattr(Path, "iterdir", unreadable)
        with pytest.raises(PermissionError):
            indexer.rebuild()
        assert list_ideas(store)[0]["id"] == original
