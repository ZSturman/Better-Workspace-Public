"""Service-owned item metadata. Legacy sidecars are read only for import.

Files remain the content source of truth; this stores decisions about them.
"""
from __future__ import annotations

import json
import uuid
from dataclasses import asdict, fields
from pathlib import Path

from .item_records import ItemMetadataError, ItemRecord, item_metadata_path, parse_item_record


def record_payload(record: ItemRecord) -> dict:
    payload = asdict(record)
    payload["resurfacing"] = {"keep_suggesting": record.keep_suggesting, "defer_until": record.defer_until}
    return json.loads(json.dumps(payload, default=str))


def load_record(store, directory: Path, *, prior=None) -> ItemRecord:
    path = str(directory.resolve())
    row = store.conn.execute("SELECT payload_json FROM private_item_records WHERE path=?", (path,)).fetchone()
    if row is None and prior is not None:
        row = store.conn.execute("SELECT payload_json FROM private_item_records WHERE id=?", (prior["id"],)).fetchone()
    if row is None:
        if item_metadata_path(directory).is_symlink():
            raise ItemMetadataError("legacy metadata is a symlink")
        return parse_item_record(item_metadata_path(directory))
    payload = json.loads(row["payload_json"])
    for key in ("tags", "domains", "tools", "mediums", "related_projects", "potential_projects", "excluded_projects", "related_ideas"):
        if key in payload:
            payload[key] = tuple(payload[key])
    known = {field.name for field in fields(ItemRecord)}
    return ItemRecord(**{key: value for key, value in payload.items() if key in known})


def save_record(store, directory: Path, record: ItemRecord) -> ItemRecord:
    path = str(directory.resolve())
    payload = record_payload(record)
    store.conn.execute("""INSERT INTO private_item_records(id,path,payload_json) VALUES (?,?,?)
        ON CONFLICT(id) DO UPDATE SET path=excluded.path,payload_json=excluded.payload_json""",
        (record.id, path, json.dumps(payload, sort_keys=True)))
    store.conn.commit()
    row = store.item_by_id(record.id)
    if row is not None and row["exists_flag"] and row["path"] == path:
        from .core_engine import utc_now
        now = utc_now()
        store.upsert_item(item_id=record.id, folder_id=row["intent_folder_id"], path=path,
                          title=record.title, item_type=record.type, status=record.status,
                          metadata=payload, device=row["device"], inode=row["inode"], timestamp=now)
        store.reconcile_filesystem_tags(record.id, record.tags)
        store.reconcile_item_relationships(record.id, related_projects=record.related_projects,
            potential_projects=record.potential_projects, excluded_projects=record.excluded_projects,
            related_ideas=record.related_ideas, timestamp=now)
    return record


def initialize_record(store, directory: Path, *, title=None, idea=False) -> ItemRecord:
    try:
        record = load_record(store, directory)
    except FileNotFoundError:
        record = ItemRecord(id=str(uuid.uuid4()), title=title or directory.name,
                            type="unclassified" if idea else "item")
    return save_record(store, directory, record)


def prior_promoted_record(store, directory: Path, info):
    birth = getattr(info, "st_birthtime", None)
    if birth is None:
        return None
    row = store.conn.execute("SELECT i.*,p.payload_json FROM intent_items i JOIN private_item_records p ON p.id=i.id WHERE i.exists_flag=0 AND i.device=? AND i.inode=?", (info.st_dev, info.st_ino)).fetchone()
    if row is None:
        return None
    old = Path(row["path"])
    root = directory.parent.parent.resolve()
    provenance = json.loads(row["payload_json"]).get("provenance") or {}
    if not isinstance(provenance, dict) or provenance.get("bw_promotion_birthtime") != birth:
        return None
    if old.parent.parent.resolve() != root or old.parent.name not in {"Projects", "Features", "Milestones"} or old.exists():
        return None
    return row


def save_indexed_record(store, directory: Path, candidate: ItemRecord, folder_id: str, observed, timestamp: str):
    """Publish one shallow observation without replacing newer private decisions."""
    store.conn.execute("BEGIN IMMEDIATE")
    try:
        if directory.is_symlink() or not directory.is_dir():
            store.conn.rollback()
            return None
        fresh_stat = directory.stat()
        if (fresh_stat.st_dev, fresh_stat.st_ino) != (observed.st_dev, observed.st_ino):
            store.conn.rollback()
            return None
        current = store.conn.execute("SELECT id FROM private_item_records WHERE id=?", (candidate.id,)).fetchone()
        record = load_record(store, directory, prior={"id": candidate.id}) if current else candidate
        if record.id != candidate.id:
            from dataclasses import replace
            record = replace(record, id=candidate.id)
        path = str(directory.resolve())
        payload = record_payload(record)
        store.conn.execute("INSERT INTO private_item_records(id,path,payload_json) VALUES (?,?,?) ON CONFLICT(id) DO UPDATE SET path=excluded.path,payload_json=excluded.payload_json", (record.id, path, json.dumps(payload, sort_keys=True)))
        # upsert_item's commit publishes both private decisions and the read model.
        store.upsert_item(item_id=record.id, folder_id=folder_id, path=path, title=record.title, item_type=record.type, status=record.status, metadata=payload, device=fresh_stat.st_dev, inode=fresh_stat.st_ino, timestamp=timestamp)
        return record
    except Exception:
        store.conn.rollback()
        raise
