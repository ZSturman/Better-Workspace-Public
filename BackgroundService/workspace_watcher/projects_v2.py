"""v2-native project identity.

A "project" is a visible child directory (through underscore containers) of the configured Projects root.
Identity survives a rename: while the runtime is live, a directory that
reappears at a new path is matched back to its existing project by
(device, inode); across a restart, the same inode match happens on the next
reconciliation pass instead of a live move event.

Deliberately not attempted (mirrors v1's ``workspace_watcher/projects.py``,
which this module's algorithm is ported from): matching a deleted-and-
recreated directory of the same name back to its old project id, and
identity for anything other than the top-level project directory.

Unlike v1's ``ProjectRegistry`` (imperative: a callback per filesystem event,
plus a separate cold-start reconcile), this is a single idempotent
``rebuild()``, called identically at startup and after every settled
filesystem batch -- the same shape as ``core_engine.IntentIndexer.rebuild()``.
"""

from __future__ import annotations

import uuid
from dataclasses import dataclass
from pathlib import Path

from .core_engine import utc_now
from .core_events import EventTypes, WorkspaceEvent
from .core_store import CoreStore
from .transparent_folders import FOREIGN_NAMES, is_visible_child, visible_children
from .project_documents import ensure_document


@dataclass
class ProjectRef:
    project_id: str
    name: str
    path: str  # workspace-root-relative


class ProjectRegistry:
    def __init__(self, store: CoreStore, workspace_root: Path, projects_relpath: str, *, write_documents: bool = False) -> None:
        self.store = store
        # Better Projects' Project.betterproject bridge. Off by default: Better
        # Workspace links projects by file identity and keeps the Notion mapping
        # itself, so nothing needs a new document, and writing one into every new
        # project folder (and rewriting it on every rename) is a file this service
        # put in the user's project without being asked. Existing documents are left
        # exactly as they are.
        self.write_documents = write_documents
        self.workspace_root = workspace_root
        self.prefix = projects_relpath.strip("/")
        self._cache: dict[str, ProjectRef] = {}
        self._load_cache()

    def _load_cache(self) -> None:
        self._cache.clear()
        for row in self.store.projects(status="active"):
            self._cache[row["path"]] = ProjectRef(row["id"], row["name"], row["path"])

    def project_root_relpath(self, relpath: str) -> str | None:
        """If relpath is under the Projects area, return the workspace-relative
        path of the top-level project directory it belongs to (which may be
        relpath itself). Returns None for the Projects area root or paths
        outside it."""
        relpath = relpath.strip("/")
        if relpath == self.prefix or not relpath.startswith(f"{self.prefix}/"):
            return None
        rest = relpath[len(self.prefix) + 1 :]
        if not rest:
            return None
        components: list[str] = []
        for name in rest.split("/"):
            if not name or name.startswith(".") or name in FOREIGN_NAMES:
                return None
            components.append(name)
            if not name.startswith("_"):
                return f"{self.prefix}/{'/'.join(components)}"
        return None

    def resolve_for_relpath(self, relpath: str) -> ProjectRef | None:
        root_relpath = self.project_root_relpath(relpath)
        if root_relpath is None:
            return None
        if not is_visible_child(self.workspace_root / root_relpath, self.workspace_root / self.prefix):
            return None
        ref = self._cache.get(root_relpath)
        if ref is not None:
            return ref
        # Lazy safety net: the directory exists on disk but hasn't been
        # registered yet (e.g. a nested-file event raced the directory's own
        # creation event).
        abspath = self.workspace_root / root_relpath
        if abspath.is_dir():
            return self.ensure_project(root_relpath, abspath, utc_now())
        return None

    def ensure_project(self, relpath: str, abspath: Path, ts: str) -> ProjectRef:
        existing = self._cache.get(relpath)
        if existing:
            self._ensure_document(abspath, existing)
            return existing

        row = self.store.project_by_path(relpath)
        if row is not None:
            ref = ProjectRef(row["id"], row["name"], relpath)
            self._cache[relpath] = ref
            self._ensure_document(abspath, ref)
            return ref

        device = inode = None
        try:
            stat = abspath.stat()
            device, inode = stat.st_dev, stat.st_ino
        except OSError:
            pass

        if device is not None:
            by_inode = self.store.project_by_inode(device, inode)
            if by_inode is not None:
                # Same directory, different path than last known -- a rename
                # happened while nothing was watching.
                name = Path(relpath).name
                self.store.rename_project(by_inode["id"], new_path=relpath, new_name=name, timestamp=ts)
                ref = ProjectRef(by_inode["id"], name, relpath)
                self._cache.pop(by_inode["path"], None)
                self._cache[relpath] = ref
                self._event(EventTypes.PROJECT_RENAMED, ref.project_id, {"path": relpath, "name": name, "previous_path": by_inode["path"]})
                self._ensure_document(abspath, ref)
                return ref

        project_id = str(uuid.uuid4())
        name = Path(relpath).name
        self.store.create_project(project_id=project_id, path=relpath, root_path=self.prefix, name=name, device=device, inode=inode, timestamp=ts)
        ref = ProjectRef(project_id, name, relpath)
        self._cache[relpath] = ref
        self._event(EventTypes.PROJECT_DISCOVERED, project_id, {"path": relpath, "name": name})
        self._ensure_document(abspath, ref)
        return ref

    def _ensure_document(self, directory: Path, ref: ProjectRef) -> None:
        """The document is an adjacent project record, never hidden watcher
        metadata. Failures must not interrupt filesystem sensing; a future
        rebuild retries the safe, atomic operation.
        """
        if not self.write_documents:
            return
        try:
            notion = self.store.notion_project_for(ref.project_id)
            ensure_document(
                directory,
                workspace_project_id=ref.project_id,
                title=ref.name,
                notion_project_id=notion["notion_project_id"] if notion is not None else None,
            )
        except OSError:
            # Permission/full-disk failures remain a project-index concern,
            # not a reason to stop event observation or session tracking.
            return

    def rebuild(self) -> dict[str, int]:
        """Bounded, idempotent scan of the Projects root.

        Run identically at startup and after every settled filesystem batch,
        mirroring ``IntentIndexer.rebuild()``'s shape: inventory what's on
        disk, reconcile against what's registered, never guess at a live
        move/delete beyond what (device, inode) evidence actually supports.
        """
        counters = {"projects": 0, "discovered": 0, "renamed": 0, "deleted": 0}
        projects_dir = self.workspace_root / self.prefix
        if not projects_dir.is_dir():
            return counters

        ts = utc_now()
        # Tracked by project id, not path: a rename changes a known project's
        # path mid-scan, and the deletion check below must not mistake that
        # for the old path having disappeared.
        known_before = {row["id"]: row["path"] for row in self.store.projects(status="active")}
        seen_ids: set[str] = set()

        for entry in visible_children(projects_dir):
            if not entry.is_dir():
                continue
            relpath = entry.relative_to(self.workspace_root).as_posix()
            ref = self.ensure_project(relpath, entry, ts)
            seen_ids.add(ref.project_id)
            counters["projects"] += 1
            if ref.project_id not in known_before:
                counters["discovered"] += 1
            elif known_before[ref.project_id] != relpath:
                counters["renamed"] += 1

        for project_id, path in known_before.items():
            if project_id not in seen_ids:
                self.store.mark_project_status(project_id, "deleted", ts)
                self._cache.pop(path, None)
                counters["deleted"] += 1
                self._event(EventTypes.PROJECT_DELETED, project_id, {"path": path})

        return counters

    def _event(self, event_type: str, entity_id: str | None, payload: dict) -> None:
        self.store.record_event(WorkspaceEvent(type=event_type, entity_id=entity_id, payload=payload, source="filesystem"))
