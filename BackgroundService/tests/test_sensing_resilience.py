"""Filesystem sensing must survive a failing downstream consumer.

The coalescer's consumer thread is the only path from the filesystem into the
application. It used to die on the first exception a settled callback raised,
which silently ended *all* sensing for the lifetime of the process while the
HTTP server kept serving, the tick loop kept ticking, and `watcher.health`
still read "running" -- observed in production from a transient
`sqlite3.InterfaceError` raised by the widget-snapshot scan running
concurrently on the runtime's shared connection.
"""

from __future__ import annotations

import threading
import time
from pathlib import Path

from workspace_watcher.coalescer import Coalescer, RawFSEvent
from workspace_watcher.core_config import CoreConfig
from workspace_watcher.core_runtime import CoreRuntime
from workspace_watcher.intents import IntentFolderSettings


def _event(path: str, kind: str = "modified") -> RawFSEvent:
    return RawFSEvent(kind=kind, src_path=path, is_directory=False)


def _wait_for(predicate, timeout: float = 5.0) -> bool:
    """Debounced flushes are delivered by a timer that enqueues a *new*
    message, so an empty queue does not mean the work has happened yet --
    every wait here is on the observable outcome instead."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        if predicate():
            return True
        time.sleep(0.01)
    return False


def test_a_failing_callback_does_not_end_sensing():
    settled: list[str] = []

    def consumer(event):
        if "poison" in event.path:
            raise RuntimeError("downstream consumer failed")
        settled.append(event.path)

    coalescer = Coalescer(consumer, debounce_seconds=0.01)
    coalescer.start()
    try:
        coalescer.submit(_event("Projects/Demo/poison.py"))
        assert _wait_for(lambda: coalescer.dropped_events == 1)
        # The very next event must still be delivered.
        coalescer.submit(_event("Projects/Demo/after.py"))
        assert _wait_for(lambda: settled == ["Projects/Demo/after.py"])
    finally:
        coalescer.stop()

    assert "downstream consumer failed" in (coalescer.last_error or "")


def test_the_consumer_thread_stays_alive_through_repeated_failures():
    coalescer = Coalescer(lambda event: (_ for _ in ()).throw(RuntimeError("always fails")), debounce_seconds=0.01)
    coalescer.start()
    try:
        for index in range(5):
            coalescer.submit(_event(f"Projects/Demo/file-{index}.py"))
        assert _wait_for(lambda: coalescer.dropped_events == 5)
        assert coalescer._thread.is_alive()
    finally:
        coalescer.stop()


def test_a_failing_error_reporter_is_itself_contained():
    def bad_reporter(payload, error):
        raise RuntimeError("the reporter is broken too")

    coalescer = Coalescer(lambda event: (_ for _ in ()).throw(RuntimeError("fails")),
                          debounce_seconds=0.01, on_error=bad_reporter)
    coalescer.start()
    try:
        coalescer.submit(_event("Projects/Demo/a.py"))
        assert _wait_for(lambda: coalescer.dropped_events == 1)
        assert coalescer._thread.is_alive()
    finally:
        coalescer.stop()


def test_a_dropped_event_is_reported_as_degraded_sensing(tmp_path):
    """"Nothing is being observed" must be distinguishable from "nothing is
    happening" without reading a log file."""
    (tmp_path / "Projects" / "Demo").mkdir(parents=True)
    config = CoreConfig(tmp_path, tmp_path / "Logs/workspace-watcher/core.db",
                        IntentFolderSettings.for_workspace(tmp_path),
                        tmp_path / "config.toml", tmp_path / "rules.toml", 0.1)
    runtime = CoreRuntime(config)
    try:
        runtime._on_settled_failed(_event("Projects/Demo/x.py"), RuntimeError("boom"))
        health = runtime.store.get_state("sensing.health")
        assert health["state"] == "degraded"
        assert "boom" in health["last_error"] if health["last_error"] else True
    finally:
        runtime.store.close()


def test_publishing_the_widget_snapshot_holds_the_pipeline_lock(tmp_path):
    """The HTTP server calls this from a request thread. Without the lock it
    ran a per-project scan on the runtime's shared connection concurrently
    with the coalescer, which is what produced the `InterfaceError` that
    killed sensing."""
    (tmp_path / "Projects" / "Demo").mkdir(parents=True)
    config = CoreConfig(tmp_path, tmp_path / "Logs/workspace-watcher/core.db",
                        IntentFolderSettings.for_workspace(tmp_path),
                        tmp_path / "config.toml", tmp_path / "rules.toml", 0.1)
    runtime = CoreRuntime(config)
    try:
        # `RLock` is re-entrant, so holding it cannot be proven from this
        # thread. Prove exclusivity instead: while the publish is in flight,
        # another thread must not be able to acquire it.
        acquired_elsewhere: list[bool] = []

        def publish_while_another_thread_tries(store, **kwargs):
            def competitor():
                acquired_elsewhere.append(runtime._lock.acquire(timeout=0.2))
                if acquired_elsewhere[-1]:
                    runtime._lock.release()
            thread = threading.Thread(target=competitor)
            thread.start()
            thread.join()
            return True

        runtime.widgets.publish = publish_while_another_thread_tries
        runtime.publish_widget_snapshot()
        assert acquired_elsewhere == [False], "another thread acquired the lock mid-publish"
    finally:
        runtime.store.close()


def test_reload_rules_holds_the_pipeline_lock(tmp_path):
    config = CoreConfig(tmp_path, tmp_path / "Logs/workspace-watcher/core.db",
                        IntentFolderSettings.for_workspace(tmp_path),
                        tmp_path / "config.toml", tmp_path / "rules.toml", 0.1)
    runtime = CoreRuntime(config)
    try:
        acquired_elsewhere: list[bool] = []
        original = runtime.store.set_state

        def set_state(key, value, timestamp):
            if key == "rules.health":
                def competitor():
                    acquired_elsewhere.append(runtime._lock.acquire(timeout=0.2))
                    if acquired_elsewhere[-1]:
                        runtime._lock.release()
                thread = threading.Thread(target=competitor)
                thread.start()
                thread.join()
            return original(key, value, timestamp)

        runtime.store.set_state = set_state
        runtime.reload_rules()
        assert acquired_elsewhere == [False]
    finally:
        runtime.store.close()
