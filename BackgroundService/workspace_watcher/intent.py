"""Semantic ("intent") folder detection and item indexing.

Folders like "For Inspiration" or "To Archive" are matched purely by
directory *name* (case-insensitive, plus configured aliases) -- see
``config.IntentFolderConfig``. Matching a path is a cheap, in-memory
per-event check (walk path segments, look up a dict) with no filesystem
I/O, which is what keeps this consistent with the rest of the watcher's
"no repeated whole-workspace scans" design: a full directory walk only
happens in ``IntentItemIndex.rebuild()`` (startup / manual `intent rebuild`),
never on ordinary file activity.

An "item" is an immediate child of a matched intent folder -- exactly one
level deep, mirroring how a "project" is an immediate child of `Projects/`.
Nested content inside an item (e.g. files inside "Dashboard Screenshots/")
is not separately indexed; only the item root and its optional
``.item.toml`` are.
"""

from __future__ import annotations

import os
import time
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Optional

from .config import Config, IntentFolderConfig
from .item_metadata import metadata_path_for, parse_item_metadata
from .store import WorkspaceStore

DEFAULT_IGNORE_DIRNAMES = {".git", "node_modules", ".venv", "venv", "__pycache__", ".Trash"}


@dataclass(frozen=True)
class IntentFolderIndex:
    """Fast name/alias -> config lookup, rebuilt only when config changes."""

    by_normalized_name: dict[str, IntentFolderConfig]

    @classmethod
    def from_config(cls, config: Config) -> "IntentFolderIndex":
        mapping: dict[str, IntentFolderConfig] = {}
        for folder in config.intent_folders:
            mapping[folder.name.strip().casefold()] = folder
            for alias in folder.aliases:
                mapping[alias.strip().casefold()] = folder
        return cls(mapping)

    def match_name(self, segment: str) -> Optional[IntentFolderConfig]:
        return self.by_normalized_name.get(segment.strip().casefold())


@dataclass(frozen=True)
class IntentMatch:
    folder: IntentFolderConfig
    folder_relpath: str   # workspace-relative path of the matched folder itself
    item_relpath: str     # workspace-relative path of the item (immediate child of the folder)
    is_folder_root: bool  # True when the event path *is* the intent folder itself


def _in_scope(folder_relpath: str, config: Config) -> bool:
    if not config.intent.roots:
        return True
    return any(
        folder_relpath == root.strip("/") or folder_relpath.startswith(root.strip("/") + "/")
        for root in config.intent.roots
    )


def classify_intent(relpath: str, config: Config, index: IntentFolderIndex) -> Optional[IntentMatch]:
    """Find the intent folder nearest the leaf of ``relpath``, if any."""

    if not config.intent.enabled or not relpath:
        return None
    segments = relpath.strip("/").split("/")
    if len(segments) > config.intent.max_depth:
        segments = segments[: config.intent.max_depth]
    # Search from the deepest ancestor toward the root so a folder nested
    # inside another intent folder resolves to the closer one.
    for depth in range(len(segments), 0, -1):
        folder_relpath = "/".join(segments[:depth])
        folder_cfg = index.match_name(segments[depth - 1])
        if folder_cfg is None or not _in_scope(folder_relpath, config):
            continue
        if depth == len(segments):
            return IntentMatch(folder_cfg, folder_relpath, folder_relpath, True)
        item_relpath = "/".join(segments[: depth + 1])
        return IntentMatch(folder_cfg, folder_relpath, item_relpath, False)
    return None


class IntentItemIndex:
    """Indexes immediate children of matched intent folders into SQLite."""

    def __init__(self, store: WorkspaceStore, workspace_root: Path) -> None:
        self.store = store
        self.workspace_root = workspace_root

    # -- single-item incremental refresh (called from the event pipeline) --

    def refresh_item(self, match: IntentMatch, now: float | None = None) -> None:
        now = time.time() if now is None else now
        item_name = match.item_relpath.rsplit("/", 1)[-1]
        abspath = self.workspace_root / match.item_relpath
        if not abspath.exists():
            self.store.mark_item_deleted(match.item_relpath, now)
            return
        self._index_one(match.folder, match.folder_relpath, abspath, match.item_relpath, item_name, now)

    # -- bounded full rebuild (startup / manual only) -----------------------

    def rebuild(self, config: Config, *, reason: str) -> dict[str, int]:
        now = time.time()
        index = IntentFolderIndex.from_config(config)
        found_folders = 0
        found_items = 0
        seen_paths: set[str] = set()
        for folder_relpath, folder_cfg in self._walk_matching_folders(config, index):
            found_folders += 1
            abspath = self.workspace_root / folder_relpath
            try:
                entries = sorted(os.scandir(abspath), key=lambda e: e.name.casefold())
            except OSError:
                continue
            for entry in entries:
                if entry.name.startswith("."):
                    continue
                item_relpath = f"{folder_relpath}/{entry.name}"
                seen_paths.add(item_relpath)
                self._index_one(folder_cfg, folder_relpath, Path(entry.path), item_relpath, entry.name, now)
                found_items += 1
        for row in self.store.all_items():
            if row["path"] not in seen_paths and row["exists_flag"]:
                self.store.mark_item_deleted(row["path"], now)
        self.store.set_state("intent.last_rebuild", {"at": now, "reason": reason, "folders": found_folders, "items": found_items})
        return {"folders": found_folders, "items": found_items}

    def _walk_matching_folders(self, config: Config, index: IntentFolderIndex):
        max_depth = config.intent.max_depth
        roots = [self.workspace_root / r.strip("/") for r in config.intent.roots] or [self.workspace_root]
        seen: set[str] = set()
        for root in roots:
            if not root.is_dir():
                continue
            root_depth = len(root.relative_to(self.workspace_root).parts) if root != self.workspace_root else 0
            for current_root, dirnames, _filenames in os.walk(root):
                current_path = Path(current_root)
                rel_parts = current_path.relative_to(self.workspace_root).parts
                if len(rel_parts) - root_depth >= max_depth:
                    dirnames[:] = []
                    continue
                dirnames[:] = [d for d in dirnames if d not in DEFAULT_IGNORE_DIRNAMES and not d.startswith(".")]
                pruned = []
                for dirname in dirnames:
                    folder_cfg = index.match_name(dirname)
                    child_relpath = "/".join((*rel_parts, dirname)) if rel_parts else dirname
                    if folder_cfg is not None and _in_scope(child_relpath, config):
                        if child_relpath not in seen:
                            seen.add(child_relpath)
                            yield child_relpath, folder_cfg
                        # An intent folder's own contents are items, not a
                        # tree to keep descending into for more folders.
                        continue
                    pruned.append(dirname)
                dirnames[:] = pruned

    def _index_one(
        self, folder_cfg: IntentFolderConfig, folder_relpath: str, abspath: Path,
        item_relpath: str, item_name: str, now: float,
    ) -> None:
        try:
            st = abspath.stat()
            device, inode = st.st_dev, st.st_ino
            is_directory = abspath.is_dir()
        except OSError:
            return
        existing = self.store.get_item_by_path(item_relpath)
        if existing is None:
            by_inode = self.store.get_item_by_inode(device, inode)
            item_id = by_inode["item_id"] if by_inode else str(uuid.uuid4())
        else:
            item_id = existing["item_id"]

        # Metadata (after/defer_until/priority/...) is always read regardless
        # of folder_cfg.tags -- that flag only controls whether *tags*
        # specifically get indexed, not whether the sidecar file is honored.
        meta_path = metadata_path_for(abspath, is_directory)
        metadata = parse_item_metadata(meta_path)

        self.store.upsert_item({
            "item_id": item_id, "intent_folder": folder_cfg.name, "folder_path": folder_relpath,
            "path": item_relpath, "name": item_name, "is_directory": is_directory,
            "device": device, "inode": inode,
            "title": (metadata.title if metadata else None) or item_name,
            "description": metadata.description if metadata else None,
            "source": metadata.source if metadata else None,
            "source_project": metadata.source_project if metadata else None,
            "action": metadata.action if metadata else None,
            "priority": (metadata.priority if metadata else None) or folder_cfg.priority,
            "archive_state": (metadata.archive_state if metadata else None) or "active",
            "created_at": existing["created_at"] if existing else now,
            "last_seen_at": now,
            "metadata_json": _metadata_to_dict(metadata),
        })
        if folder_cfg.tags and metadata and metadata.tags:
            self.store.set_item_user_tags(item_id, metadata.tags)


def _metadata_to_dict(metadata) -> dict:
    if metadata is None:
        return {}
    return {
        "tags": metadata.tags, "title": metadata.title, "description": metadata.description,
        "created": metadata.created, "last_reviewed": metadata.last_reviewed, "source": metadata.source,
        "source_project": metadata.source_project, "action": metadata.action, "after": metadata.after,
        "defer_until": metadata.defer_until, "snooze": metadata.snooze, "after_inactive": metadata.after_inactive,
        "priority": metadata.priority, "requires_confirmation": metadata.requires_confirmation,
        "archive_state": metadata.archive_state, "related_projects": metadata.related_projects,
        "excluded_projects": metadata.excluded_projects, "used_by_projects": metadata.used_by_projects,
        "repeat": metadata.repeat, "extra": metadata.extra,
    }
