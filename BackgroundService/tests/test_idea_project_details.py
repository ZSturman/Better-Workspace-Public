from workspace_watcher.core_engine import IntentIndexer
from workspace_watcher.intents import IntentFolderDetector, IntentFolderSettings
from workspace_watcher.core_store import CoreStore
from workspace_watcher.ideas_v2 import create_idea, update_idea, idea_detail, validate_planning
from workspace_watcher.private_items import load_record
import pytest


def test_project_details_persist_in_private_planning_with_stale_checks(tmp_path):
    ideas = tmp_path / "[[Ideas]]"
    ideas.mkdir()
    planning = {"priority": 3, "ratings": {}, "potential": "project", "needsSetup": False,
                "project": {"metadata": {"domain": "Technology", "phase": "Planning", "projectType": "Application"},
                            "oneLiner": "Useful tool", "summary": "A complete idea", "automaticNotionSync": True}}
    with CoreStore(tmp_path / "private.db") as store:
        indexer = IntentIndexer(IntentFolderDetector(IntentFolderSettings(search_roots=(tmp_path,))), store)
        indexer.rebuild(initialize_missing_metadata=True)
        created = create_idea(store, ideas, "Studio")
        indexer.rebuild()
        saved = update_idea(store, created["id"], {"planning": planning, "expected_planning": None})
        assert saved["planning"] == planning
        assert idea_detail(store, created["id"])["planning"] == planning
        assert load_record(store, ideas / "Studio").planning == planning
        assert not (ideas / "Studio" / "watcher.item.toml").exists()
        changed = {**planning, "project": {**planning["project"], "summary": "New summary"}}
        with pytest.raises(ValueError, match="changed"):
            update_idea(store, created["id"], {"planning": changed, "expected_planning": None})
        update_idea(store, created["id"], {"planning": changed, "expected_planning": planning})
        assert idea_detail(store, created["id"])["planning"] == changed


def test_project_details_validation_and_legacy_compatibility():
    legacy = {"priority": 3, "ratings": {}, "potential": None, "needsSetup": False}
    validate_planning(legacy)
    with pytest.raises(ValueError):
        validate_planning({**legacy, "project": {"unexpected": "value"}})
    with pytest.raises(ValueError):
        validate_planning({**legacy, "project": {"metadata": {}, "oneLiner": "", "summary": "x" * 12001, "automaticNotionSync": True}})
