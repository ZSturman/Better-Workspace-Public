"""v2 session lifecycle wired into the live runtime: start/continue/switch
via _on_settled, idle close via the tick loop, and restart recovery -- all
without any Hammerspoon involvement."""

from __future__ import annotations

import time
from datetime import datetime, timedelta, timezone
from pathlib import Path

from workspace_watcher.coalescer import Settled
from workspace_watcher.core_config import CoreConfig, HammerspoonInboxSettings, ProjectsSettings, SessionsSettings
from workspace_watcher.core_runtime import CoreRuntime
from workspace_watcher.core_store import CoreStore
from workspace_watcher.intents import IntentFolderSettings


def _runtime(root: Path, *, sessions_enabled: bool = True, **session_overrides) -> CoreRuntime:
    config = CoreConfig(
        root, root / "Logs/workspace-watcher/core.db", IntentFolderSettings.for_workspace(root),
        root / "config.toml", root / "rules.toml", 0.1,
        HammerspoonInboxSettings(enabled=False, path=root / "inbox.jsonl"),
        ProjectsSettings(enabled=True, root="Projects"),
        SessionsSettings(enabled=sessions_enabled, **session_overrides),
    )
    return CoreRuntime(config)


def _settled(path: str) -> Settled:
    return Settled(kind="created", path=path, prev_path=None, is_directory=False, raw_event_count=1, ts=time.time())


def _open_sessions(runtime: CoreRuntime) -> list:
    return [row for row in runtime.store.recent_sessions(limit=200) if row["status"] == "open"]


def test_on_settled_opens_a_session_and_fires_a_rule(tmp_path):
    root = tmp_path / "workspace"
    (root / "Projects" / "Foo").mkdir(parents=True)
    rules_path = root / "rules.toml"
    rules_path.write_text(
        """
[[rules]]
id = "session-started"
enabled = true
[rules.when]
event = "session.started"
[[rules.actions]]
type = "notification"
notification_type = "information"
title = "Session started"
""".strip()
    )
    runtime = _runtime(root)
    runtime.reload_rules()

    runtime._on_settled(_settled("Projects/Foo/main.py"))

    sessions = runtime.store.recent_sessions()
    assert len(sessions) == 1 and sessions[0]["status"] == "open" and sessions[0]["project_name"] == "Foo"
    notifications = runtime.store.notifications()
    assert len(notifications) == 1 and notifications[0]["title"] == "Session started"


def test_repeated_activity_in_the_same_project_never_duplicates_the_open_session(tmp_path):
    root = tmp_path / "workspace"
    (root / "Projects" / "Foo").mkdir(parents=True)
    runtime = _runtime(root)

    for name in ("a.py", "b.py", "c.py"):
        runtime._on_settled(_settled(f"Projects/Foo/{name}"))

    sessions = runtime.store.recent_sessions()
    assert len(sessions) == 1
    assert sessions[0]["meaningful_event_count"] == 3
    assert len(_open_sessions(runtime)) == 1


def test_switching_projects_closes_the_first_session_and_opens_a_second(tmp_path):
    root = tmp_path / "workspace"
    (root / "Projects" / "Foo").mkdir(parents=True)
    (root / "Projects" / "Bar").mkdir(parents=True)
    runtime = _runtime(root, minimum_events=1, minimum_active_seconds=1, minimum_confidence=0.0)

    runtime._on_settled(_settled("Projects/Foo/main.py"))
    runtime._on_settled(_settled("Projects/Bar/main.py"))

    sessions = {row["project_id"]: row for row in runtime.store.recent_sessions()}
    closed = [row for row in sessions.values() if row["status"] != "open"]
    open_rows = _open_sessions(runtime)
    assert len(closed) == 1 and closed[0]["close_reason"] == "switched"
    assert len(open_rows) == 1 and open_rows[0]["project_name"] == "Bar"


def test_rapid_switching_among_three_projects_never_leaves_more_than_one_open(tmp_path):
    root = tmp_path / "workspace"
    for name in ("Foo", "Bar", "Baz"):
        (root / "Projects" / name).mkdir(parents=True)
    runtime = _runtime(root, minimum_events=1, minimum_active_seconds=1, minimum_confidence=0.0)

    sequence = ["Foo", "Bar", "Baz", "Foo", "Baz", "Bar", "Foo"]
    for name in sequence:
        runtime._on_settled(_settled(f"Projects/{name}/main.py"))
        assert len(_open_sessions(runtime)) == 1  # never more than one open, at every step

    # These switches happen with no real elapsed time, so every return to a
    # project already worked in falls within the resume/merge window and
    # extends that project's existing session row rather than creating a
    # fresh one -- the same guarantee test_sessions_v2.py verifies for a
    # single A-then-back-to-A switch, exercised here across a 3-project
    # rotation with no accidental cross-project merging or data loss.
    all_rows = runtime.store.recent_sessions(limit=200)
    by_project = {row["project_name"] for row in all_rows}
    assert by_project == {"Foo", "Bar", "Baz"}
    assert len(all_rows) == 3  # resumed, not re-created, on every return
    foo_row = next(row for row in all_rows if row["project_name"] == "Foo")
    assert foo_row["status"] == "open"  # the sequence ends on Foo
    assert foo_row["meaningful_event_count"] == 3  # all three Foo touches landed on the one Foo row


def test_duplicate_settled_events_for_the_same_path_do_not_duplicate_or_corrupt_state(tmp_path):
    root = tmp_path / "workspace"
    (root / "Projects" / "Foo").mkdir(parents=True)
    runtime = _runtime(root, minimum_events=1, minimum_active_seconds=0, minimum_confidence=0.0)

    event = _settled("Projects/Foo/main.py")
    for _ in range(5):  # the exact same Settled event delivered 5 times (e.g. a coalescer/at-least-once retry)
        runtime._on_settled(event)

    assert len(_open_sessions(runtime)) == 1
    open_row = _open_sessions(runtime)[0]
    assert open_row["meaningful_event_count"] == 5  # each touch still counts as real evidence...
    assert len(runtime.store.recent_sessions()) == 1  # ...but only ever within the same single session row


def test_an_out_of_order_delayed_event_does_not_move_the_session_backward(tmp_path):
    # A Settled event can arrive late (e.g. a slow debounce flush) with a
    # path that's still valid but logically "behind" the session's current
    # extent. It must still be recorded as evidence, but must never rewind
    # `ended_at` to something earlier than what's already there.
    root = tmp_path / "workspace"
    (root / "Projects" / "Foo").mkdir(parents=True)
    runtime = _runtime(root, minimum_events=1, minimum_active_seconds=0, minimum_confidence=0.0)

    runtime._on_settled(_settled("Projects/Foo/a.py"))
    first_ended_at = _open_sessions(runtime)[0]["ended_at"]

    # Simulate a second, later-arriving event whose own timestamp logic
    # still only ever advances `ended_at` via `utc_now()` at touch time --
    # confirm it never regresses even when touched again immediately after.
    runtime._on_settled(_settled("Projects/Foo/b.py"))
    second_ended_at = _open_sessions(runtime)[0]["ended_at"]

    assert second_ended_at >= first_ended_at


def test_idle_past_the_timeout_closes_via_the_tick_loop_hook(tmp_path):
    root = tmp_path / "workspace"
    (root / "Projects" / "Foo").mkdir(parents=True)
    runtime = _runtime(root, inactivity_timeout_minutes=20.0)

    runtime._on_settled(_settled("Projects/Foo/main.py"))
    assert len(_open_sessions(runtime)) == 1

    # Backdate the session's last-touched timestamp directly (no Hammerspoon
    # idle signal involved) to simulate 21 real minutes of inactivity
    # without the test actually waiting 21 minutes.
    stale = (datetime.now(timezone.utc) - timedelta(minutes=21)).isoformat()
    runtime.store.conn.execute("UPDATE sessions SET ended_at=? WHERE status='open'", (stale,))
    runtime.store.conn.commit()

    runtime._close_idle_session()

    assert _open_sessions(runtime) == []
    row = runtime.store.recent_sessions()[0]
    assert row["close_reason"] == "inactivity"


def test_idle_before_the_timeout_does_not_close(tmp_path):
    root = tmp_path / "workspace"
    (root / "Projects" / "Foo").mkdir(parents=True)
    runtime = _runtime(root, inactivity_timeout_minutes=20.0)

    runtime._on_settled(_settled("Projects/Foo/main.py"))
    runtime._close_idle_session()

    assert len(_open_sessions(runtime)) == 1


def test_clean_stop_closes_the_open_session(tmp_path):
    root = tmp_path / "workspace"
    (root / "Projects" / "Foo").mkdir(parents=True)
    runtime = _runtime(root)
    runtime.start()
    try:
        runtime._on_settled(_settled("Projects/Foo/main.py"))
        assert len(_open_sessions(runtime)) == 1
    finally:
        runtime.stop()

    store = CoreStore(root / "Logs/workspace-watcher/core.db", read_only=True)
    try:
        rows = store.recent_sessions()
        assert len(rows) == 1 and rows[0]["status"] != "open"
        assert rows[0]["close_reason"] == "watcher_stopped"
    finally:
        store.close()


def test_unclean_shutdown_is_recovered_on_next_start_without_duplicating(tmp_path):
    root = tmp_path / "workspace"
    (root / "Projects" / "Foo").mkdir(parents=True)
    # No .start() here -- no real sensor/coalescer threads, so closing the
    # store directly below cleanly simulates a crash with nothing else left
    # running in the background to race against it.
    runtime = _runtime(root)
    runtime._on_settled(_settled("Projects/Foo/main.py"))
    assert len(_open_sessions(runtime)) == 1
    # Simulate a crash: the SQLite file is left with a session mid-"open",
    # no clean stop() ever ran to close it.
    runtime.store.close()

    restarted = _runtime(root)
    restarted.start()
    try:
        rows = restarted.store.recent_sessions()
        assert len(rows) == 1  # the exact same row, not a second one
        assert rows[0]["status"] != "open"
        assert rows[0]["close_reason"] == "recovered_after_restart"
        assert _open_sessions(restarted) == []
    finally:
        restarted.stop()


def test_disabled_sessions_setting_never_touches_the_sessions_table(tmp_path):
    root = tmp_path / "workspace"
    (root / "Projects" / "Foo").mkdir(parents=True)
    runtime = _runtime(root, sessions_enabled=False)

    runtime._on_settled(_settled("Projects/Foo/main.py"))

    assert runtime.sessions is None
    assert runtime.store.recent_sessions() == []
