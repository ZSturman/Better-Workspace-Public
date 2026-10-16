"""Filesystem reconciliation must keep up with the event stream.

A reconcile costs seconds on a real Workspace, and it used to run once per
settled event -- including events the watcher caused by writing its own
database. The queue then grew without bound and activity fell days behind
while health read "running". These pin the two halves of the fix: one
reconcile per burst, and none at all for the watcher's own writes.
"""
from __future__ import annotations

import time
from pathlib import Path

from workspace_watcher.coalescer import Settled
from workspace_watcher.core_config import CoreConfig, HammerspoonInboxSettings, ProjectsSettings, SessionsSettings
from workspace_watcher.core_runtime import CoreRuntime
from workspace_watcher.intents import IntentFolderSettings


def _runtime(root: Path) -> CoreRuntime:
    config = CoreConfig(
        root, root / "Logs/workspace-watcher/core.db", IntentFolderSettings.for_workspace(root),
        root / "config.toml", root / "rules.toml", 0.1,
        HammerspoonInboxSettings(enabled=False, path=root / "inbox.jsonl"),
        ProjectsSettings(enabled=True, root="Projects"),
        SessionsSettings(enabled=True),
    )
    return CoreRuntime(config)


def _settled(path: str, *, kind: str = "created", is_directory: bool = False, prev_path: str | None = None) -> Settled:
    return Settled(kind=kind, path=path, prev_path=prev_path, is_directory=is_directory, raw_event_count=1, ts=time.time())


def _counting(runtime: CoreRuntime) -> list[str]:
    reasons: list[str] = []
    original = runtime._reconcile

    def counted(reason: str):
        reasons.append(reason)
        return original(reason)

    runtime._reconcile = counted
    return reasons


def test_events_queued_behind_one_share_a_single_trailing_reconcile(tmp_path):
    (tmp_path / "Projects/Foo").mkdir(parents=True)
    runtime = _runtime(tmp_path)
    reasons = _counting(runtime)
    queued = [True, True, False]
    runtime.coalescer.has_queued_work = lambda: queued[0]

    for name in ("a", "b", "c"):
        runtime._on_settled(_settled(f"Projects/Foo/{name}", is_directory=True))
        queued.pop(0)

    assert reasons == ["filesystem:created"]
    # Activity is still concluded per event, not per burst.
    assert runtime.store.get_state("project.current")["name"] == "Foo"


def test_the_watchers_own_writes_never_trigger_a_reconcile(tmp_path):
    runtime = _runtime(tmp_path)
    reasons = _counting(runtime)
    runtime.coalescer.has_queued_work = lambda: False

    runtime._on_settled(_settled("Logs/workspace-watcher/core.db"))
    runtime._on_settled(_settled("Logs/workspace-watcher/widget-snapshot.json"))

    assert reasons == []


def test_a_deferred_reconcile_still_runs_when_a_self_write_ends_the_burst(tmp_path):
    (tmp_path / "Projects/Foo").mkdir(parents=True)
    runtime = _runtime(tmp_path)
    reasons = _counting(runtime)
    queued = [True, False]
    runtime.coalescer.has_queued_work = lambda: queued[0]

    runtime._on_settled(_settled("Projects/Foo/a", is_directory=True))
    queued.pop(0)
    runtime._on_settled(_settled("Logs/workspace-watcher/core.db"))

    assert reasons == ["filesystem:created"]


def test_the_tick_loop_runs_a_reconcile_left_pending(tmp_path):
    runtime = _runtime(tmp_path)
    reasons = _counting(runtime)
    runtime._reconcile_pending = "filesystem:moved"
    runtime.coalescer.has_queued_work = lambda: False

    runtime._tick_once()

    assert reasons == ["filesystem:moved"]
    assert runtime._reconcile_pending is None


def test_changes_a_reconcile_cannot_see_never_trigger_one(tmp_path):
    # A Git client polling a repo touches `.git` every few seconds; each of
    # these used to start another 45-second walk of the whole Workspace.
    (tmp_path / "Projects/Foo/.git").mkdir(parents=True)
    runtime = _runtime(tmp_path)
    reasons = _counting(runtime)
    runtime.coalescer.has_queued_work = lambda: False

    runtime._on_settled(_settled("Projects/Foo/.git/index.lock"))
    runtime._on_settled(_settled("Projects/Foo/.git/index.lock", kind="deleted"))
    runtime._on_settled(_settled("Projects/Foo/.git/refs/heads", is_directory=True))
    runtime._on_settled(_settled("Projects/Foo/node_modules/left-pad", is_directory=True))
    runtime._on_settled(_settled("Projects/Foo/.git", kind="bulk_change", is_directory=True))
    # Ordinary file edits and a directory's own "modified" carry nothing a
    # reconcile reads.
    runtime._on_settled(_settled("Projects/Foo/main.py", kind="modified"))
    runtime._on_settled(_settled("Projects/Foo/notes.md"))
    runtime._on_settled(_settled("Projects/Foo/src", kind="modified", is_directory=True))

    assert reasons == []
    # Activity conclusions are unaffected: the edit still counts as work.
    assert runtime.store.get_state("project.current")["name"] == "Foo"


def test_changes_that_can_alter_the_index_still_reconcile(tmp_path):
    ideas = tmp_path / "[[Ideas]]"
    (ideas / "dist").mkdir(parents=True)
    (tmp_path / "Projects").mkdir()
    runtime = _runtime(tmp_path)
    runtime._reconcile("startup")  # learns that [[Ideas]] is an intent folder
    reasons = _counting(runtime)
    runtime.coalescer.has_queued_work = lambda: False

    runtime._on_settled(_settled("Somewhere/[[Later]]", is_directory=True))
    runtime._on_settled(_settled("[[Ideas]]/Old", kind="moved", is_directory=True, prev_path="[[Ideas]]/New"))
    runtime._on_settled(_settled("Somewhere/watcher.intent.toml", kind="modified"))
    runtime._on_settled(_settled("[[Ideas]]/Thing/watcher.item.toml", kind="deleted"))
    runtime._on_settled(_settled("Site/next.config.js"))
    # A pruned name is still an item where the indexer lists entries outright.
    runtime._on_settled(_settled("[[Ideas]]/dist", kind="deleted", is_directory=True))
    runtime._on_settled(_settled("Projects/build", is_directory=True))
    runtime._on_settled(_settled("Somewhere", kind="bulk_change", is_directory=True))
    # Moving a folder out of a pruned tree brings it into view.
    runtime._on_settled(_settled("Foo/[[Drafts]]", kind="moved", is_directory=True, prev_path="node_modules/[[Drafts]]"))

    assert len(reasons) == 9


def test_restating_an_unchanged_state_writes_nothing(tmp_path):
    runtime = _runtime(tmp_path)
    store = runtime.store
    store.set_state("tick_loop.health", {"state": "ok"}, "2026-10-06T00:00:00Z")
    changes = store.conn.total_changes

    store.set_state("tick_loop.health", {"state": "ok"}, "2026-10-06T00:00:01Z")
    assert store.conn.total_changes == changes

    store.set_state("tick_loop.health", {"state": "error", "error": "x"}, "2026-10-06T00:00:02Z")
    assert store.get_state("tick_loop.health") == {"state": "error", "error": "x"}


def test_the_tick_rebuilds_the_widget_snapshot_only_when_its_inputs_changed(tmp_path):
    # Rebuilding it every second (a query per project) was the service's
    # whole idle CPU once reconciles stopped.
    runtime = _runtime(tmp_path)
    runtime.coalescer.has_queued_work = lambda: False
    builds: list[int] = []
    original = runtime.publish_widget_snapshot
    runtime.publish_widget_snapshot = lambda: builds.append(1) or original()

    runtime._tick_once()
    runtime._tick_once()  # the first tick's own health writes
    builds.clear()

    for _ in range(5):
        runtime._tick_once()
    assert builds == []

    runtime.store.set_state("project.current", {"name": "Foo"}, "2026-10-06T00:00:00Z")
    runtime._tick_once()
    assert len(builds) == 1

    # Clock-derived fields still refresh without any change.
    runtime._widget_published_at -= runtime.WIDGET_SNAPSHOT_MAX_AGE_SECONDS
    runtime._tick_once()
    assert len(builds) == 2
