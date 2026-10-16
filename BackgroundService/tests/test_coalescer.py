import time

import pytest

from workspace_watcher.coalescer import Coalescer, RawFSEvent


class _FakeHandle:
    def __init__(self, fn):
        self.fn = fn
        self.cancelled = False

    def cancel(self):
        self.cancelled = True


class FakeScheduler:
    """Replaces real threading.Timer so tests control exactly when a
    debounce/burst window "elapses" instead of waiting on wall-clock time."""

    def __init__(self):
        self.handles: list[_FakeHandle] = []

    def __call__(self, delay, fn):
        h = _FakeHandle(fn)
        self.handles.append(h)
        return h

    def fire_all(self):
        pending = [h for h in self.handles if not h.cancelled]
        self.handles = []
        for h in pending:
            if not h.cancelled:
                h.fn()


@pytest.fixture
def settled():
    return []


@pytest.fixture
def scheduler():
    return FakeScheduler()


@pytest.fixture
def coalescer(settled, scheduler):
    c = Coalescer(
        on_settled=lambda s: settled.append(s),
        debounce_seconds=1.5,
        burst_window_seconds=5.0,
        burst_threshold=5,
        schedule_timer=scheduler,
    )
    c.start()
    yield c
    c.stop()


def submit_and_sync(coalescer, event):
    coalescer.submit(event)
    coalescer.wait_idle()


def test_single_create_settles_as_created(coalescer, scheduler, settled):
    submit_and_sync(coalescer, RawFSEvent("created", "Projects/X/a.py", False))
    scheduler.fire_all()
    coalescer.wait_idle()

    assert len(settled) == 1
    assert settled[0].kind == "created"
    assert settled[0].path == "Projects/X/a.py"
    assert settled[0].raw_event_count == 1


def test_rapid_repeated_saves_coalesce_to_one_modified(coalescer, scheduler, settled):
    for _ in range(6):
        submit_and_sync(coalescer, RawFSEvent("modified", "Projects/X/a.py", False))
    scheduler.fire_all()
    coalescer.wait_idle()

    assert len(settled) == 1
    assert settled[0].kind == "modified"
    assert settled[0].raw_event_count == 6


def test_create_then_delete_before_settling_is_a_net_noop(coalescer, scheduler, settled):
    submit_and_sync(coalescer, RawFSEvent("created", "Projects/X/tmp.py", False))
    submit_and_sync(coalescer, RawFSEvent("deleted", "Projects/X/tmp.py", False))
    scheduler.fire_all()
    coalescer.wait_idle()

    assert settled == []


def test_atomic_save_collapses_temp_rename_into_modified(coalescer, scheduler, settled):
    submit_and_sync(coalescer, RawFSEvent("created", "Projects/X/.a.py.swp", False))
    submit_and_sync(coalescer, RawFSEvent(
        "moved", "Projects/X/.a.py.swp", False, dest_path="Projects/X/a.py"
    ))
    scheduler.fire_all()
    coalescer.wait_idle()

    assert len(settled) == 1
    assert settled[0].kind == "modified"
    assert settled[0].path == "Projects/X/a.py"
    assert settled[0].prev_path is None  # the temp name never surfaces


def test_atomic_save_with_pid_hash_temp_name_collapses_to_modified(coalescer, scheduler, settled):
    # Real pattern observed from an Xcode-driven save: temp name is
    # `Entities.swift.tmp.11534.5155d16373cb`, not just `*.tmp`.
    submit_and_sync(coalescer, RawFSEvent(
        "moved", "Projects/X/Entities.swift.tmp.11534.5155d16373cb", False,
        dest_path="Projects/X/Entities.swift",
    ))
    scheduler.fire_all()
    coalescer.wait_idle()

    assert len(settled) == 1
    assert settled[0].kind == "modified"
    assert settled[0].path == "Projects/X/Entities.swift"
    assert settled[0].prev_path is None


def test_rename_within_same_directory(coalescer, scheduler, settled):
    submit_and_sync(coalescer, RawFSEvent(
        "moved", "Projects/X/old.py", False, dest_path="Projects/X/new.py"
    ))
    scheduler.fire_all()
    coalescer.wait_idle()

    assert len(settled) == 1
    assert settled[0].kind == "renamed"
    assert settled[0].path == "Projects/X/new.py"
    assert settled[0].prev_path == "Projects/X/old.py"


def test_move_to_different_directory(coalescer, scheduler, settled):
    submit_and_sync(coalescer, RawFSEvent(
        "moved", "Projects/X/file.py", False, dest_path="Projects/Y/file.py"
    ))
    scheduler.fire_all()
    coalescer.wait_idle()

    assert len(settled) == 1
    assert settled[0].kind == "moved"
    assert settled[0].path == "Projects/Y/file.py"
    assert settled[0].prev_path == "Projects/X/file.py"


def test_directory_rename_is_not_treated_as_atomic_save(coalescer, scheduler, settled):
    submit_and_sync(coalescer, RawFSEvent(
        "moved", "Projects/OldName", True, dest_path="Projects/NewName"
    ))
    scheduler.fire_all()
    coalescer.wait_idle()

    assert len(settled) == 1
    assert settled[0].kind == "renamed"
    assert settled[0].is_directory is True


def test_burst_of_many_files_in_one_directory_coalesces_to_bulk_change(coalescer, scheduler, settled):
    for i in range(12):
        submit_and_sync(coalescer, RawFSEvent("created", f"Projects/X/build/out{i}.o", False))
    scheduler.fire_all()
    coalescer.wait_idle()

    assert len(settled) == 1
    assert settled[0].kind == "bulk_change"
    assert settled[0].path == "Projects/X/build"
    assert settled[0].metadata["file_count"] == 12


def test_activity_below_burst_threshold_stays_per_file(coalescer, scheduler, settled):
    for i in range(3):
        submit_and_sync(coalescer, RawFSEvent("created", f"Projects/X/src/file{i}.py", False))
    scheduler.fire_all()
    coalescer.wait_idle()

    assert len(settled) == 3
    assert {s.kind for s in settled} == {"created"}


def test_two_different_projects_stay_independent(coalescer, scheduler, settled):
    submit_and_sync(coalescer, RawFSEvent("created", "Projects/Alpha/a.py", False))
    submit_and_sync(coalescer, RawFSEvent("created", "Projects/Beta/b.py", False))
    scheduler.fire_all()
    coalescer.wait_idle()

    paths = {s.path for s in settled}
    assert paths == {"Projects/Alpha/a.py", "Projects/Beta/b.py"}
