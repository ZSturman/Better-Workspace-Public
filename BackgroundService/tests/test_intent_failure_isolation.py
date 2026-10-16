from __future__ import annotations

import logging

import pytest

from workspace_watcher.config import IntentFolderConfig, default_config, load_config
from workspace_watcher.context_engine import ContextEngine
from workspace_watcher.intent import IntentItemIndex
from workspace_watcher.store import WorkspaceStore


def test_duplicate_intent_folder_names_are_rejected():
    cfg = default_config(__import__("pathlib").Path("/workspace"))
    cfg.intent_folders = [
        IntentFolderConfig(name="To Review"),
        IntentFolderConfig(name="to review"),  # case-insensitive duplicate
    ]
    with pytest.raises(ValueError, match="Duplicate"):
        cfg.validate()


def test_invalid_category_is_rejected():
    cfg = default_config(__import__("pathlib").Path("/workspace"))
    cfg.intent_folders = [IntentFolderConfig(name="Weird", category="not-a-real-category")]
    with pytest.raises(ValueError, match="category"):
        cfg.validate()


def test_invalid_duration_string_is_rejected():
    cfg = default_config(__import__("pathlib").Path("/workspace"))
    cfg.intent_folders = [IntentFolderConfig(name="Weird", default_snooze="thirty days")]
    with pytest.raises(ValueError, match="default_snooze"):
        cfg.validate()


def test_malformed_item_toml_does_not_stop_indexing(tmp_path):
    good = tmp_path / "For Inspiration" / "Good Item"
    good.mkdir(parents=True)
    (good / ".item.toml").write_text('tags = ["Fine"]\n')
    bad = tmp_path / "For Inspiration" / "Bad Item"
    bad.mkdir(parents=True)
    (bad / ".item.toml").write_text("this is not valid TOML {{{\n")

    cfg = default_config(tmp_path)
    store = WorkspaceStore(tmp_path / "events.db")
    summary = IntentItemIndex(store, tmp_path).rebuild(cfg, reason="test")
    assert summary["items"] == 2  # both indexed; the bad one just has no metadata
    bad_item = store.get_item_by_path("For Inspiration/Bad Item")
    assert bad_item is not None and bad_item["title"] == "Bad Item"
    good_item = store.get_item_by_path("For Inspiration/Good Item")
    tags = {t["display"] for t in store.tags_for_item(good_item["item_id"])}
    assert tags == {"Fine"}
    store.close()


def test_missing_intent_root_directory_does_not_crash_rebuild(tmp_path):
    cfg = default_config(tmp_path)  # no folders exist on disk at all
    store = WorkspaceStore(tmp_path / "events.db")
    summary = IntentItemIndex(store, tmp_path).rebuild(cfg, reason="test")
    assert summary == {"folders": 0, "items": 0}
    store.close()


def test_notification_delivery_failure_is_recorded_not_raised(tmp_path):
    (tmp_path / "For Inspiration" / "Item").mkdir(parents=True)
    cfg = default_config(tmp_path)
    cfg.relevance.enabled = True
    store = WorkspaceStore(cfg.db_path)
    engine = ContextEngine(store, cfg, logging.getLogger("test"))
    IntentItemIndex(store, tmp_path).rebuild(cfg, reason="test")

    def failing_notifier(title, message):
        raise RuntimeError("Notification Center is unavailable in this test")

    engine.nudges.notifier = failing_notifier
    engine._notify_contextual_matches("Some Project", "p1", [
        {"decision": "surface", "source": "intent:For Inspiration", "title": "Item", "score": 0.5},
    ], now=100.0)
    decisions = store.recent_nudge_decisions(5)
    assert decisions[0]["decision"] == "delivery_failed"
    store.close()


def test_malformed_config_file_gives_a_clear_error(tmp_path):
    bad_config = tmp_path / "config.toml"
    bad_config.write_text('[[intent_folders]]\nname = "X"\ncategory = "bogus"\n')
    with pytest.raises(ValueError, match="category"):
        load_config(bad_config, tmp_path)
