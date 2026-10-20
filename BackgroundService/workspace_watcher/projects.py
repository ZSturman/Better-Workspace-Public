"""Project identity.

A "project" is a visible child directory (through underscore containers) of the configured Projects
area. Identity must survive a rename -- a future component asking "is this
still Project X?" should not be forced to rely on the directory name.

Two mechanisms provide that:

1. While the watcher is running, a directory move/rename event for a known
   project root updates its path in place; the project_id never changes.
2. If the watcher was NOT running when a rename happened, startup
   reconciliation matches directories back to registry entries by
   (device, inode) -- the identity of a directory survives `mv` even across
   watcher restarts, as long as it stays on the same volume.

Deliberately not attempted: matching a deleted-and-recreated directory of
the same name back to its old project_id (that is a semantically different
directory, even if the name is identical), and identity for anything other
than the top-level project directory (files/subdirectories inside a project
inherit its project_id but are not projects themselves).
"""

from __future__ import annotations

import time
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Optional

from .store import WorkspaceStore
from .transparent_folders import FOREIGN_NAMES, is_visible_child, visible_children


@dataclass
class ProjectRef:
    project_id: str
    name: str
    path: str  # workspace-root-relative


class ProjectRegistry:
    def __init__(self, store: WorkspaceStore, workspace_root: Path, projects_relpath: str):
        self.store = store
        self.workspace_root = workspace_root
        self.prefix = projects_relpath.strip("/")
        self._cache: dict[str, ProjectRef] = {}
        self._load_cache()

    def _load_cache(self) -> None:
        self._cache.clear()
        for row in self.store.all_projects(status="active"):
            self._cache[row["path"]] = ProjectRef(row["project_id"], row["name"], row["path"])

    def project_root_relpath(self, relpath: str) -> Optional[str]:
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

    def resolve_for_relpath(self, relpath: str) -> Optional[ProjectRef]:
        root_relpath = self.project_root_relpath(relpath)
        if root_relpath is None:
            return None
        if not is_visible_child(self.workspace_root / root_relpath, self.workspace_root / self.prefix):
            return None
        ref = self._cache.get(root_relpath)
        if ref is not None:
            return ref
        # Lazy safety net: the directory exists on disk but we have not
        # registered it yet (e.g. a nested-file event raced the directory's
        # own creation event past noise filtering).
        abspath = self.workspace_root / root_relpath
        if abspath.is_dir():
            return self.ensure_project(root_relpath, abspath, ts=time.time())
        return None

    def ensure_project(self, relpath: str, abspath: Path, ts: float) -> ProjectRef:
        existing = self._cache.get(relpath)
        if existing:
            return existing

        row = self.store.get_project_by_path(relpath)
        if row is not None:
            ref = ProjectRef(row["project_id"], row["name"], relpath)
            self._cache[relpath] = ref
            return ref

        device = inode = None
        try:
            st = abspath.stat()
            device, inode = st.st_dev, st.st_ino
        except OSError:
            pass

        if device is not None:
            by_inode = self.store.get_project_by_inode(device, inode)
            if by_inode is not None:
                # Same directory, different path than last known -- a rename
                # happened while nothing was watching.
                name = Path(relpath).name
                self.store.update_project_path(by_inode["project_id"], relpath, name, ts)
                ref = ProjectRef(by_inode["project_id"], name, relpath)
                self._cache.pop(by_inode["path"], None)
                self._cache[relpath] = ref
                return ref

        project_id = str(uuid.uuid4())
        name = Path(relpath).name
        self.store.create_project(project_id, relpath, name, device, inode, ts)
        ref = ProjectRef(project_id, name, relpath)
        self._cache[relpath] = ref
        return ref

    def handle_root_moved(self, old_relpath: str, new_relpath: str, ts: float) -> Optional[ProjectRef]:
        ref = self._cache.get(old_relpath)
        row = self.store.get_project_by_path(old_relpath) if ref is None else None
        project_id = ref.project_id if ref else (row["project_id"] if row else None)
        if project_id is None:
            # Never seen this directory before under its old name; treat the
            # destination as a freshly detected project instead of guessing.
            return self.ensure_project(new_relpath, self.workspace_root / new_relpath, ts)

        new_name = Path(new_relpath).name
        self.store.update_project_path(project_id, new_relpath, new_name, ts)
        self._cache.pop(old_relpath, None)
        new_ref = ProjectRef(project_id, new_name, new_relpath)
        self._cache[new_relpath] = new_ref
        return new_ref

    def handle_root_deleted(self, relpath: str) -> None:
        ref = self._cache.pop(relpath, None)
        project_id = ref.project_id if ref else None
        if project_id is None:
            row = self.store.get_project_by_path(relpath)
            project_id = row["project_id"] if row else None
        if project_id:
            self.store.mark_project_status(project_id, "deleted")

    def reconcile_startup(self) -> list[ProjectRef]:
        """Scan the Projects directory once at startup so restarts don't lose
        track of projects created (or renamed) while the watcher was down.
        Returns the ProjectRef for every newly-detected project."""
        projects_dir = self.workspace_root / self.prefix
        if not projects_dir.is_dir():
            return []

        # "Newly detected" has to be judged by project_id, not by path: a
        # directory found at a path we've never seen may still turn out to
        # be an existing project that was renamed while nothing was
        # watching (ensure_project matches that case by inode below).
        known_ids_before = {row["project_id"] for row in self.store.all_projects(status="active")}
        seen_relpaths: set[str] = set()
        ts = time.time()
        refs: list[ProjectRef] = []

        for entry in visible_children(projects_dir):
            if not entry.is_dir():
                continue
            relpath = entry.relative_to(self.workspace_root).as_posix()
            seen_relpaths.add(relpath)
            refs.append(self.ensure_project(relpath, entry, ts))

        newly_detected = [r for r in refs if r.project_id not in known_ids_before]

        # Anything registered as active but no longer present on disk under
        # its known path gets marked deleted; it may reappear later via
        # inode matching if it was actually just renamed and we happened to
        # miss it above (handled by ensure_project's inode lookup).
        for row in self.store.all_projects(status="active"):
            if row["path"] not in seen_relpaths:
                self.store.mark_project_status(row["project_id"], "deleted")
                self._cache.pop(row["path"], None)

        return newly_detected
