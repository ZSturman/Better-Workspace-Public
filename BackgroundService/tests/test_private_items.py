from dataclasses import replace
import shutil

from workspace_watcher.core_engine import IntentIndexer
from workspace_watcher.core_store import CoreStore
from workspace_watcher.ideas_v2 import create_idea, update_idea, idea_detail
from workspace_watcher.intents import IntentFolderDetector, IntentFolderSettings
from workspace_watcher.item_records import initialize_idea_record, item_metadata_path, save_item_record
from workspace_watcher.private_items import load_record
from workspace_watcher.sidecar_retirement import retire_sidecars


def detector(root):
    return IntentFolderDetector(IntentFolderSettings(search_roots=(root,)))


def test_cleanup_archives_exact_bytes_preserves_identity_and_is_idempotent(tmp_path):
    item = tmp_path / "[[Ideas]]" / "Legacy"
    record = initialize_idea_record(item)
    save_item_record(item_metadata_path(item), replace(record, notes="Keep me", tags=("AI",),
                                                      extra={"future": {"nested": [1, 2]}}))
    # Include unknown nested TOML that a canonical renderer need not understand.
    with item_metadata_path(item).open("a") as stream:
        stream.write('\n[future]\nnested = [1, 2]\n')
    original = item_metadata_path(item).read_bytes()
    content = item / "note.md"
    content.write_text("User content")
    with CoreStore(tmp_path / "core.db") as store:
        plan = retire_sidecars(store, detector(tmp_path))
        assert plan["eligible"] == 1 and plan["removed"] == 0
        assert store.items() == [] and item_metadata_path(item).read_bytes() == original
        result = retire_sidecars(store, detector(tmp_path), apply=True)
        assert result["removed"] == 1 and result["kept"] == []
        assert not item_metadata_path(item).exists()
        assert content.read_text() == "User content"
        assert load_record(store, item).id == record.id
        assert load_record(store, item).extra == {"future": {"nested": [1, 2]}}
        assert store.conn.execute("SELECT original_bytes FROM retired_item_sidecars").fetchone()[0] == original
        assert retire_sidecars(store, detector(tmp_path), apply=True)["removed"] == 0
    with CoreStore(tmp_path / "core.db") as store:
        index = IntentIndexer(detector(tmp_path), store)
        assert index.rebuild()["events"] == 0
        assert idea_detail(store, record.id)["notes"] == "Keep me"
        update_idea(store, record.id, {"status": "exploring", "defer_until": "2026-11-01"})
        assert index.rebuild()["events"] == 0
        assert load_record(store, item).defer_until == "2026-11-01"
        assert not item_metadata_path(item).exists()


def test_cleanup_keeps_malformed_sidecars_and_symlinks(tmp_path):
    ideas = tmp_path / "[[Ideas]]"
    bad = ideas / "Bad"
    bad.mkdir(parents=True)
    item_metadata_path(bad).write_text("not valid TOML")
    linked = ideas / "Linked"
    linked.mkdir()
    external = tmp_path / "external.toml"
    external.write_text("Do not change")
    item_metadata_path(linked).symlink_to(external)
    with CoreStore(tmp_path / "core.db") as store:
        result = retire_sidecars(store, detector(tmp_path), apply=True)
        assert result["removed"] == 0 and len(result["kept"]) == 2
    assert item_metadata_path(bad).read_text() == "not valid TOML"
    assert external.read_text() == "Do not change" and item_metadata_path(linked).is_symlink()


def test_private_identity_survives_rename_and_copy_gets_a_new_id(tmp_path):
    ideas = tmp_path / "[[Ideas]]"
    ideas.mkdir()
    with CoreStore(tmp_path / "core.db") as store:
        index = IntentIndexer(detector(tmp_path), store)
        index.rebuild()
        created = create_idea(store, ideas, "Original")
        update_idea(store, created["id"], {"notes": "Private notes"})
        moved = ideas / "Renamed"
        (ideas / "Original").rename(moved)
        index.rebuild()
        assert load_record(store, moved).id == created["id"]
        assert load_record(store, moved).notes == "Private notes"
        copied = ideas / "Copied"
        shutil.copytree(moved, copied)
        index.rebuild()
        assert load_record(store, copied).id != created["id"]
        assert not list(ideas.rglob("watcher.item.toml"))


def test_legacy_copy_collision_is_repaired_without_rewriting_sidecars(tmp_path):
    first = tmp_path / "[[Ideas]]" / "Original"
    initialize_idea_record(first)
    copied = first.parent / "Copy"
    shutil.copytree(first, copied)
    original_bytes = item_metadata_path(first).read_bytes()
    with CoreStore(tmp_path / "core.db") as store:
        index = IntentIndexer(detector(tmp_path), store)
        assert index.rebuild()["collisions"] == 1
        assert load_record(store, first).id != load_record(store, copied).id
        assert item_metadata_path(first).read_bytes() == original_bytes
        assert item_metadata_path(copied).read_bytes() == original_bytes
        assert retire_sidecars(store, detector(tmp_path), apply=True)["removed"] == 2


def test_retirement_rejects_a_file_changed_after_plan(tmp_path, monkeypatch):
    item = tmp_path / "[[Ideas]]" / "Changed"
    initialize_idea_record(item)
    rebuild = IntentIndexer.rebuild
    def change_after_inventory(indexer, **kwargs):
        result = rebuild(indexer, **kwargs)
        with item_metadata_path(item).open("a") as stream:
            stream.write("\n# Changed externally\n")
        return result
    monkeypatch.setattr(IntentIndexer, "rebuild", change_after_inventory)
    with CoreStore(tmp_path / "core.db") as store:
        result = retire_sidecars(store, detector(tmp_path), apply=True)
        assert result["removed"] == 0 and "changed" in result["kept"][0]["reason"]
        assert item_metadata_path(item).exists()


def test_unindexed_retirement_preserves_metadata_without_creating_active_ideas(tmp_path):
    item = tmp_path / "[[Ideas]]" / "Former idea"
    record = initialize_idea_record(item)
    foreign = tmp_path / ".project-core" / "Unrelated"
    initialize_idea_record(foreign)
    with CoreStore(tmp_path / "core.db") as store:
        IntentIndexer(detector(tmp_path), store).rebuild()
        moved = tmp_path / "Projects" / "Former idea"
        moved.parent.mkdir()
        item.rename(moved)
        item = moved
        IntentIndexer(detector(tmp_path), store).rebuild()
        assert retire_sidecars(store, detector(tmp_path))["eligible"] == 0
        result = retire_sidecars(store, detector(tmp_path), apply=True, include_unindexed=True)
        assert result["removed"] == 1 and result["kept"] == []
        assert store.items() == []
        assert load_record(store, item).id == record.id
        assert item_metadata_path(foreign).exists()


def test_an_active_legacy_copy_does_not_steal_an_unindexed_private_record(tmp_path):
    item = tmp_path / "Projects" / "Original"
    record = initialize_idea_record(item)
    original = item_metadata_path(item).read_bytes()
    with CoreStore(tmp_path / "core.db") as store:
        retire_sidecars(store, detector(tmp_path), apply=True, include_unindexed=True)
        copied = tmp_path / "[[Ideas]]" / "Copy"
        copied.mkdir(parents=True)
        item_metadata_path(copied).write_bytes(original)
        assert IntentIndexer(detector(tmp_path), store).rebuild()["collisions"] == 1
        assert load_record(store, copied).id != record.id
        assert load_record(store, item).id == record.id
