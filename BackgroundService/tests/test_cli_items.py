from __future__ import annotations

import argparse

from workspace_watcher import __main__ as cli
from workspace_watcher.config import default_config
from workspace_watcher.intent import IntentItemIndex
from workspace_watcher.store import WorkspaceStore


def _ns(config_path, workspace_root, **extra) -> argparse.Namespace:
    base = {"config": config_path, "workspace_root": str(workspace_root)}
    base.update(extra)
    return argparse.Namespace(**base)


def _make_archive_item(tmp_path):
    item_dir = tmp_path / "To Archive" / "Old Prototype"
    item_dir.mkdir(parents=True)
    cfg = default_config(tmp_path)
    store = WorkspaceStore(cfg.db_path)
    IntentItemIndex(store, tmp_path).rebuild(cfg, reason="test")
    item = store.get_item_by_path("To Archive/Old Prototype")
    store.close()
    return item


def test_archive_without_confirm_refuses_and_does_not_move(tmp_path, capsys):
    item = _make_archive_item(tmp_path)
    args = _ns(None, tmp_path, item_id=item["item_id"], project=None, destination=None, confirm=False)
    assert cli.cmd_items_archive(args) == 2
    assert (tmp_path / "To Archive" / "Old Prototype").is_dir()
    assert not (tmp_path / "Closed").exists()


def test_archive_with_confirm_moves_file_and_marks_old_path_gone(tmp_path):
    item = _make_archive_item(tmp_path)
    args = _ns(None, tmp_path, item_id=item["item_id"], project=None, destination=None, confirm=True)
    assert cli.cmd_items_archive(args) == 0
    assert not (tmp_path / "To Archive" / "Old Prototype").exists()
    assert (tmp_path / "Closed" / "Old Prototype").is_dir()

    cfg = default_config(tmp_path)
    store = WorkspaceStore(cfg.db_path, read_only=True)
    try:
        row = store.get_item(item["item_id"])
        assert row["archive_state"] == "archived"
        assert row["exists_flag"] == 0  # the old path is gone; nothing else would have caught this
        assert store.all_items(only_existing=True) == []
    finally:
        store.close()


def test_tag_command_writes_item_toml_and_index(tmp_path):
    item_dir = tmp_path / "For Inspiration" / "Dashboard Screenshots"
    item_dir.mkdir(parents=True)
    cfg = default_config(tmp_path)
    store = WorkspaceStore(cfg.db_path)
    IntentItemIndex(store, tmp_path).rebuild(cfg, reason="test")
    item = store.get_item_by_path("For Inspiration/Dashboard Screenshots")
    store.close()

    args = _ns(None, tmp_path, item_id=item["item_id"], add=["Dashboard design", "Navigation"])
    assert cli.cmd_items_tag(args) == 0
    toml_text = (item_dir / ".item.toml").read_text()
    assert "Dashboard design" in toml_text and "Navigation" in toml_text

    store2 = WorkspaceStore(cfg.db_path, read_only=True)
    try:
        tags = {t["display"] for t in store2.tags_for_item(item["item_id"])}
        assert tags == {"Dashboard design", "Navigation"}
    finally:
        store2.close()
