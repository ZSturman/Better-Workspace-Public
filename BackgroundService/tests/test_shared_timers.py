"""The coalescer's debounce timers share one thread, however many are pending."""
from __future__ import annotations

import threading
import time

from workspace_watcher.coalescer import real_timer_scheduler


def _wait_until(predicate, timeout=2.0):
    deadline = time.monotonic() + timeout
    while not predicate() and time.monotonic() < deadline:
        time.sleep(0.01)
    return predicate()


def test_many_pending_timers_fire_in_order_on_one_thread():
    before = threading.active_count()
    fired: list[int] = []
    threads: set[str] = set()
    deadlines: dict[int, tuple[float, float]] = {}
    fired_at: dict[int, float] = {}

    def callback(n):
        def fire():
            fired.append(n)
            fired_at[n] = time.monotonic()
            threads.add(threading.current_thread().name)
        return fire

    for n in reversed(range(200)):
        delay = 0.05 + n * 0.001
        before_schedule = time.monotonic()
        real_timer_scheduler(delay, callback(n))
        deadlines[n] = (before_schedule + delay, time.monotonic() + delay)
    assert threading.active_count() <= before + 1

    assert _wait_until(lambda: len(fired) == 200)
    assert sorted(fired) == list(range(200))
    # Delays are relative to each call, not a shared epoch. Under build/CI load,
    # scheduling 200 timers can itself take longer than the 1 ms spacing. Check
    # deadline order when the call intervals make it unambiguous, plus no early
    # firing, rather than incorrectly requiring numeric callback order.
    assert all(fired_at[n] >= deadlines[n][0] for n in fired)
    assert all(deadlines[a][0] <= deadlines[b][1] for a, b in zip(fired, fired[1:]))
    assert threads == {"workspace-watcher-timers"}


def test_a_cancelled_timer_never_fires_and_a_failing_one_does_not_stop_the_rest():
    fired: list[str] = []
    real_timer_scheduler(0.02, lambda: 1 / 0)
    real_timer_scheduler(0.03, lambda: fired.append("cancelled")).cancel()
    real_timer_scheduler(0.04, lambda: fired.append("kept"))

    assert _wait_until(lambda: fired == ["kept"])
    time.sleep(0.05)
    assert fired == ["kept"]


def test_a_sooner_timer_scheduled_later_is_not_held_behind_a_distant_one():
    fired = threading.Event()
    real_timer_scheduler(30, lambda: None)
    real_timer_scheduler(0.02, fired.set)
    assert fired.wait(1.0)
