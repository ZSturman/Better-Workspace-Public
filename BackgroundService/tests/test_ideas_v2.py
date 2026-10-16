"""ideas_v2.py: the Ideas tab's read/write model over the same intent-item,
tag, and relationship tables every other v2 surface uses."""

from __future__ import annotations

from workspace_watcher.core_engine import IntentIndexer
from workspace_watcher.core_store import CoreStore
from workspace_watcher.ideas_v2 import create_idea, idea_detail, list_ideas, resurfacing_view, update_idea
from workspace_watcher.intents import IntentFolderDetector, IntentFolderSettings
from workspace_watcher.private_items import load_record


def _indexer(store: CoreStore, tmp_path) -> IntentIndexer:
    settings = IntentFolderSettings(search_roots=(tmp_path,))
    return IntentIndexer(IntentFolderDetector(settings), store)


def test_create_idea_stores_metadata_privately_and_is_immediately_listed(tmp_path):
    ideas_folder = tmp_path / "[[Ideas]]"
    ideas_folder.mkdir()
    with CoreStore(tmp_path / "core.db") as store:
        indexer = _indexer(store, tmp_path)
        indexer.rebuild(initialize_missing_metadata=True)  # discovers the empty folder
        created = create_idea(store, ideas_folder, "  A Brand New Idea  ")
        assert not (ideas_folder / "A Brand New Idea" / "watcher.item.toml").exists()
        record = load_record(store, ideas_folder / "A Brand New Idea")
        assert record.type == "unclassified" and record.id == created["id"]
        ideas = list_ideas(store)
        assert any(row["id"] == created["id"] and row["title"] == "A Brand New Idea" for row in ideas)


def test_create_idea_rejects_a_blank_title(tmp_path):
    ideas_folder = tmp_path / "[[Ideas]]"
    ideas_folder.mkdir()
    with CoreStore(tmp_path / "core.db") as store:
        try:
            create_idea(store, ideas_folder, "   ")
            assert False, "expected a ValueError"
        except ValueError:
            pass


def test_create_idea_rejects_a_duplicate_name(tmp_path):
    ideas_folder = tmp_path / "[[Ideas]]"
    ideas_folder.mkdir()
    with CoreStore(tmp_path / "core.db") as store:
        create_idea(store, ideas_folder, "Same Name")
        try:
            create_idea(store, ideas_folder, "Same Name")
            assert False, "expected a ValueError"
        except ValueError:
            pass


def test_update_idea_edits_fields_reconciles_tags_and_persists_to_disk(tmp_path):
    ideas_folder = tmp_path / "[[Ideas]]"
    ideas_folder.mkdir()
    with CoreStore(tmp_path / "core.db") as store:
        indexer = _indexer(store, tmp_path)
        indexer.rebuild(initialize_missing_metadata=True)
        created = create_idea(store, ideas_folder, "Editable Idea")
        indexer.rebuild()  # index the freshly created idea itself

        detail = update_idea(store, created["id"], {
            "type": "feature", "status": "exploring", "tags": ["ai", "developer tools"],
            "one_liner": "Ship it", "description": "Longer description here.",
        })
        assert detail["type"] == "feature" and detail["status"] == "exploring"
        assert set(detail["tags"]) == {"ai", "developer tools"}

        # Persisted in the service-owned record:
        record = load_record(store, ideas_folder / "Editable Idea")
        assert record.type == "feature" and set(record.tags) == {"ai", "developer tools"}

        # Canonical tags were reconciled so they're comparable to project tags:
        canonical = {row["display"] for row in store.tags_for_item(created["id"])}
        assert canonical == {"ai", "developer tools"}

        full = idea_detail(store, created["id"])
        assert full["description"] == "Longer description here."


def test_update_idea_rejects_unknown_fields(tmp_path):
    ideas_folder = tmp_path / "[[Ideas]]"
    ideas_folder.mkdir()
    with CoreStore(tmp_path / "core.db") as store:
        indexer = _indexer(store, tmp_path)
        indexer.rebuild(initialize_missing_metadata=True)
        created = create_idea(store, ideas_folder, "Idea")
        indexer.rebuild()
        try:
            update_idea(store, created["id"], {"id": "not-allowed"})
            assert False, "expected a ValueError"
        except ValueError:
            pass


def test_update_idea_project_association_is_optional_and_self_heals(tmp_path):
    """An idea naming a project that doesn't exist yet stays a perfectly
    valid standalone idea; the association appears once the project is
    discovered on a later reconcile -- it never blocks on ordering."""
    ideas_folder = tmp_path / "[[Ideas]]"
    ideas_folder.mkdir()
    (tmp_path / "Projects" / "Demo Project").mkdir(parents=True)
    with CoreStore(tmp_path / "core.db") as store:
        indexer = _indexer(store, tmp_path)
        indexer.rebuild(initialize_missing_metadata=True)
        created = create_idea(store, ideas_folder, "Idea With Project")
        indexer.rebuild()
        detail = update_idea(store, created["id"], {"related_projects": ["Nonexistent Project"]})
        assert detail["related_projects"] == ["Nonexistent Project"]  # preserve the chosen name before discovery

        store.create_project(project_id="proj-1", path="Projects/Demo Project", root_path="Projects", name="Demo Project", device=None, inode=None, timestamp="2026-01-01T00:00:00+00:00")
        update_idea(store, created["id"], {"related_projects": ["Demo Project"]})
        detail = idea_detail(store, created["id"])
        assert detail["related_projects"] == ["Demo Project"]


def test_resurfacing_view_only_lists_ideas_currently_surfaced(tmp_path):
    ideas_folder = tmp_path / "[[Ideas]]"
    ideas_folder.mkdir()
    with CoreStore(tmp_path / "core.db") as store:
        indexer = _indexer(store, tmp_path)
        indexer.rebuild(initialize_missing_metadata=True)
        created = create_idea(store, ideas_folder, "Never Surfaced")
        indexer.rebuild()
        assert resurfacing_view(store) == []
        store.remember_resurfacing(created["id"], now="2026-01-01T00:00:00+00:00", surfaced=True, score=0.9, reasons={"signals": ["test"]})
        surfaced = resurfacing_view(store)
        assert len(surfaced) == 1 and surfaced[0]["id"] == created["id"]


def test_planning_registers_files_without_editing_them_and_refuses_stale_scores(tmp_path):
    from workspace_watcher.ideas_v2 import register_idea
    ideas = tmp_path / "[[Ideas]]"
    ideas.mkdir()
    note = ideas / "Potential project.md"
    note.write_text("Original idea and attachments stay here")
    with CoreStore(tmp_path / "core.db") as store:
        indexer = _indexer(store, tmp_path)
        indexer.rebuild(initialize_missing_metadata=True)
        idea = register_idea(store, ideas, note)
        original = idea["planning"]
        assert original["needsSetup"] is True
        planning = {"priority": 5, "ratings": {"qualityOfLife": 5, "effort": 1}, "potential": "project", "needsSetup": False}
        result = update_idea(store, idea["id"], {"planning": planning, "expected_planning": original})
        assert result["planning"] == planning
        indexer.rebuild()
        assert next(i for i in list_ideas(store) if i["id"] == idea["id"])["planning"] == planning
        assert note.read_text() == "Original idea and attachments stay here"
        assert list(ideas.iterdir()) == [note]
        assert update_idea(store, idea["id"], {"planning": planning, "expected_planning": original})["planning"] == planning
        with __import__("pytest").raises(ValueError, match="changed"):
            update_idea(store, idea["id"], {"planning": {**planning, "priority": 1}, "expected_planning": original})
        with __import__("pytest").raises(ValueError):
            update_idea(store, idea["id"], {"planning": {**planning, "priority": True}})


def test_folder_promotion_relocation_preserves_private_metadata_and_remote_link(tmp_path):
    from workspace_watcher.ideas_v2 import register_idea, relocate_idea
    workspace = tmp_path / "Workspace"
    ideas = workspace / "Ideas"
    projects = workspace / "Projects"
    ideas.mkdir(parents=True); projects.mkdir()
    source = ideas / "Keep everything"
    source.mkdir(); (source / "asset.txt").write_text("Original")
    with CoreStore(tmp_path / "core.db") as store:
        store.upsert_intent_folder(folder_id="ideas", path=str(ideas), root_path=str(workspace), name="Ideas", config={}, timestamp="2026-10-13T00:00:00+00:00")
        idea = register_idea(store, ideas, source)
        store.upsert_idea_notion_link(idea["id"], notion_page_id="existing-page", synced_hash="baseline", notion_last_edited_time="2026-10-12T00:00:00Z", sync_error=None, timestamp="2026-10-13T00:00:00Z")
        planning = {"priority": 5, "ratings": {"qualityOfLife": 5}, "potential": "project", "needsSetup": False}
        update_idea(store, idea["id"], {"planning": planning})
        destination = projects / source.name
        source.rename(destination)
        result = relocate_idea(store, workspace, idea["id"], str(source), str(destination))
        assert result["path"] == str(destination)
        assert list_ideas(store) == []
        assert store.idea_notion_link(idea["id"])["notion_page_id"] == "existing-page"
        assert store.idea_notion_link(idea["id"])["synced_hash"] == "baseline"
        private = load_record(store, destination, prior=store.item_by_id(idea["id"]))
        assert private.planning == planning
        assert (destination / "asset.txt").read_text() == "Original"
        assert relocate_idea(store, workspace, idea["id"], str(source), str(destination)) == result
        destination.rename(source)
        returned = register_idea(store, ideas, source)
        if hasattr(source.stat(), "st_birthtime"):
            assert returned["id"] == idea["id"]
            assert returned["planning"] == planning



def test_stale_background_candidate_preserves_new_user_planning_and_promotion(tmp_path):
    from workspace_watcher.ideas_v2 import register_idea, relocate_idea
    from workspace_watcher.private_items import save_indexed_record
    ideas = tmp_path / "Ideas"; projects = tmp_path / "Projects"
    ideas.mkdir(); projects.mkdir()
    folder = ideas / "Planning"; folder.mkdir()
    with CoreStore(tmp_path / "core.db") as store:
        store.upsert_intent_folder(folder_id="ideas", path=str(ideas), root_path=str(tmp_path), name="Ideas", config={}, timestamp="2026-10-13T00:00:00+00:00")
        idea = register_idea(store, ideas, folder)
        stale = load_record(store, folder)
        info = folder.stat()
        planning = {"priority": 5, "ratings": {"qualityOfLife": 5}, "potential": "project", "needsSetup": False}
        update_idea(store, idea["id"], {"planning": planning})
        refreshed = save_indexed_record(store, folder, stale, "ideas", info, "2026-10-13T01:00:00+00:00")
        assert refreshed.planning == planning
        assert idea_detail(store, idea["id"])["planning"] == planning
        destination = projects / folder.name
        folder.rename(destination)
        relocate_idea(store, tmp_path, idea["id"], str(folder), str(destination))
        assert save_indexed_record(store, folder, stale, "ideas", info, "2026-10-13T02:00:00+00:00") is None
        assert load_record(store, destination).planning == planning
