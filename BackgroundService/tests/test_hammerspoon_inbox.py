"""Durable, idempotent ingestion of Hammerspoon-produced events into the v2
event journal -- and that a resulting rule can fire off it."""

from __future__ import annotations

import json
import socket
import threading
from argparse import Namespace
from pathlib import Path

from workspace_watcher.core_config import CoreConfig, HammerspoonInboxSettings
from workspace_watcher.core_runtime import CoreRuntime
from workspace_watcher.core_store import CoreStore
from workspace_watcher.hammerspoon_inbox import HammerspoonInbox
from workspace_watcher.intents import IntentFolderSettings


def _write_lines(path: Path, rows: list[dict]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as handle:
        for row in rows:
            handle.write(json.dumps(row) + "\n")


def _inbox(tmp_path: Path, *, enabled: bool = True) -> tuple[HammerspoonInbox, CoreStore, Path]:
    store = CoreStore(tmp_path / "core.db")
    inbox_path = tmp_path / "inbox" / "hammerspoon-events.jsonl"
    settings = HammerspoonInboxSettings(enabled=enabled, path=inbox_path, stale_after_minutes=20.0)
    return HammerspoonInbox(store, settings), store, inbox_path


def test_duplicate_event_id_is_ingested_once(tmp_path):
    inbox, store, path = _inbox(tmp_path)
    row = {"event_id": "abc123", "kind": "idle_started", "timestamp": "2026-09-18T10:00:00+00:00"}
    _write_lines(path, [row])
    first = inbox.ingest()
    assert len(first) == 1
    assert first[0].type == "hammerspoon.idle_started"

    # A retried append (e.g. the producer never saw an ack) writes the exact
    # same line again -- it must not create a second journal row.
    _write_lines(path, [row])
    second = inbox.ingest()
    assert second == []
    assert len(store.recent_events(100)) == 1


def test_malformed_line_does_not_stop_later_lines(tmp_path):
    inbox, store, path = _inbox(tmp_path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as handle:
        handle.write("not json at all\n")
        handle.write(json.dumps({"event_id": "ok-1", "kind": "app_focused", "app": "Code"}) + "\n")
    recorded = inbox.ingest()
    assert [event.id for event in recorded] == ["hammerspoon:ok-1"]
    assert recorded[0].payload["app"] == "Code"


def test_offset_persists_across_restart(tmp_path):
    inbox, store, path = _inbox(tmp_path)
    _write_lines(path, [{"event_id": "first", "kind": "idle_started"}])
    inbox.ingest()

    # Simulate a watcher restart: a fresh CoreStore/HammerspoonInbox pointed
    # at the same on-disk database must not re-ingest what was already read,
    # even though it is a brand-new Python object with no in-memory state.
    store.close()
    restarted_store = CoreStore(tmp_path / "core.db")
    restarted_inbox = HammerspoonInbox(restarted_store, HammerspoonInboxSettings(enabled=True, path=path))
    _write_lines(path, [{"event_id": "second", "kind": "idle_ended"}])
    recorded = restarted_inbox.ingest()
    assert [event.id for event in recorded] == ["hammerspoon:second"]
    assert len(restarted_store.recent_events(100)) == 2


def test_events_written_while_watcher_offline_are_ingested_on_next_call(tmp_path):
    # The producer must not need Workspace Watcher online at the moment an
    # event happens: write a whole backlog with no ingest() calls in between,
    # then a single call catches it all up, in order, exactly once each.
    inbox, store, path = _inbox(tmp_path)
    _write_lines(path, [
        {"event_id": "a", "kind": "app_focused"},
        {"event_id": "b", "kind": "idle_started"},
        {"event_id": "c", "kind": "idle_ended"},
    ])
    recorded = inbox.ingest()
    assert [event.id for event in recorded] == ["hammerspoon:a", "hammerspoon:b", "hammerspoon:c"]


def test_disabled_or_missing_inbox_is_a_noop(tmp_path):
    inbox, _store, path = _inbox(tmp_path / "disabled", enabled=False)
    _write_lines(path, [{"event_id": "a", "kind": "app_focused"}])
    assert inbox.ingest() == []

    enabled_inbox, _store2, _path2 = _inbox(tmp_path / "missing-file")
    assert enabled_inbox.ingest() == []  # file does not exist yet


def test_cmd_run_actually_ticks_the_hammerspoon_inbox(tmp_path, monkeypatch):
    # Regression test: cmd_run used to call only `runtime.start()` then block
    # on the HTTP server's serve_forever(), so CoreRuntime's periodic ticking
    # (Hammerspoon inbox ingestion, notification/message retry, scheduler)
    # was never actually invoked in production despite being fully wired and
    # unit-tested in isolation. This exercises the real `cmd_run` entry point
    # end to end, with the network/port dependency replaced by fakes so it
    # cannot collide with a real Workspace Watcher instance on this machine.
    from workspace_watcher.__main__ import cmd_run

    root = tmp_path / "workspace"
    root.mkdir()
    inbox_path = root / "Logs/workspace-watcher/inbox/hammerspoon-events.jsonl"
    db_path = root / "Logs/workspace-watcher/core.db"
    config_path = tmp_path / "config.toml"
    config_path.write_text(
        f"""
[workspace_watcher]
workspace_root = "{root}"
rules_file = "rules.toml"
[workspace_watcher.storage]
database = "{db_path}"
[workspace_watcher.hammerspoon_inbox]
enabled = true
path = "{inbox_path}"
""".strip()
    )
    _write_lines(inbox_path, [{"event_id": "cmd-run-1", "kind": "app_focused", "app": "Code"}])

    class FakeServer:
        def __init__(self) -> None:
            self._closed = threading.Event()

        def serve_forever(self) -> None:
            # Long enough for the background ticker to run several 1s ticks
            # before cmd_run's shutdown path closes this fake server.
            self._closed.wait(2.5)

        def server_close(self) -> None:
            self._closed.set()

    fake_server = FakeServer()
    monkeypatch.setattr("workspace_watcher.core_api.serve", lambda config, runtime=None: fake_server)
    # cmd_run probes the real port 8765; force it to look free regardless of
    # whether a real Workspace Watcher instance happens to be running.
    monkeypatch.setattr(socket.socket, "connect_ex", lambda self, addr: 1)

    result = cmd_run(Namespace(config=config_path, workspace_root=None))
    assert result == 0

    store = CoreStore(db_path, read_only=True)
    assert store.get_state("hammerspoon_inbox.health") == {"state": "ok"}
    recorded = [row for row in store.recent_events(50) if row["source"] == "hammerspoon"]
    assert [row["type"] for row in recorded] == ["hammerspoon.app_focused"]


def test_hammerspoon_event_triggers_a_rule_and_notification(tmp_path):
    root = tmp_path / "workspace"
    root.mkdir()
    inbox_path = root / "Logs/workspace-watcher/inbox/hammerspoon-events.jsonl"
    rules_path = tmp_path / "rules.toml"
    rules_path.write_text(
        """
[[rules]]
id = "idle-nudge"
enabled = true
[rules.when]
event = "hammerspoon.idle_started"
[[rules.actions]]
type = "notification"
notification_type = "information"
title = "You went idle"
""".strip()
    )
    config = CoreConfig(
        root, root / "Logs/workspace-watcher/core.db", IntentFolderSettings.for_workspace(root),
        tmp_path / "config.toml", rules_path, 0.1,
        HammerspoonInboxSettings(enabled=True, path=inbox_path),
    )
    runtime = CoreRuntime(config)
    runtime.reload_rules()
    _write_lines(inbox_path, [{"event_id": "idle-1", "kind": "idle_started", "timestamp": "2026-09-18T10:00:00+00:00"}])
    runtime._ingest_hammerspoon()
    notifications = runtime.store.notifications()
    assert len(notifications) == 1
    assert notifications[0]["title"] == "You went idle"
    assert runtime.store.get_state("hammerspoon_inbox.health") == {"state": "ok"}
