from __future__ import annotations

import time

import workspace_watcher.lm_studio as lm_module
from workspace_watcher.client import ProjectActivityContext, ProjectSummary
from workspace_watcher.config import default_config
from workspace_watcher.intent import IntentItemIndex
from workspace_watcher.relevance import RelevanceEngine
from workspace_watcher.store import WorkspaceStore
from workspace_watcher.ui import menubar


def test_build_status_reports_active_project_suggestions_and_due_items(tmp_path, monkeypatch):
    def _offline(*_args, **_kwargs):
        raise OSError("offline in test")

    monkeypatch.setattr(lm_module, "urlopen", _offline)
    (tmp_path / "For Inspiration" / "Dashboard Screenshots").mkdir(parents=True)
    (tmp_path / "For Inspiration" / "Dashboard Screenshots" / ".item.toml").write_text('tags = ["Dashboard design"]\n')
    (tmp_path / "To Archive" / "Old Project").mkdir(parents=True)
    (tmp_path / "To Archive" / "Old Project" / ".item.toml").write_text("after_inactive = \"1d\"\n")

    config = default_config(tmp_path)
    config.relevance.enabled = True
    config.relevance.minimum_score = 0.01
    store = WorkspaceStore(config.db_path)
    now = time.time()
    store.create_project("p1", "Projects/Home Dashboard", "Home Dashboard", None, None, now)
    store.set_state("active_project", {"project_id": "p1", "project_name": "Home Dashboard", "since": now})
    IntentItemIndex(store, tmp_path).rebuild(config, reason="test")
    old_item = store.get_item_by_path("To Archive/Old Project")
    store.conn.execute("UPDATE items SET last_seen_at=? WHERE item_id=?", (now - 2 * 86400, old_item["item_id"]))
    store.conn.commit()
    context = ProjectActivityContext(
        ProjectSummary("p1", "Home Dashboard", "Projects/Home Dashboard", 0, 1, 3, "active"),
        24, [], ["Projects/Home Dashboard/dashboard design.md"], {"modified": 1}, 0, 1,
    )
    RelevanceEngine(store, config.relevance).run(context, now=now)
    store.close()

    status = menubar.build_status(config)
    assert status.active_project_name == "Home Dashboard"
    assert status.due_by_folder == {"To Archive": 1}
    assert "For Inspiration" in status.suggestions_by_folder
    assert status.suggestions_by_folder["For Inspiration"][0].title == "Dashboard Screenshots"


def test_build_status_surfaces_pending_project_decision_with_full_options(tmp_path):
    config = default_config(tmp_path)
    store = WorkspaceStore(config.db_path)
    now = time.time()
    store.ensure_project_detection_decision(
        "p1", "New Thing", now,
        [
            {"kind": "existing_notion_project", "notion_project_id": "n1", "name": "Old Thing", "score": 0.5},
            {"kind": "create_notion_project", "requires_explicit_approval": True},
            {"kind": "local_only"}, {"kind": "ignore_for_now"},
        ],
    )
    store.close()

    status = menubar.build_status(config)
    assert len(status.project_decisions) == 1
    decision = status.project_decisions[0]
    assert decision.project_name == "New Thing"
    assert [m["name"] for m in decision.existing_matches] == ["Old Thing"]


def test_build_status_hides_snoozed_project_decision(tmp_path):
    config = default_config(tmp_path)
    store = WorkspaceStore(config.db_path)
    now = time.time()
    store.ensure_project_detection_decision("p1", "New Thing", now, [{"kind": "local_only"}])
    store.snooze_project_detection("p1", now + 3600, now)
    store.close()

    status = menubar.build_status(config)
    assert status.project_decisions == []


def test_build_status_with_no_database_is_a_clear_error(tmp_path):
    config = default_config(tmp_path)
    status = menubar.build_status(config)
    assert status.error and "watcher" in status.error.lower()


def test_cmd_menubar_degrades_gracefully_without_rumps(tmp_path, capsys, monkeypatch):
    import argparse
    import builtins
    from workspace_watcher.__main__ import cmd_menubar

    real_import = builtins.__import__

    def _no_rumps(name, *args, **kwargs):
        if name == "rumps":
            raise ImportError("No module named 'rumps'")
        return real_import(name, *args, **kwargs)

    monkeypatch.setattr(builtins, "__import__", _no_rumps)
    args = argparse.Namespace(config=None, workspace_root=str(tmp_path))
    assert cmd_menubar(args) == 1
    assert "rumps" in capsys.readouterr().out.lower()
