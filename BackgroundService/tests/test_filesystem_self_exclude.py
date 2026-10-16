"""The watcher's own writes never enter the event pipeline."""

from pathlib import Path
from types import SimpleNamespace

from workspace_watcher.filesystem import _Handler, is_within


class _Recorder:
    def __init__(self):
        self.events = []

    def submit(self, event):
        self.events.append(event)


def _event(path, directory=False, dest=None):
    return SimpleNamespace(src_path=path, is_directory=directory, dest_path=dest)


def test_events_inside_the_data_directory_are_dropped(tmp_path: Path):
    recorder = _Recorder()
    handler = _Handler(tmp_path, recorder, "Logs/workspace-watcher")
    handler.on_modified(_event(str(tmp_path / "Logs/workspace-watcher/core.db-journal")))
    handler.on_created(_event(str(tmp_path / "Logs/workspace-watcher/widget-snapshot.tmp")))
    handler.on_moved(_event(str(tmp_path / "Logs/workspace-watcher/a.tmp"),
                            dest=str(tmp_path / "Logs/workspace-watcher/widget-snapshot.json")))
    assert recorder.events == []


def test_real_work_and_moves_out_of_the_data_directory_still_arrive(tmp_path: Path):
    recorder = _Recorder()
    handler = _Handler(tmp_path, recorder, "Logs/workspace-watcher")
    handler.on_modified(_event(str(tmp_path / "Projects/App/main.py")))
    handler.on_modified(_event(str(tmp_path / "Logs/workspace-watcher-notes.md")))
    handler.on_moved(_event(str(tmp_path / "Logs/workspace-watcher/export.csv"),
                            dest=str(tmp_path / "Projects/App/export.csv")))
    assert [e.src_path for e in recorder.events] == [
        "Projects/App/main.py", "Logs/workspace-watcher-notes.md", "Logs/workspace-watcher/export.csv"]


def test_is_within():
    assert is_within("Logs/w", "Logs/w")
    assert is_within("Logs/w/core.db", "Logs/w")
    assert not is_within("Logs/wx/core.db", "Logs/w")
    assert not is_within("anything", None)
    assert not is_within("anything", ".")
