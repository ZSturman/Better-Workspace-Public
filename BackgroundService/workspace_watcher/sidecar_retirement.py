"""Explicit retirement of exact, service-owned legacy item sidecars.

Original bytes are committed and verified in SQLite before removing each file.
Malformed files and symlinks are kept for review. No other metadata is touched.
"""
from __future__ import annotations

import hashlib
import os
import uuid
from dataclasses import replace
from pathlib import Path

from .core_engine import IntentIndexer, utc_now
from .item_records import ItemMetadataError, item_metadata_path, parse_item_record
from .private_items import load_record, save_record


def retire_sidecars(store, detector, *, apply=False, include_unindexed=False) -> dict:
    candidates = []
    kept = []
    paths = set()
    for folder in detector.discover():
        for child in folder.path.iterdir():
            if child.is_symlink() or child.name.startswith(".") or not child.is_dir():
                continue
            path = item_metadata_path(child)
            paths.add(path)
    if include_unindexed:
        # An explicit one-time inventory, never a background traversal. Inspect
        # only this service's exact filename; never enter another tool's stores.
        excluded = set(detector.settings.excluded_names) | {".project-core", "_audit", "Migration"}
        for root in detector.settings.search_roots:
            for current, dirs, files in os.walk(root, followlinks=False):
                parent = Path(current)
                dirs[:] = [name for name in dirs if name not in excluded
                           and not (parent / name).is_symlink()
                           and not any((parent / name).resolve().is_relative_to(boundary)
                                       for boundary in detector.settings.excluded_roots)]
                if "watcher.item.toml" in files:
                    paths.add(item_metadata_path(parent))
    for path in sorted(paths):
        if not path.exists() and not path.is_symlink():
            continue
        try:
            if path.is_symlink() or not path.is_file():
                raise ValueError("not a regular file")
            original = path.read_bytes()
            record = parse_item_record(path)
            candidates.append((path, original, record))
        except (OSError, ValueError) as error:
            kept.append({"path": str(path), "reason": str(error)})
    result = {"apply": apply, "eligible": len(candidates), "removed": 0, "kept": kept,
              "paths": [str(path) for path, _, _ in candidates]}
    if not apply:
        return result
    # Import and resolve copied UUIDs without changing any original sidecars.
    IntentIndexer(detector, store).rebuild(initialize_missing_metadata=True)
    for path, original, legacy in candidates:
        try:
            if path.is_symlink() or path.read_bytes() != original:
                raise ValueError("file changed after planning")
            row = store.item_by_path(str(path.parent.resolve()))
            if row is None:
                # Former intent items moved into Projects still carry valuable
                # metadata. Store it without inventing an active idea/index row.
                existing = store.conn.execute("SELECT id FROM private_item_records WHERE path=?", (str(path.parent.resolve()),)).fetchone()
                if existing is None:
                    collision = store.conn.execute("SELECT path FROM private_item_records WHERE id=?", (legacy.id,)).fetchone()
                    if collision is not None and Path(collision["path"]).exists():
                        legacy = replace(legacy, id=str(uuid.uuid4()))
                    save_record(store, path.parent, legacy)
            record = load_record(store, path.parent, prior=row)
            if row is not None and record.id != row["id"]:
                raise ValueError("private identity does not match the index")
            private = store.conn.execute("SELECT id FROM private_item_records WHERE id=?", (record.id,)).fetchone()
            if private is None:
                raise ValueError("metadata is not stored privately")
            digest = hashlib.sha256(original).hexdigest()
            archived = store.conn.execute("SELECT original_bytes FROM retired_item_sidecars WHERE path=?", (str(path),)).fetchone()
            if archived is not None and archived["original_bytes"] != original:
                raise ValueError("a different original is already archived at this path")
            store.conn.execute("INSERT OR IGNORE INTO retired_item_sidecars VALUES (?,?,?,?,?)",
                               (str(path), record.id, original, digest, utc_now()))
            store.conn.commit()
            archived = store.conn.execute("SELECT original_bytes FROM retired_item_sidecars WHERE path=?", (str(path),)).fetchone()
            if archived["original_bytes"] != original:
                raise ValueError("archive verification failed")
            if path.is_symlink() or path.read_bytes() != original:
                raise ValueError("file changed before removal")
            path.unlink()
            result["removed"] += 1
        except (OSError, ValueError) as error:
            kept.append({"path": str(path), "reason": str(error)})
    return result
