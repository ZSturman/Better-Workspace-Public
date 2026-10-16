from __future__ import annotations

from pathlib import Path

from workspace_watcher.config import default_config
from workspace_watcher.intent import IntentItemIndex
from workspace_watcher.reminders import ReminderEngine
from workspace_watcher.store import WorkspaceStore


def _make_item(store, tmp_path, folder="To Archive", name="Old Project", toml_body=""):
    folder_dir = tmp_path / folder / name
    folder_dir.mkdir(parents=True)
    if toml_body:
        (folder_dir / ".item.toml").write_text(toml_body)
    cfg = default_config(tmp_path)
    IntentItemIndex(store, tmp_path).rebuild(cfg, reason="test")
    return store.get_item_by_path(f"{folder}/{name}")


def test_no_condition_is_not_due(tmp_path):
    store = WorkspaceStore(tmp_path / "events.db")
    item = _make_item(store, tmp_path, folder="To Review", toml_body="")  # "To Review" has no default inactivity_threshold
    engine = ReminderEngine(store, default_config(tmp_path))
    due, reason = engine.is_item_due(item, now=1_000_000.0)
    assert not due and reason == "no_condition"
    store.close()


def test_absolute_after_date_gates_due(tmp_path):
    store = WorkspaceStore(tmp_path / "events.db")
    item = _make_item(store, tmp_path, folder="To Review", toml_body="after = 2030-01-01\n")
    engine = ReminderEngine(store, default_config(tmp_path))
    before = __import__("datetime").datetime(2029, 1, 1).timestamp()
    after = __import__("datetime").datetime(2031, 1, 1).timestamp()
    assert engine.is_item_due(item, now=before) == (False, "not_yet_after")
    assert engine.is_item_due(item, now=after)[0] is True


def test_after_inactive_uses_folder_default_when_item_omits_it(tmp_path):
    store = WorkspaceStore(tmp_path / "events.db")
    item = _make_item(store, tmp_path, toml_body="")  # "To Archive" default inactivity_threshold is "90d"
    engine = ReminderEngine(store, default_config(tmp_path))
    soon = item["last_seen_at"] + 86400  # 1 day later: not yet 90d
    later = item["last_seen_at"] + 91 * 86400
    assert engine.is_item_due(item, now=soon) == (False, "not_yet_inactive")
    due, reason = engine.is_item_due(item, now=later)
    assert due and reason == "due"


def test_recently_reviewed_suppresses_until_repeat_elapses(tmp_path):
    store = WorkspaceStore(tmp_path / "events.db")
    item = _make_item(store, tmp_path, toml_body="after_inactive = \"1d\"\nrepeat = \"7d\"\n")
    engine = ReminderEngine(store, default_config(tmp_path))
    now = item["last_seen_at"] + 2 * 86400
    assert engine.is_item_due(item, now=now)[0] is True
    store.mark_item_reviewed(item["item_id"], now)
    item = store.get_item(item["item_id"])
    assert engine.is_item_due(item, now=now + 86400) == (False, "recently_reviewed")
    assert engine.is_item_due(item, now=now + 8 * 86400)[0] is True


def test_defer_until_next_project_session_requires_a_new_session(tmp_path):
    store = WorkspaceStore(tmp_path / "events.db")
    store.create_project("p1", "Projects/Home Dashboard", "Home Dashboard", None, None, 0)
    item = _make_item(store, tmp_path, folder="Waiting For", name="Vendor Reply", toml_body='defer_until = "next_project_session"\nsource_project = "p1"\n')
    engine = ReminderEngine(store, default_config(tmp_path))
    now = item["created_at"] + 100
    assert engine.is_item_due(item, now=now) == (False, "deferred_until_next_session")
    store.upsert_activity_session({
        "session_id": "s1", "project_id": "p1", "project_name": "Home Dashboard",
        "started_at": now + 10, "ended_at": now + 20, "active_seconds": 200,
        "meaningful_event_count": 5, "status": "completed", "created_at": now + 10, "updated_at": now + 20,
    })
    assert engine.is_item_due(item, now=now + 30)[0] is True
    store.close()
