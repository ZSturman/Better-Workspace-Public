"""Live watchdog coverage for the canonical v2 runtime."""

from __future__ import annotations

import shutil
import time
from pathlib import Path

from workspace_watcher.core_config import CoreConfig
from workspace_watcher.core_runtime import CoreRuntime
from workspace_watcher.intents import IntentFolderSettings


def wait_for(predicate, timeout: float = 8.0) -> bool:
    deadline = time.time() + timeout
    while time.time() < deadline:
        if predicate():
            return True
        time.sleep(0.05)
    return False


def runtime_for(root: Path) -> CoreRuntime:
    config = CoreConfig(root, root / "Logs/workspace-watcher/core.db", IntentFolderSettings.for_workspace(root), root / "config.toml", root / "rules.toml", 0.1)
    return CoreRuntime(config)


def test_live_v2_create_move_copy_next_route_and_restart_are_idempotent(tmp_path):
    """A single observer feeds all domain changes through reconciliation."""
    inbox = tmp_path / "Temporary" / "[[Inbox]]"
    ideas = tmp_path / "Temporary" / "[[Ideas]]"
    route = tmp_path / "Projects" / "ExampleNextApp" / "app" / "docs" / "[[...slug]]"
    inbox.mkdir(parents=True)
    ideas.mkdir(parents=True)
    route.mkdir(parents=True)
    (route.parents[3] / "next.config.ts").write_text("export default {}")

    runtime = runtime_for(tmp_path)
    runtime.start()
    try:
        thought = inbox / "Dashboard Thought"
        thought.mkdir()
        assert wait_for(lambda: runtime.store.item_by_path(str(thought.resolve())) is not None)
        first = runtime.store.item_by_path(str(thought.resolve()))
        assert first is not None
        assert not (thought / "watcher.item.toml").exists()
        item_id = first["id"]
        destination = ideas / thought.name
        thought.rename(destination)
        assert wait_for(lambda: (row := runtime.store.item_by_path(str(destination.resolve()))) is not None and row["id"] == item_id)
        assert not runtime.store.item_by_path(str(route.resolve()))

        copied = ideas / "Dashboard Thought Copy"
        shutil.copytree(destination, copied)
        assert wait_for(lambda: runtime.store.item_by_path(str(copied.resolve())) is not None)
        assert runtime.store.item_by_path(str(copied.resolve()))["id"] != item_id
        assert not (copied / "watcher.item.toml").exists()
    finally:
        runtime.stop()

    # The event log is only quiescent once `stop()` has flushed the
    # coalescer's queue and closed the open session. Counting while the
    # runtime was still live raced the tail of the copytree above -- the
    # `wait_for` only proves the copied *item* landed, not that every settled
    # event it produced has been processed -- so the restart assertion below
    # intermittently saw one extra event that had nothing to do with restarting.
    restarted = runtime_for(tmp_path)
    event_count = len(restarted.store.recent_events(1000))
    restarted.start()
    try:
        assert len(restarted.store.items()) == 2
        assert len(restarted.store.recent_events(1000)) == event_count
    finally:
        restarted.stop()


def test_a_failing_tick_step_does_not_kill_future_ticks(tmp_path):
    """One bad tick (e.g. the real sqlite3.InterfaceError observed in
    production from publish_widget_snapshot's per-project scan) must not
    silently disable idle-session close / Notion sync / notifications for
    the rest of the process's life -- each call to `_tick_once` is
    independent, so a step that raises this second must still run cleanly
    the next."""
    runtime = runtime_for(tmp_path)
    runtime.start()
    try:
        original = runtime.publish_widget_snapshot
        calls = {"n": 0}

        def flaky():
            calls["n"] += 1
            if calls["n"] == 1:
                raise RuntimeError("simulated transient failure")
            return original()

        runtime.publish_widget_snapshot = flaky
        runtime._tick_once()
        assert runtime.store.get_state("tick_loop.health")["state"] == "error"
        runtime._tick_once()
        assert runtime.store.get_state("tick_loop.health")["state"] == "ok"
        assert calls["n"] == 2
    finally:
        runtime.stop()
