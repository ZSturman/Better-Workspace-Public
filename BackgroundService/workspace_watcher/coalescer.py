"""Turns a rapid stream of raw filesystem events into a small number of
settled, meaningful-shaped events.

Three noise problems get handled here, deliberately kept separate from
classification/routing (which happen downstream once an event "settles"):

1. Debounce: an editor's single save can fire several raw events for the
   same path. Each path gets a trailing debounce window; only after the
   path goes quiet do we settle it.

2. Atomic saves: many editors write a new temp file and rename it over the
   target rather than writing in place. Watchdog reports that as a `moved`
   event. If the rename source looks like a transient temp name, this
   collapses the pair into a single `modified` event on the real path
   instead of surfacing the temp filename at all.

3. Bursts: something like a build or `git checkout` can touch hundreds of
   files in one directory within a second or two. Rather than emit hundreds
   of individual events (which would drown out real project activity for
   any downstream consumer), a directory that crosses `burst_threshold`
   distinct paths within `burst_window_seconds` switches into bulk mode: the
   rest of that burst settles as a single `bulk_change` event for the
   directory. Bulk mode clears once the directory goes quiet again.

Everything here runs on one dedicated consumer thread so state mutation
never needs locks: watchdog's own thread(s) only ever call `submit`, which
just pushes onto a queue; timers only ever push a "flush" message onto the
same queue. The clock and timer-scheduling function are injectable so tests
can drive this deterministically without real sleeps.
"""

from __future__ import annotations

import heapq
import posixpath
import queue
import threading
import time
from collections import deque
from dataclasses import dataclass, field
from typing import Callable, Optional

from .noise import NoiseFilter

SettledCallback = Callable[["Settled"], None]
TimerScheduler = Callable[[float, Callable[[], None]], "TimerHandle"]


class TimerHandle:
    def cancel(self) -> None:
        raise NotImplementedError


class _SharedTimerHandle(TimerHandle):
    __slots__ = ("cancelled",)

    def __init__(self) -> None:
        self.cancelled = False

    def cancel(self) -> None:
        self.cancelled = True


class _SharedTimerThread:
    """Every debounce in the process, on one thread.

    A `threading.Timer` per pending path meant a burst (a checkout, a build,
    an unzip) briefly ran hundreds of threads -- 216 measured -- each only to
    push one "flush" message onto the coalescer's queue. Callbacks here must
    stay that cheap: they run on this thread, one after another.
    """

    def __init__(self) -> None:
        self._heap: list[tuple[float, int, Callable[[], None], _SharedTimerHandle]] = []
        self._sequence = 0
        self._condition = threading.Condition()
        self._thread: threading.Thread | None = None

    def schedule(self, delay: float, fn: Callable[[], None]) -> TimerHandle:
        handle = _SharedTimerHandle()
        with self._condition:
            self._sequence += 1
            heapq.heappush(self._heap, (time.monotonic() + max(delay, 0), self._sequence, fn, handle))
            if self._thread is None or not self._thread.is_alive():
                self._thread = threading.Thread(target=self._run, name="workspace-watcher-timers", daemon=True)
                self._thread.start()
            self._condition.notify()
        return handle

    def _run(self) -> None:
        while True:
            with self._condition:
                while not self._heap or self._heap[0][0] > time.monotonic():
                    self._condition.wait(None if not self._heap else self._heap[0][0] - time.monotonic())
                _, _, fn, handle = heapq.heappop(self._heap)
            if handle.cancelled:
                continue
            try:
                fn()
            except Exception:
                # One failing callback must not end every later debounce.
                pass


_shared_timers = _SharedTimerThread()


def real_timer_scheduler(delay: float, fn: Callable[[], None]) -> TimerHandle:
    return _shared_timers.schedule(delay, fn)


@dataclass
class RawFSEvent:
    kind: str  # created, modified, deleted, moved
    src_path: str  # workspace-root-relative, POSIX
    is_directory: bool
    dest_path: Optional[str] = None
    ts: float = field(default_factory=time.time)


@dataclass
class Settled:
    kind: str
    path: str
    prev_path: Optional[str]
    is_directory: bool
    raw_event_count: int
    ts: float
    metadata: dict = field(default_factory=dict)


@dataclass
class _Pending:
    kind: str
    prev_path: Optional[str]
    is_directory: bool
    raw_count: int
    first_ts: float
    timer: TimerHandle


@dataclass
class _Bulk:
    raw_count: int
    sample_paths: list[str]
    first_ts: float
    timer: Optional[TimerHandle]


_STICKY_KINDS = {"renamed", "moved"}


def _merge_kind(old: str, new: str) -> Optional[str]:
    if old in _STICKY_KINDS:
        return "deleted" if new == "deleted" else old
    if old == "created":
        return None if new == "deleted" else "created"
    if old == "modified":
        return "deleted" if new == "deleted" else "modified"
    if old == "deleted":
        return "created" if new == "created" else "deleted"
    return new


class Coalescer:
    def __init__(
        self,
        on_settled: SettledCallback,
        debounce_seconds: float = 1.5,
        burst_window_seconds: float = 5.0,
        burst_threshold: int = 20,
        schedule_timer: TimerScheduler = real_timer_scheduler,
        clock: Callable[[], float] = time.time,
        on_error: Callable[[Any, Exception], None] | None = None,
    ):
        self._on_settled = on_settled
        self._on_error = on_error
        self.dropped_events = 0
        self.last_error: str | None = None
        self._debounce = debounce_seconds
        self._burst_window = burst_window_seconds
        self._burst_threshold = burst_threshold
        self._schedule_timer = schedule_timer
        self._clock = clock

        self._queue: "queue.Queue[tuple]" = queue.Queue()
        self._pending: dict[str, _Pending] = {}
        self._bulk: dict[str, _Bulk] = {}
        self._burst_active: set[str] = set()
        self._burst_windows: dict[str, deque] = {}

        self._thread = threading.Thread(target=self._run, name="workspace-watcher-coalescer", daemon=True)
        self._running = False

    def start(self) -> None:
        self._running = True
        self._thread.start()

    def stop(self) -> None:
        self._queue.put(("stop", None))
        if self._thread.is_alive():
            self._thread.join(timeout=5)

    def has_queued_work(self) -> bool:
        """Whether more messages are already waiting behind the one being
        handled. Lets a settled callback defer expensive work that the
        next message would only repeat."""
        return self._queue.qsize() > 0

    def submit(self, event: RawFSEvent) -> None:
        self._queue.put(("raw", event))

    # -- consumer thread ----------------------------------------------------

    def _run(self) -> None:
        while True:
            msg_type, payload = self._queue.get()
            try:
                if msg_type == "stop":
                    self._flush_all()
                    return
                if msg_type == "raw":
                    self._handle_raw(payload)
                elif msg_type == "flush":
                    self._flush_key(payload)
                elif msg_type == "flush_bulk":
                    self._flush_bulk(payload)
            except Exception as error:
                # This thread is the *only* path from the filesystem into the
                # application, and it used to die on the first exception a
                # settled callback raised -- taking all sensing with it, for
                # the lifetime of the process, with no observable symptom:
                # the HTTP server kept serving, the tick loop kept ticking
                # and `watcher.health` still read "running", while nothing
                # was being observed any more. Seen in production from a
                # transient `sqlite3.InterfaceError` inside the downstream
                # widget-snapshot scan. One bad event must cost exactly that
                # event, so recovery does not depend on noticing and
                # restarting the daemon.
                self._record_failure(payload, error)
            finally:
                self._queue.task_done()

    def _record_failure(self, payload: Any, error: Exception) -> None:
        """Count and remember dropped events so a persistently failing
        consumer is diagnosable rather than looking like a quiet workspace.
        Reported through `on_error` when a caller supplies one, since the
        coalescer itself deliberately knows nothing about storage."""
        self.dropped_events += 1
        self.last_error = f"{type(error).__name__}: {error}"
        if self._on_error is not None:
            try:
                self._on_error(payload, error)
            except Exception:
                pass  # an error reporter that fails must not end the thread

    def wait_idle(self) -> None:
        """Block until every message submitted so far has been processed.
        Used by tests (with an injected fake timer) to get deterministic
        synchronization without relying on real sleeps."""
        self._queue.join()

    def _flush_all(self) -> None:
        for key in list(self._pending.keys()):
            self._flush_key(key)
        for key in list(self._bulk.keys()):
            self._flush_bulk(key)

    # -- raw event handling ---------------------------------------------------

    def _handle_raw(self, ev: RawFSEvent) -> None:
        if ev.kind == "moved" and ev.dest_path is not None:
            self._handle_moved(ev)
        else:
            self._route(ev.src_path, ev.kind, None, ev.is_directory, 1, ev.ts)

    def _handle_moved(self, ev: RawFSEvent) -> None:
        src, dest = ev.src_path, ev.dest_path
        src_pending = self._pending.pop(src, None)
        carried = 0
        if src_pending is not None:
            src_pending.timer.cancel()
            carried = src_pending.raw_count

        src_name = posixpath.basename(src)
        src_parent = posixpath.dirname(src)
        dest_parent = posixpath.dirname(dest)

        if not ev.is_directory and src_parent == dest_parent and NoiseFilter.is_transient_temp_name(src_name):
            kind, prev_path = "modified", None
        elif src_parent == dest_parent:
            kind, prev_path = "renamed", src
        else:
            kind, prev_path = "moved", src

        self._route(dest, kind, prev_path, ev.is_directory, carried + 1, ev.ts, force_kind=True)

    def _route(
        self, path: str, kind: str, prev_path: Optional[str], is_directory: bool,
        count: int, ts: float, force_kind: bool = False,
    ) -> None:
        parent = posixpath.dirname(path)

        if parent in self._burst_active:
            self._bulk_upsert(parent, path, count, ts)
            return

        crossed = self._track_burst_window(parent, path, ts)
        if crossed:
            self._enter_burst_mode(parent, ts)
            self._bulk_upsert(parent, path, count, ts)
            return

        self._simple_upsert(path, kind, prev_path, is_directory, count, ts, force_kind)

    def _track_burst_window(self, parent: str, path: str, ts: float) -> bool:
        if not parent:
            return False
        dq = self._burst_windows.setdefault(parent, deque())
        cutoff = ts - self._burst_window
        while dq and dq[0][0] < cutoff:
            dq.popleft()
        dq.append((ts, path))
        distinct = len({p for _, p in dq})
        return distinct >= self._burst_threshold

    def _enter_burst_mode(self, parent: str, ts: float) -> None:
        self._burst_active.add(parent)
        migrated_count = 0
        sample: list[str] = []
        for path in [p for p in self._pending if posixpath.dirname(p) == parent]:
            pending = self._pending.pop(path)
            pending.timer.cancel()
            migrated_count += pending.raw_count
            if len(sample) < 12:
                sample.append(path)
        if migrated_count:
            bulk = self._bulk.get(parent)
            if bulk is None:
                self._bulk[parent] = _Bulk(migrated_count, sample, ts, None)
            else:
                bulk.raw_count += migrated_count
                bulk.sample_paths.extend(p for p in sample if p not in bulk.sample_paths)

    def _simple_upsert(
        self, path: str, kind: str, prev_path: Optional[str], is_directory: bool,
        count: int, ts: float, force_kind: bool,
    ) -> None:
        existing = self._pending.get(path)
        if existing is None:
            timer = self._schedule_timer(self._debounce, lambda: self._queue.put(("flush", path)))
            self._pending[path] = _Pending(kind, prev_path, is_directory, count, ts, timer)
            return

        existing.timer.cancel()
        merged = kind if force_kind else _merge_kind(existing.kind, kind)
        if merged is None:
            del self._pending[path]
            return

        existing.kind = merged
        existing.prev_path = prev_path if prev_path is not None else existing.prev_path
        existing.raw_count += count
        existing.timer = self._schedule_timer(self._debounce, lambda: self._queue.put(("flush", path)))
        self._pending[path] = existing

    def _bulk_upsert(self, parent: str, path: str, count: int, ts: float) -> None:
        bulk = self._bulk.get(parent)
        if bulk is None:
            bulk = _Bulk(0, [], ts, None)
            self._bulk[parent] = bulk
        if bulk.timer is not None:
            bulk.timer.cancel()
        bulk.raw_count += count
        if path not in bulk.sample_paths and len(bulk.sample_paths) < 12:
            bulk.sample_paths.append(path)
        bulk.timer = self._schedule_timer(self._debounce, lambda: self._queue.put(("flush_bulk", parent)))

    # -- flushing -------------------------------------------------------------

    def _flush_key(self, path: str) -> None:
        pending = self._pending.pop(path, None)
        if pending is None:
            return
        self._on_settled(Settled(
            kind=pending.kind, path=path, prev_path=pending.prev_path,
            is_directory=pending.is_directory, raw_event_count=pending.raw_count,
            ts=self._clock(),
        ))

    def _flush_bulk(self, parent: str) -> None:
        bulk = self._bulk.pop(parent, None)
        self._burst_active.discard(parent)
        self._burst_windows.pop(parent, None)
        if bulk is None:
            return
        self._on_settled(Settled(
            kind="bulk_change", path=parent, prev_path=None, is_directory=True,
            raw_event_count=bulk.raw_count, ts=self._clock(),
            metadata={"file_count": bulk.raw_count, "sample_paths": bulk.sample_paths},
        ))
