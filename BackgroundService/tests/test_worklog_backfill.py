"""The local Work Log backfill: rebuilding missed history from surviving journals,
without double counting what the live service recorded, without inventing a day,
without turning a scripted sweep into a "session", and without ever queueing Notion."""

from __future__ import annotations

import json
from datetime import date, datetime, timedelta, timezone
from pathlib import Path

from workspace_watcher.core_config import CoreConfig, HammerspoonInboxSettings, NotionSettings, ProjectsSettings, SessionsSettings, WorkLogsSettings
from workspace_watcher.core_store import CoreStore
from workspace_watcher.intents import IntentFolderSettings
from workspace_watcher.sessions_v2 import Session
from workspace_watcher.work_logs_v2 import WorkLogGenerator
from workspace_watcher.worklog_backfill import BACKFILL_DRAFT_STATUS, WorkLogBackfill

DAY = date(2026, 9, 25)


def _at(hour: int, minute: int = 0, second: int = 0, day: date = DAY) -> datetime:
    return datetime(day.year, day.month, day.day, hour, minute, second, tzinfo=timezone.utc)


def _z(at: datetime) -> str:
    return at.strftime("%Y-%m-%dT%H:%M:%SZ")


class FakeSync:
    def __init__(self) -> None:
        self.synced: list[str] = []

    def sync(self, draft: dict) -> str:
        self.synced.append(draft["id"])
        return "page"


def _setup(tmp_path: Path):
    root = tmp_path / "Workspace"
    for name in ("Alpha", "Beta"):
        (root / "Projects" / name).mkdir(parents=True)
        (root / "Projects" / name / "a.py").write_text("x")
    config = CoreConfig(
        root, root / "Logs/workspace-watcher/core.db", IntentFolderSettings.for_workspace(root),
        root / "config.toml", root / "rules.toml", 0.1,
        HammerspoonInboxSettings(enabled=False, path=root / "inbox.jsonl"),
        ProjectsSettings(enabled=True, root="Projects"), SessionsSettings(),
    )
    store = CoreStore(config.database_path)
    for name in ("Alpha", "Beta"):
        store.create_project(project_id=f"id-{name}", path=f"Projects/{name}", root_path="Projects", name=name,
                             device=None, inode=None, timestamp=_z(_at(0)))
    return root, config, store


def _journal(tmp_path: Path, rows: list[tuple[datetime, str]]) -> Path:
    path = tmp_path / "fs.jsonl"
    with path.open("w") as handle:
        for at, target in rows:
            handle.write(json.dumps({"path": target, "timestamp": _z(at)}) + "\n")
        handle.write('{"path": "torn')  # an append-only journal can end mid-line
    return path


def _sitting(root: Path, project: str, start: datetime, minutes: int) -> list[tuple[datetime, str]]:
    """A real sitting: a save every 30 seconds, alternating two files."""
    return [(start + timedelta(seconds=30 * i), str(root / "Projects" / project / ("a.py" if i % 2 else "b.py")))
            for i in range(minutes * 2)]


def _backfill(store, config, journal, terminal=None) -> WorkLogBackfill:
    return WorkLogBackfill(store, config, filesystem_journals=[journal], terminal_journals=[terminal] if terminal else [],
                           timezone_name="UTC", commits_probe=lambda *_: [])


def _generator(store, config) -> WorkLogGenerator:
    return WorkLogGenerator(store, WorkLogsSettings(notion_sync=True, authoritative_writer="v2"),
                            NotionSettings(enabled=True), config.workspace_root, sync=FakeSync())


def test_a_sitting_becomes_one_reconstructed_session_with_provenance(tmp_path):
    root, config, store = _setup(tmp_path)
    rows = _sitting(root, "Alpha", _at(10), 20)
    rows.append((_at(10, 5, 1), str(root / "Projects/Alpha/b.py.tmp.4242.0a1b2c3d")))  # an atomic save's temporary
    result = _backfill(store, config, _journal(tmp_path, rows)).plan(DAY, DAY)

    completed = [s for s in result.sessions if s["status"] == "completed"]
    assert len(completed) == 1
    session = completed[0]
    assert session["id"].startswith("backfill-")
    assert session["project_name"] == "Alpha"
    assert session["evidence"]["provenance"]["source"] == "backfill"
    assert not any(".tmp." in path for path in session["files"]), "a save's temporary is not a second save"
    assert result.coverage[DAY.isoformat()].status() == "reconstructed"
    assert store.conn.execute("SELECT COUNT(*) FROM sessions").fetchone()[0] == 0, "planning writes nothing"


def test_a_scripted_sweep_is_kept_but_not_counted_as_work(tmp_path):
    root, config, store = _setup(tmp_path)
    sweep = [(_at(11, 0, 0), str(root / f"Projects/Beta/gen/f{i}.txt")) for i in range(40)]
    sweep += [(_at(11, 30, 0), str(root / f"Projects/Beta/other/g{i}.txt")) for i in range(40)]
    result = _backfill(store, config, _journal(tmp_path, sweep)).plan(DAY, DAY)
    assert result.sessions, "the activity is not hidden"
    assert all(s["status"] == "discarded" for s in result.sessions)
    assert any("sweep" in (s["evidence"].get("discarded_because") or "") for s in result.sessions)


def test_what_the_live_service_recorded_is_never_counted_again(tmp_path):
    root, config, store = _setup(tmp_path)
    store.upsert_session(Session(
        id="live-1", project_id="id-Alpha", project_name="Alpha", started_at=_at(13).isoformat(), ended_at=_at(13, 30).isoformat(),
        active_seconds=1200, meaningful_event_count=30, status="completed", close_reason="inactivity",
        created_at=_at(13).isoformat(), updated_at=_at(13, 30).isoformat()).to_record())
    rows = _sitting(root, "Alpha", _at(13, 5), 10)
    result = _backfill(store, config, _journal(tmp_path, rows)).plan(DAY, DAY)
    assert result.sessions == []
    coverage = result.coverage[DAY.isoformat()]
    assert coverage.in_live_windows == len(rows)
    assert coverage.status() == "recorded"


def test_a_day_without_evidence_is_reported_as_such_not_filled_in(tmp_path):
    root, config, store = _setup(tmp_path)
    rows = _sitting(root, "Alpha", _at(10), 10)
    result = _backfill(store, config, _journal(tmp_path, rows)).plan(DAY - timedelta(days=1), DAY)
    assert result.coverage[(DAY - timedelta(days=1)).isoformat()].status() == "no_evidence"
    assert all(s["started_at"].startswith(DAY.isoformat()) for s in result.sessions)


def test_terminal_commands_count_toward_their_project(tmp_path):
    root, config, store = _setup(tmp_path)
    rows = _sitting(root, "Alpha", _at(10), 10)
    terminal = tmp_path / "terminal.jsonl"
    terminal.write_text("".join(json.dumps({"timestamp": _z(_at(10, 2 + i)), "cwd": str(root / "Projects/Alpha"),
                                            "repo_root": "", "category": "build"}) + "\n" for i in range(3)))
    result = _backfill(store, config, _journal(tmp_path, rows), terminal).plan(DAY, DAY)
    [session] = [s for s in result.sessions if s["status"] == "completed"]
    assert session["evidence"]["terminal_commands"] == 3


def test_applying_twice_changes_nothing_and_never_queues_notion(tmp_path):
    root, config, store = _setup(tmp_path)
    rows = _sitting(root, "Alpha", _at(10), 20) + _sitting(root, "Beta", _at(15), 15)
    journal = _journal(tmp_path, rows)
    generator = _generator(store, config)

    first = _backfill(store, config, journal).apply(_backfill(store, config, journal).plan(DAY, DAY), generator)
    sessions = {row["id"] for row in store.conn.execute("SELECT id FROM sessions")}
    drafts = {row["id"]: (row["payload_json"], row["status"]) for row in store.work_log_drafts()}
    assert first.drafts_touched == 2
    assert {status for _, status in drafts.values()} == {BACKFILL_DRAFT_STATUS}
    assert all("Reconstructed from the filesystem journal." in json.loads(p)["summary"] for p, _ in drafts.values())

    second = _backfill(store, config, journal).apply(_backfill(store, config, journal).plan(DAY, DAY), generator)
    assert second.removed_sessions == len(sessions)
    assert {row["id"] for row in store.conn.execute("SELECT id FROM sessions")} == sessions
    assert {row["id"]: (row["payload_json"], row["status"]) for row in store.work_log_drafts()} == drafts

    assert generator.sync_pending(limit=50) == [], "reconstructed history is never sent to Notion on its own"
    assert store.get_state("work_logs.backfill")["days"][DAY.isoformat()]["status"] == "reconstructed"


def test_a_live_draft_for_the_same_day_gains_the_reconstructed_session_and_keeps_its_status(tmp_path):
    root, config, store = _setup(tmp_path)
    generator = _generator(store, config)
    live = Session(id="live-1", project_id="id-Alpha", project_name="Alpha", started_at=_at(18).isoformat(),
                   ended_at=_at(18, 40).isoformat(), active_seconds=1800, meaningful_event_count=40, files=["Projects/Alpha/a.py"],
                   confidence=0.9, status="completed", close_reason="inactivity",
                   created_at=_at(18).isoformat(), updated_at=_at(18, 40).isoformat())
    store.upsert_session(live.to_record())
    generator.prepare(live)

    journal = _journal(tmp_path, _sitting(root, "Alpha", _at(9), 20))
    _backfill(store, config, journal).apply(_backfill(store, config, journal).plan(DAY, DAY), generator)
    [draft] = store.work_log_drafts()
    payload = json.loads(draft["payload_json"])
    assert draft["status"] == "prepared", "a live draft is not relabelled by history"
    assert payload["session_count"] == 2 and payload["backfilled_session_count"] == 1
    assert "1 of 2 session(s) reconstructed" in payload["summary"]
