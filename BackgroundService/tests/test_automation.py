from __future__ import annotations

import argparse
import time

from workspace_watcher import __main__ as cli
from workspace_watcher.config import default_config
from workspace_watcher.store import WorkspaceStore


def _ns(config_path, workspace_root, **extra) -> argparse.Namespace:
    base = {"config": config_path, "workspace_root": str(workspace_root)}
    base.update(extra)
    return argparse.Namespace(**base)


def _seed_decision(tmp_path, *, options=None):
    config = default_config(tmp_path)
    store = WorkspaceStore(config.db_path)
    now = time.time()
    store.ensure_project_detection_decision(
        "p1", "New Thing", now,
        options or [
            {"kind": "existing_notion_project", "notion_project_id": "n1", "name": "Old Thing", "score": 0.5},
            {"kind": "create_notion_project", "requires_explicit_approval": True},
            {"kind": "local_only"}, {"kind": "ignore_for_now"},
        ],
    )
    store.close()
    return config


def test_pending_decision_offers_more_than_existing_project_matches(tmp_path, capsys):
    config = _seed_decision(tmp_path)
    args = _ns(None, tmp_path, include_snoozed=False)
    assert cli.cmd_automation_pending(args) == 0
    out = capsys.readouterr().out
    assert "existing_notion_project: link to \"Old Thing\"" in out
    assert "create_notion_project: create a brand-new project" in out
    assert "local_only: keep it local" in out
    assert "ignored: dismiss" in out


def test_resolve_accepts_create_notion_project(tmp_path):
    config = _seed_decision(tmp_path)
    args = _ns(None, tmp_path, project_id="p1", status="create_notion_project", notion_project_id=None, note=None)
    assert cli.cmd_automation_resolve(args) == 0

    store = WorkspaceStore(config.db_path, read_only=True)
    try:
        rows = store.project_detection_decisions("create_notion_project")
        assert len(rows) == 1
        assert rows[0]["project_id"] == "p1"
    finally:
        store.close()


def test_resolve_existing_project_records_which_one_was_chosen(tmp_path):
    config = _seed_decision(tmp_path)
    args = _ns(None, tmp_path, project_id="p1", status="existing_notion_project", notion_project_id="n1", note=None)
    assert cli.cmd_automation_resolve(args) == 0

    store = WorkspaceStore(config.db_path, read_only=True)
    try:
        import json
        row = store.project_detection_decisions("existing_notion_project")[0]
        assert json.loads(row["resolution_json"])["notion_project_id"] == "n1"
    finally:
        store.close()


def test_snooze_hides_decision_from_pending_until_due(tmp_path, capsys):
    config = _seed_decision(tmp_path)
    args = _ns(None, tmp_path, project_id="p1", minutes=60)
    assert cli.cmd_automation_snooze(args) == 0

    pending_args = _ns(None, tmp_path, include_snoozed=False)
    cli.cmd_automation_pending(pending_args)
    assert "No pending project decisions." in capsys.readouterr().out

    all_args = _ns(None, tmp_path, include_snoozed=True)
    cli.cmd_automation_pending(all_args)
    out = capsys.readouterr().out
    assert "New Thing" in out
    assert "snoozed until" in out


def test_snoozed_decision_becomes_due_again_after_time_passes(tmp_path):
    config = _seed_decision(tmp_path)
    now = time.time()
    store = WorkspaceStore(config.db_path)
    assert store.snooze_project_detection("p1", now + 60, now)
    store.close()

    store = WorkspaceStore(config.db_path, read_only=True)
    try:
        assert store.project_detection_decisions("pending", due_at=now) == []
        assert len(store.project_detection_decisions("pending", due_at=now + 61)) == 1
    finally:
        store.close()


def test_resolving_a_decision_clears_any_snooze(tmp_path):
    config = _seed_decision(tmp_path)
    now = time.time()
    store = WorkspaceStore(config.db_path)
    store.snooze_project_detection("p1", now + 60, now)
    store.resolve_project_detection("p1", "local_only", {"chosen_by": "cli", "note": ""}, now)
    row = store.project_detection_decisions("local_only")[0]
    store.close()
    assert row["snoozed_until"] is None


def test_snooze_and_resolve_report_missing_decision(tmp_path):
    config = default_config(tmp_path)
    store = WorkspaceStore(config.db_path)
    store.close()

    snooze_args = _ns(None, tmp_path, project_id="nope", minutes=60)
    assert cli.cmd_automation_snooze(snooze_args) == 1

    resolve_args = _ns(None, tmp_path, project_id="nope", status="ignored", notion_project_id=None, note=None)
    assert cli.cmd_automation_resolve(resolve_args) == 1
