"""Bulk filesystem runs across many projects are not work on those projects."""

from __future__ import annotations

import dataclasses
import json
from datetime import datetime, timedelta, timezone
from pathlib import Path

from workspace_watcher.core_config import NotionSettings, SessionsSettings, WorkLogsSettings
from workspace_watcher.core_store import CoreStore
from workspace_watcher.projects_v2 import ProjectRef
from workspace_watcher.session_automation import Activation, AutomationRule, apply_classification, classify
from workspace_watcher.sessions_v2 import Session, Sessionizer
from workspace_watcher.work_logs_v2 import WorkLogGenerator

T0 = datetime(2026, 10, 10, 11, 0, tzinfo=timezone.utc)
FOCUS = ProjectRef(project_id="p-focus", name="Focus", path="Projects/Focus")
AUDIT = ProjectRef(project_id="p-audit", name="_Workspace Audit", path="Projects/_Workspace Audit")
TARGETS = [ProjectRef(project_id=f"p-{i}", name=f"Target {i}", path=f"Projects/Target {i}") for i in range(40)]


def _touch(store: CoreStore, sessionizer: Sessionizer, project: ProjectRef, name: str, at: datetime) -> None:
    for event in sessionizer.touch(project, f"{project.path}/{name}", False, at.isoformat()):
        store.record_event(dataclasses.replace(event, occurred_at=at.isoformat()))


def _scenario(tmp_path: Path, store: CoreStore) -> Sessionizer:
    sessionizer = Sessionizer(store, SessionsSettings(), tmp_path, git_probe=lambda _root: {}, commits_probe=lambda _root, _since: [])
    # Real work: ten minutes of steady edits in one project before the audit starts.
    for minute in range(10):
        _touch(store, sessionizer, FOCUS, "Sources/App.swift", T0 + timedelta(minutes=minute))
    # Three automated passes, each writing four files into forty projects within a minute.
    for run in range(3):
        start = T0 + timedelta(minutes=12 + run * 8)
        for index, target in enumerate(TARGETS):
            at = start + timedelta(seconds=index * 1.2)
            _touch(store, sessionizer, AUDIT, "progress.json", at)
            for offset, name in enumerate(["README.md", "docs/NEXT_STEPS.md", "WORKSPACE_RECONCILIATION.md", "WORKSPACE_RECONCILIATION.json"]):
                _touch(store, sessionizer, target, name, at + timedelta(seconds=0.1 * (offset + 1)))
    # Real work resumes afterwards, in the same project.
    for minute in range(40, 52):
        _touch(store, sessionizer, FOCUS, "Sources/View.swift", T0 + timedelta(minutes=minute))
    for event in sessionizer.close_all((T0 + timedelta(hours=2)).isoformat(), "test"):
        store.record_event(dataclasses.replace(event, occurred_at=(T0 + timedelta(hours=2)).isoformat()))
    return sessionizer


def _drafts(tmp_path: Path, store: CoreStore) -> None:
    generator = WorkLogGenerator(store, WorkLogsSettings(), NotionSettings(), tmp_path)
    for row in store.conn.execute("SELECT * FROM sessions WHERE status='completed'").fetchall():
        generator.prepare(Session.from_row(row))


def _status(store: CoreStore) -> dict[str, str]:
    return {row["project_id"]: row["status"] for row in store.conn.execute("SELECT project_id, status FROM sessions")}


def test_bulk_passes_are_marked_automated_and_focused_work_is_kept(tmp_path):
    with CoreStore(tmp_path / "core.db") as store:
        _scenario(tmp_path, store)
        before = _status(store)
        assert before["p-0"] == "completed", "Repeated passes resume each target until it looks legitimate"
        assert before["p-focus"] == "completed"
        _drafts(tmp_path, store)
        report = apply_classification(store, apply=True, now=(T0 + timedelta(hours=3)).isoformat())
        after = _status(store)
        assert all(after[target.project_id] == "discarded" for target in TARGETS)
        assert after["p-audit"] == "discarded", "The automation's own folder alternates with every target"
        assert after["p-focus"] == "completed", "Sustained work that overlapped the audit is kept"
        assert report["automated_sessions"] == len(TARGETS) + 1
        evidence = json.loads(store.conn.execute("SELECT evidence_json FROM sessions WHERE project_id='p-0'").fetchone()[0])
        assert evidence["automation"]["previous_status"] == "completed"
        assert evidence["automation"]["reason"] == "bulk_filesystem_fanout"
        assert "confidence_breakdown" in evidence, "Existing evidence is kept beside the classification"
        drafts = {row["project_id"]: row for row in store.conn.execute("SELECT * FROM work_log_drafts")}
        assert drafts["p-0"]["status"] == "automated" and drafts["p-focus"]["status"] == "prepared"
        assert json.loads(drafts["p-0"]["session_ids_json"]), "An automated draft keeps its session ids for recovery"
        assert store.conn.execute("SELECT COUNT(*) FROM sessions").fetchone()[0] == len(before), "Nothing is deleted"


def test_dry_run_writes_nothing_and_rerun_is_idempotent(tmp_path):
    with CoreStore(tmp_path / "core.db") as store:
        _scenario(tmp_path, store)
        _drafts(tmp_path, store)
        snapshot = [tuple(row) for row in store.conn.execute("SELECT id, status, evidence_json FROM sessions ORDER BY id")]
        drafts = [tuple(row) for row in store.conn.execute("SELECT * FROM work_log_drafts ORDER BY id")]
        report = apply_classification(store, apply=False)
        assert report["automated_sessions"] == len(TARGETS) + 1 and not report["apply"]
        assert [tuple(row) for row in store.conn.execute("SELECT id, status, evidence_json FROM sessions ORDER BY id")] == snapshot
        assert [tuple(row) for row in store.conn.execute("SELECT * FROM work_log_drafts ORDER BY id")] == drafts
        apply_classification(store, apply=True)
        again = apply_classification(store, apply=True)
        assert again["automated_sessions"] == 0, "Already classified sessions are not counted twice"


def test_a_burst_still_settling_is_not_judged(tmp_path):
    with CoreStore(tmp_path / "core.db") as store:
        _scenario(tmp_path, store)
        early = (T0 + timedelta(minutes=13)).isoformat()  # the first pass is still in progress
        report = apply_classification(store, settled_before=early, apply=True)
        assert report["automated_sessions"] == 0
        assert _status(store)["p-0"] == "completed"


def test_mixed_draft_keeps_only_real_sessions():
    rule = AutomationRule()
    burst = [Activation(T0 + timedelta(seconds=i), f"p-{i}", f"s-{i}") for i in range(10)]
    person = [Activation(T0 + timedelta(minutes=30), "p-0", "s-0-later")]
    sessions = [{"id": f"s-{i}", "status": "completed", "longest_burst_seconds": 1} for i in range(10)]
    sessions += [{"id": "s-0-later", "status": "completed", "longest_burst_seconds": 1},
                 {"id": "s-1", "status": "completed", "longest_burst_seconds": 600}]
    result = classify([*burst, *person], sessions, rule)
    assert "s-0-later" not in result, "A lone activation is a person choosing the project"
    assert "s-2" in result
    sustained = classify(burst, [{"id": "s-1", "status": "completed", "longest_burst_seconds": 600}], rule)
    assert sustained == {}, "Long uninterrupted activity of its own is work, even inside a burst"


def test_active_time_never_exceeds_the_session_span(tmp_path):
    with CoreStore(tmp_path / "core.db") as store:
        sessionizer = Sessionizer(store, SessionsSettings(), tmp_path, git_probe=lambda _root: {}, commits_probe=lambda _root, _since: [])
        # Two projects interleaved every second for two minutes: each resume used to add 60 s.
        for second in range(120):
            _touch(store, sessionizer, FOCUS if second % 2 else AUDIT, "f.txt", T0 + timedelta(seconds=second))
        sessionizer.close_all((T0 + timedelta(minutes=10)).isoformat(), "test")
        for row in store.conn.execute("SELECT started_at, ended_at, active_seconds FROM sessions"):
            span = (datetime.fromisoformat(row["ended_at"]) - datetime.fromisoformat(row["started_at"])).total_seconds()
            assert row["active_seconds"] <= span + SessionsSettings().event_active_seconds
