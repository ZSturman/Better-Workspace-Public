"""V2 orchestration: discover -> normalize -> record -> evaluate -> act."""

from __future__ import annotations

import json
import uuid
from dataclasses import replace
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from .core_events import EventTypes, WorkspaceEvent
from .core_store import CoreStore
from .transparent_folders import visible_children
from .intents import IntentFolderDetector
from .item_records import ItemMetadataError, ItemRecord
from .private_items import load_record, record_payload, prior_promoted_record, save_indexed_record


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


class IntentIndexer:
    """Reconciles folders/items from disk into the v2 read model.

    Metadata lives privately in SQLite. Moves retain identity through device/inode;
    legacy UUIDs are imported without rewriting the original sidecar.
    """

    def __init__(self, detector: IntentFolderDetector, store: CoreStore) -> None:
        self.detector, self.store = detector, store

    def rebuild(self, *, initialize_missing_metadata: bool = False) -> dict[str, int]:
        """Bounded, idempotent filesystem reconciliation.

        We inventory before changing SQLite.  That lets a portable UUID prove
        a move, while a UUID simultaneously present at two paths is a copy
        collision rather than an accidental destructive upsert.
        """
        now, seen_paths, seen_folders = utc_now(), set(), set()
        counters = {"folders": 0, "items": 0, "invalid_metadata": 0, "collisions": 0, "events": 0}
        candidates: list[dict[str, Any]] = []
        for folder in self.detector.discover():
            seen_folders.add(str(folder.path))
            folder_row = self.store.folder_by_path(str(folder.path))
            folder_id = folder_row["id"] if folder_row else str(uuid.uuid4())
            self.store.upsert_intent_folder(folder_id=folder_id, path=str(folder.path), root_path=str(folder.root), name=folder.name, config=folder.config, timestamp=now)
            counters["folders"] += 1
            if not folder_row:
                self._event(EventTypes.INTENT_DISCOVERED, folder_id, {"path": str(folder.path), "name": folder.name}); counters["events"] += 1
            for child in visible_children(folder.path, self.detector.settings.excluded_names):
                if child.is_symlink() or child.name.startswith("."):
                    continue
                path = str(child.resolve())
                if not child.is_dir():
                    prior_file = self.store.item_by_path(path)
                    if folder.name.casefold() == "ideas" and prior_file is not None:
                        seen_paths.add(path)
                    continue
                seen_paths.add(path)
                try:
                    stat = child.stat()
                except OSError:
                    continue
                prior = self.store.item_by_path(path) or self.store.item_by_inode(stat.st_dev, stat.st_ino)
                if prior is None and folder.name.casefold() == "ideas":
                    prior = prior_promoted_record(self.store, child, stat)
                try:
                    record = load_record(self.store, child, prior=prior)
                except FileNotFoundError:
                    record = ItemRecord(id=prior["id"] if prior else str(uuid.uuid4()), title=child.name,
                                        planning={"priority": 3, "ratings": {}, "needsSetup": True} if folder.name.casefold() == "ideas" else None)
                except ItemMetadataError as error:
                    counters["invalid_metadata"] += 1
                    self._event(EventTypes.INTENT_ITEM_METADATA_CHANGED, None, {"path": str(child), "error": str(error), "valid": False}); counters["events"] += 1
                    continue
                private = self.store.conn.execute("SELECT path FROM private_item_records WHERE id=?", (record.id,)).fetchone()
                if private and private["path"] != path and Path(private["path"]).exists():
                    # A legacy copy can refer to an unindexed, already imported
                    # record. Never steal its private metadata identity.
                    old_id = record.id
                    record = replace(record, id=str(uuid.uuid4()))
                    counters["collisions"] += 1
                    self._event(EventTypes.INTENT_ITEM_IDENTITY_COLLISION, record.id,
                                {"path": path, "replaced_id": old_id}); counters["events"] += 1
                candidates.append({"folder_id": folder_id, "path": path, "child": child, "stat": stat, "record": record})
        # Resolve metadata UUID collisions deterministically. Prefer the path
        # already known to the store; otherwise retain the lexical first path.
        by_id: dict[str, list[dict[str, Any]]] = {}
        for candidate in candidates:
            if candidate["record"]:
                by_id.setdefault(candidate["record"].id, []).append(candidate)
        for item_id, duplicates in by_id.items():
            if len(duplicates) < 2:
                continue
            existing = self.store.item_by_id(item_id)
            duplicates.sort(key=lambda item: (item["path"] != (existing["path"] if existing else ""), item["path"]))
            for duplicate in duplicates[1:]:
                new_record = replace(duplicate["record"], id=str(uuid.uuid4()))
                duplicate["record"] = new_record
                counters["collisions"] += 1
                self._event(EventTypes.INTENT_ITEM_IDENTITY_COLLISION, new_record.id, {"path": duplicate["path"], "replaced_id": item_id}); counters["events"] += 1
        for candidate in candidates:
            folder_id, path, child, stat, record = candidate["folder_id"], candidate["path"], candidate["child"], candidate["stat"], candidate["record"]
            prior_at_path = self.store.item_by_path(path)
            prior_by_inode = self.store.item_by_inode(stat.st_dev, stat.st_ino)
            prior_by_id = self.store.item_by_id(record.id) if record else None
            # A pre-cutover scan could have assigned an ephemeral local ID
            # before this directory received watcher.item.toml. The metadata
            # UUID wins and is promoted in place instead of violating path's
            # uniqueness constraint or creating a second logical item.
            if record and prior_at_path and prior_at_path["id"] != record.id and prior_by_id is None:
                self.store.adopt_item_identity(prior_at_path["id"], record.id)
                prior_at_path = self.store.item_by_path(path)
            prior = prior_at_path or prior_by_inode or prior_by_id
            item_id = record.id if record else (prior or {"id": str(uuid.uuid4())})["id"]
            record = save_indexed_record(self.store, child, record, folder_id, stat, now)
            if record is None:
                seen_paths.discard(path)
                continue
            item_id = record.id
            payload = record_payload(record)
            changed_metadata = prior is not None and prior["metadata_json"] != json.dumps(payload, sort_keys=True)
            counters["items"] += 1
            if record and (prior is None or changed_metadata):
                # Only when the record is new or actually changed -- reusing
                # the same signal the event-type decision below uses, so an
                # unchanged item's reconcile pass stays a true no-op (no
                # "restart noise", matching this loop's existing invariant).
                self.store.reconcile_filesystem_tags(item_id, record.tags)
                self.store.reconcile_item_relationships(
                    item_id, related_projects=record.related_projects, potential_projects=record.potential_projects,
                    excluded_projects=record.excluded_projects, related_ideas=record.related_ideas, timestamp=now,
                )
            if prior is None:
                event_type = EventTypes.INTENT_ITEM_CREATED
            elif prior["intent_folder_id"] != folder_id:
                event_type = EventTypes.INTENT_ITEM_INTENT_CHANGED
            elif prior["path"] != path:
                event_type = EventTypes.INTENT_ITEM_MOVED
            elif changed_metadata:
                event_type = EventTypes.INTENT_ITEM_METADATA_CHANGED
            else:
                continue  # reconciliation must not create restart noise
            self._event(event_type, item_id, {"path": path, "intent_folder_id": folder_id, "previous_path": prior["path"] if prior else None}); counters["events"] += 1
        for absent in self.store.absent_items(seen_paths):
            self._event(EventTypes.INTENT_ITEM_DELETED, absent["id"], {"path": absent["path"]}); counters["events"] += 1
        self.store.mark_absent_items(seen_paths, now)
        self.store.mark_absent_folders(seen_folders, now)
        return counters

    def _event(self, event_type: str, entity_id: str | None, payload: dict[str, Any]) -> None:
        self.store.record_event(WorkspaceEvent(type=event_type, entity_id=entity_id, payload=payload))
