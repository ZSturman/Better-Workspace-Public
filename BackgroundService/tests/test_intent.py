from __future__ import annotations

from pathlib import Path

from workspace_watcher.config import default_config
from workspace_watcher.intent import IntentFolderIndex, IntentItemIndex, IntentMatch, classify_intent
from workspace_watcher.item_metadata import parse_item_metadata, upsert_item_toml_fields
from workspace_watcher.store import WorkspaceStore
from workspace_watcher.tags import normalize_tag, split_tag_list


def test_normalize_and_split_tags():
    assert normalize_tag("  Simplistic  UX ") == "simplistic ux"
    assert normalize_tag("Dashboard-Design") == normalize_tag("Dashboard Design")
    assert split_tag_list("Dashboard design, Simplistic UX; Navigation") == ["Dashboard design", "Simplistic UX", "Navigation"]
    assert split_tag_list(["A", "a", "B"]) == ["A", "B"]  # de-duplicated by normalized form, first spelling wins


def test_classify_intent_matches_nested_and_deep_paths():
    cfg = default_config(Path("/workspace"))
    index = IntentFolderIndex.from_config(cfg)
    top = classify_intent("For Inspiration/Dashboard Screenshots", cfg, index)
    assert isinstance(top, IntentMatch) and top.folder.name == "For Inspiration" and not top.is_folder_root
    nested = classify_intent("For Inspiration/Dashboard Screenshots/notes/inner.png", cfg, index)
    assert nested is not None and nested.item_relpath == "For Inspiration/Dashboard Screenshots"
    root_event = classify_intent("For Inspiration", cfg, index)
    assert root_event is not None and root_event.is_folder_root
    assert classify_intent("Projects/Some App/src/main.py", cfg, index) is None


def test_classify_intent_respects_roots_scope():
    cfg = default_config(Path("/workspace"))
    cfg.intent.roots = ["Ideas"]
    index = IntentFolderIndex.from_config(cfg)
    assert classify_intent("Ideas/For Inspiration/X", cfg, index) is not None
    assert classify_intent("Resources/For Inspiration/X", cfg, index) is None


def test_item_metadata_round_trip(tmp_path):
    item_dir = tmp_path / "Dashboard Screenshots"
    item_dir.mkdir()
    toml_path = item_dir / ".item.toml"
    upsert_item_toml_fields(toml_path, {"tags": ["Dashboard design", "Simplistic UX"], "priority": "low", "after_inactive": "90d"})
    metadata = parse_item_metadata(toml_path)
    assert metadata is not None
    assert metadata.tags == ["Dashboard design", "Simplistic UX"]
    assert metadata.priority == "low"
    assert metadata.after_inactive == "90d"
    # A targeted update preserves the other fields.
    upsert_item_toml_fields(toml_path, {"priority": "high"})
    metadata2 = parse_item_metadata(toml_path)
    assert metadata2.priority == "high"
    assert metadata2.tags == ["Dashboard design", "Simplistic UX"]


def test_intent_item_index_rebuild_and_incremental_refresh(tmp_path):
    root = tmp_path
    item_dir = root / "For Inspiration" / "Dashboard Screenshots"
    item_dir.mkdir(parents=True)
    (item_dir / ".item.toml").write_text('tags = ["Dashboard design", "Simplistic UX"]\n')
    cfg = default_config(root)
    store = WorkspaceStore(root / "events.db")
    index = IntentItemIndex(store, root)
    summary = index.rebuild(cfg, reason="test")
    assert summary == {"folders": 1, "items": 1}
    item = store.get_item_by_path("For Inspiration/Dashboard Screenshots")
    assert item is not None and item["title"] == "Dashboard Screenshots"
    tags = {t["display"] for t in store.tags_for_item(item["item_id"])}
    assert tags == {"Dashboard design", "Simplistic UX"}

    # Rename on disk, then an incremental refresh (as the watcher would issue
    # for a settled rename event) should follow the same item via inode,
    # not create a duplicate row.
    new_path = root / "For Inspiration" / "Dashboard Screenshots Renamed"
    item_dir.rename(new_path)
    folder_index = IntentFolderIndex.from_config(cfg)
    match = classify_intent("For Inspiration/Dashboard Screenshots Renamed", cfg, folder_index)
    index.refresh_item(match)
    renamed = store.get_item_by_path("For Inspiration/Dashboard Screenshots Renamed")
    assert renamed is not None and renamed["item_id"] == item["item_id"]
    assert store.get_item_by_path("For Inspiration/Dashboard Screenshots") is None
    assert len(store.all_items(only_existing=True)) == 1

    # Deleting the item marks it gone without losing history.
    import shutil
    shutil.rmtree(new_path)
    index.refresh_item(match)
    assert len(store.all_items(only_existing=True)) == 0
    assert len(store.all_items()) == 1
    store.close()


def test_projects_area_does_not_adopt_configured_intent_folder_name():
    cfg = default_config(Path("/workspace"))
    index = IntentFolderIndex.from_config(cfg)
    assert index.match_name("To Review") is not None
    assert index.match_name("Recipe Planner") is None
