"""Thin wrapper around watchdog. This is the only module that imports
watchdog -- everything past `Coalescer.submit` deals only in
workspace-root-relative POSIX paths and the small `RawFSEvent` shape, so
swapping the underlying filesystem-watching library later would not touch
anything else.
"""

from __future__ import annotations

import os
from pathlib import Path

from watchdog.events import FileSystemEvent, FileSystemEventHandler
from watchdog.observers import Observer

from .coalescer import Coalescer, RawFSEvent


def to_relpath(abspath: str, root: Path) -> str:
    rel = os.path.relpath(abspath, root)
    return rel.replace(os.sep, "/")


def is_within(relpath: str, ancestor: str | None) -> bool:
    if not ancestor or ancestor in (".", ""):
        return False
    return relpath == ancestor or relpath.startswith(ancestor.rstrip("/") + "/")


class _Handler(FileSystemEventHandler):
    def __init__(self, root: Path, coalescer: Coalescer, self_exclude: str | None = None):
        self._root = root
        self._coalescer = coalescer
        self._self_exclude = self_exclude

    def _submit(self, kind: str, event: FileSystemEvent, dest_abspath: str | None = None) -> None:
        src_rel = to_relpath(event.src_path, self._root)
        if src_rel.startswith(".."):
            return
        dest_rel = None
        if dest_abspath is not None:
            dest_rel = to_relpath(dest_abspath, self._root)
            if dest_rel.startswith(".."):
                return
        # The watcher's own data directory (core.db and its journal, the widget
        # snapshot) changes on every tick. Those writes are the watcher's, never
        # the person's: every consumer already refuses to act on them, and
        # letting them in turned each journal write (~34 a second) into a debounce
        # timer thread and a settle under the runtime lock: ~35,000 threads in 25
        # minutes. (Not the service's sustained CPU use; see BACKGROUND_SERVICE.md.)
        if is_within(src_rel, self._self_exclude) and (dest_rel is None or is_within(dest_rel, self._self_exclude)):
            return
        self._coalescer.submit(
            RawFSEvent(kind=kind, src_path=src_rel, is_directory=event.is_directory, dest_path=dest_rel)
        )

    def on_created(self, event: FileSystemEvent) -> None:
        self._submit("created", event)

    def on_modified(self, event: FileSystemEvent) -> None:
        self._submit("modified", event)

    def on_deleted(self, event: FileSystemEvent) -> None:
        self._submit("deleted", event)

    def on_moved(self, event: FileSystemEvent) -> None:
        self._submit("moved", event, dest_abspath=event.dest_path)


class FilesystemWatcher:
    """One observer with one or more non-overlapping scheduled roots.

    ``root`` is the path used when converting all callbacks to the stable
    workspace-relative representation.  ``watch_roots`` is deliberately
    separate: a v2 caller can express a readable configuration containing
    Workspace, Temporary and Projects while scheduling Workspace only.
    """

    def __init__(self, root: Path, coalescer: Coalescer, *, watch_roots: list[Path] | tuple[Path, ...] | None = None,
                 self_exclude: str | None = None):
        self._root = root.resolve()
        self._observer = Observer()
        roots = watch_roots or [self._root]
        for watch_root in roots:
            self._observer.schedule(_Handler(self._root, coalescer, self_exclude), str(watch_root), recursive=True)

    def start(self) -> None:
        self._observer.start()

    def stop(self) -> None:
        self._observer.stop()
        self._observer.join(timeout=5)
