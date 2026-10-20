"""The Ideas tab's own read model: an idea is an intent-item whose containing
`[[Name]]` folder is named "Ideas" (case-insensitive) -- no separate storage,
no parallel identity system. This module is the one place that assembles a
GUI-friendly idea view out of the same tables every other v2 surface reads
(`intent_items`, `tags`/`item_tags`, `relationships`, `resurfacing_state`,
`idea_notion_links`), mirroring `project_model_v2.py`'s role for projects.
"""

from __future__ import annotations

import json
from dataclasses import replace
from pathlib import Path
from typing import Any

from .core_engine import utc_now
from .core_store import CoreStore
from .item_records import ItemMetadataError, ItemRecord
from .private_items import initialize_record, load_record, save_record, record_payload, prior_promoted_record

# A live, GUI-toggleable override for whether Ideas<->Notion sync actually
# runs, stored in the same generic `watcher_state` key/value table every
# other health/status flag already uses -- not a new mechanism. This is
# deliberately independent of `config.toml`'s `[workspace_watcher.ideas]
# .notion_sync` default: config.toml stays the safe on-disk default (so a
# fresh install/reset never syncs to Notion by surprise), while a person can
# flip the live effective value from Settings without editing a file or
# restarting. Absent an override, the config default applies.
IDEAS_NOTION_SYNC_STATE_KEY = "ideas.notion_sync_override"


def ideas_notion_sync_enabled(store: CoreStore, config_default: bool) -> bool:
    override = store.get_state(IDEAS_NOTION_SYNC_STATE_KEY)
    if override is not None and "enabled" in override:
        return bool(override["enabled"])
    return config_default


def set_ideas_notion_sync_enabled(store: CoreStore, enabled: bool, timestamp: str) -> None:
    store.set_state(IDEAS_NOTION_SYNC_STATE_KEY, {"enabled": enabled}, timestamp)


_RELATIONSHIP_FIELDS = {
    "related_to_project": "related_projects", "potentially_related_to_project": "potential_projects",
    "excluded_from_project": "excluded_projects",
}

EDITABLE_FIELDS = (
    "title", "type", "status", "one_liner", "description", "notes", "source", "priority",
    "tags", "domains", "tools", "mediums", "related_projects", "potential_projects", "excluded_projects", "related_ideas",
    "confidence", "effort", "impact", "defer_until", "keep_suggesting", "planning",
)


def ideas_folder_row(store: CoreStore) -> Any | None:
    return next((row for row in store.folders() if row["name"].casefold() == "ideas"), None)


def _project_names(store: CoreStore, relationship_type: str, item_id: str) -> list[str]:
    names = []
    for row in store.relationships_for(item_id):
        if row["type"] != relationship_type or not row["to_id"].startswith("project:"):
            continue
        project = store.project_by_id(row["to_id"].removeprefix("project:"))
        if project:
            names.append(project["name"])
    return sorted(names)


def _related_idea_titles(store: CoreStore, item_id: str) -> list[dict[str, str]]:
    related = []
    for row in store.relationships_for(item_id):
        if row["type"] != "related_to_item":
            continue
        other_id = row["to_id"] if row["from_id"] == item_id else row["from_id"]
        other = store.item_by_id(other_id)
        if other:
            related.append({"id": other["id"], "title": other["title"]})
    return sorted(related, key=lambda entry: entry["title"].casefold())


def idea_view(store: CoreStore, item_row: Any) -> dict[str, Any]:
    metadata = json.loads(item_row["metadata_json"] or "{}")
    state = store.resurfacing_state(item_row["id"])
    link = store.idea_notion_link(item_row["id"])
    conflict = store.notification_by_id(f"idea-conflict:{item_row['id']}")
    return {
        "id": item_row["id"], "title": item_row["title"], "path": item_row["path"],
        "planning": metadata.get("planning"),
        "type": metadata.get("type", "unclassified"), "status": item_row["status"],
        "one_liner": metadata.get("one_liner", ""), "tags": metadata.get("tags", []),
        "domains": metadata.get("domains", []), "tools": metadata.get("tools", []), "mediums": metadata.get("mediums", []),
        "related_projects": sorted(set(_project_names(store, "related_to_project", item_row["id"]) + list(metadata.get("related_projects") or []))),
        "potential_projects": _project_names(store, "potentially_related_to_project", item_row["id"]),
        "impact": metadata.get("impact"), "effort": metadata.get("effort"), "confidence": metadata.get("confidence"),
        "keep_suggesting": metadata.get("keep_suggesting", True), "defer_until": metadata.get("resurfacing", {}).get("defer_until") if isinstance(metadata.get("resurfacing"), dict) else None,
        "created_at": item_row["created_at"], "updated_at": item_row["updated_at"],
        "notion_linked": bool(link and link["notion_page_id"]),
        "notion_page_id": link["notion_page_id"] if link else None,
        "notion_sync_conflict": bool(conflict and conflict["state"] in {"pending", "delivered"}),
        "last_score": state["last_score"] if state else None,
        "last_surfaced_at": state["last_surfaced_at"] if state else None,
    }


def list_ideas(store: CoreStore) -> list[dict[str, Any]]:
    folder = ideas_folder_row(store)
    if folder is None:
        return []
    return [idea_view(store, row) for row in store.items(folder_id=folder["id"])]


def idea_detail(store: CoreStore, item_id: str) -> dict[str, Any] | None:
    item_row = store.item_by_id(item_id)
    if item_row is None:
        return None
    metadata = json.loads(item_row["metadata_json"] or "{}")
    link = store.idea_notion_link(item_id)
    view = idea_view(store, item_row)
    view.update({
        "description": metadata.get("description", ""), "notes": metadata.get("notes", ""), "source": metadata.get("source", ""),
        "priority": metadata.get("priority"),
        "excluded_projects": _project_names(store, "excluded_from_project", item_id),
        "related_ideas": _related_idea_titles(store, item_id),
        "canonical_tags": [dict(row) for row in store.tags_for_item(item_id)],
        "notion_page_id": link["notion_page_id"] if link else None,
        "notion_sync_error": link["sync_error"] if link else None,
    })
    return view


def resurfacing_view(store: CoreStore, *, limit: int = 20) -> list[dict[str, Any]]:
    folder = ideas_folder_row(store)
    if folder is None:
        return []
    rows = []
    for item_row in store.items(folder_id=folder["id"]):
        state = store.resurfacing_state(item_row["id"])
        if state is None or not state["last_surfaced_at"]:
            continue
        view = idea_view(store, item_row)
        view["reasons"] = json.loads(state["last_reason_json"] or "{}")
        rows.append(view)
    rows.sort(key=lambda entry: entry["last_score"] or 0, reverse=True)
    return rows[:limit]


def create_idea(store: CoreStore, ideas_folder_path: Path, title: str) -> dict[str, Any]:
    cleaned = title.strip()
    if not cleaned:
        raise ValueError("An idea needs a title.")
    directory = ideas_folder_path / cleaned
    if directory.exists():
        raise ValueError(f"An idea named {cleaned!r} already exists.")
    if cleaned in {".", ".."} or "/" in cleaned or "\\" in cleaned:
        raise ValueError("An idea title must be a single folder name.")
    directory.mkdir(parents=True, exist_ok=False)
    record = initialize_record(store, directory, title=cleaned, idea=True)
    folder = ideas_folder_row(store)
    now = utc_now()
    folder_id = folder["id"] if folder else None
    if folder_id:
        stat = directory.stat()
        store.upsert_item(item_id=record.id, folder_id=folder_id, path=str(directory.resolve()), title=record.title, item_type=record.type, status=record.status, metadata=record_payload(record), device=stat.st_dev, inode=stat.st_ino, timestamp=now)
    return {"id": record.id, "title": record.title, "path": str(directory)}


def update_idea(store: CoreStore, item_id: str, updates: dict[str, Any]) -> dict[str, Any]:
    item_row = store.item_by_id(item_id)
    if item_row is None:
        raise ValueError("idea not found")
    path = Path(item_row["path"])
    if path.is_symlink() or not path.exists():
        raise ValueError("idea folder is unavailable")
    try:
        record = load_record(store, path, prior=item_row)
    except (FileNotFoundError, ItemMetadataError) as error:
        raise ValueError(f"idea metadata is unreadable: {error}") from error
    updates = dict(updates)
    expected = updates.pop("expected_planning", ...)
    if "planning" in updates:
        validate_planning(updates["planning"])
        if expected is not ... and record.planning != expected and record.planning != updates["planning"]:
            raise ValueError("This idea's scores changed. Refresh before saving again.")
    unknown = set(updates) - set(EDITABLE_FIELDS)
    if unknown:
        raise ValueError(f"unknown or read-only field(s): {', '.join(sorted(unknown))}")
    changes: dict[str, Any] = {}
    for field, value in updates.items():
        if field in {"tags", "domains", "tools", "mediums", "related_projects", "potential_projects", "excluded_projects", "related_ideas"}:
            changes[field] = tuple(str(v) for v in (value or []))
        else:
            changes[field] = value
    updated = replace(record, **changes)
    if not isinstance(updated.title, str) or not updated.title.strip():
        raise ValueError("An idea needs a title.")
    # The scalar priority remains compatible with the existing resurfacer.
    if "planning" in changes:
        updated = replace(updated, priority="high" if changes["planning"]["priority"] >= 4 else "low" if changes["planning"]["priority"] <= 2 else "normal")
    if "planning" in changes:
        prior_private = store.conn.execute("SELECT payload_json FROM private_item_records WHERE id=?", (record.id,)).fetchone()
        if prior_private is None:
            save_record(store, path, record)
            prior_private = store.conn.execute("SELECT payload_json FROM private_item_records WHERE id=?", (record.id,)).fetchone()
        previous = json.loads(prior_private["payload_json"])
        previous.setdefault("planning", None)
        if previous != record_payload(record):
            raise ValueError("This idea changed. Refresh before saving again.")
        payload = record_payload(updated)
        encoded = json.dumps(payload, sort_keys=True)
        changed = store.conn.execute("UPDATE private_item_records SET payload_json=? WHERE id=? AND payload_json=?", (encoded, record.id, prior_private["payload_json"]))
        if changed.rowcount != 1:
            store.conn.rollback()
            raise ValueError("This idea changed. Refresh before saving again.")
        store.conn.execute("UPDATE intent_items SET metadata_json=?,title=?,type=?,status=?,updated_at=? WHERE id=?", (encoded, updated.title, updated.type, updated.status, utc_now(), record.id))
        store.conn.commit()
    else:
        save_record(store, path, updated)
    return idea_detail(store, item_id) or {}


def validate_planning(value: Any) -> None:
    if not isinstance(value, dict) or set(value) - {"priority", "ratings", "potential", "needsSetup", "sourceProjectID", "project"}:
        raise ValueError("Invalid idea planning fields")
    project = value.get("project")
    if project is not None:
        if not isinstance(project, dict) or set(project) - {"metadata", "oneLiner", "summary", "automaticNotionSync"}:
            raise ValueError("Invalid potential project details")
        if type(project.get("automaticNotionSync")) is not bool or not isinstance(project.get("metadata"), dict):
            raise ValueError("Invalid potential project details")
        for key, limit in (("oneLiner", 2000), ("summary", 12000)):
            if not isinstance(project.get(key), str) or len(project[key]) > limit:
                raise ValueError("Potential project text is too long")
        for key in ("domain", "projectType", "phase", "status"):
            text = project["metadata"].get(key)
            if text is not None and (not isinstance(text, str) or len(text.encode()) > 200 or "\n" in text):
                raise ValueError("Invalid potential project property")
        if len(json.dumps(project).encode()) > 128000:
            raise ValueError("Potential project details are too large")
    priority, ratings = value.get("priority"), value.get("ratings")
    if type(priority) is not int or priority not in range(1, 6):
        raise ValueError("Idea priority must be 1 to 5")
    if value.get("potential") not in {None, "project", "feature", "milestone"} or type(value.get("needsSetup")) is not bool:
        raise ValueError("Choose a potential Project, Feature or Milestone")
    if not isinstance(ratings, dict) or len(ratings) > 64 or any(not isinstance(k, str) or len(k) > 64 or type(v) is not int or v not in range(1, 6) for k, v in ratings.items()):
        raise ValueError("Idea ratings must be 1 to 5")
    if value.get("sourceProjectID") is not None and (not isinstance(value["sourceProjectID"], str) or len(value["sourceProjectID"]) > 128):
        raise ValueError("Invalid source project identity")


def register_idea(store: CoreStore, ideas_root: Path, path: Path) -> dict[str, Any]:
    """Register one explicit visible child without reading its contents or sidecars."""
    from .transparent_folders import is_visible_child
    import uuid
    root = ideas_root.resolve()
    if ideas_root.is_symlink() or path.is_symlink() or not is_visible_child(path, ideas_root) or path.name.startswith(".") or not path.exists():
        raise ValueError("Choose an ordinary immediate child of Ideas")
    if path.name in {"_audit", ".project-core", "watcher.item.toml", "Project.betterproject"}:
        raise ValueError("That metadata location cannot be an idea")
    folder = ideas_folder_row(store)
    if folder is None or Path(folder["path"]).resolve() != root:
        raise ValueError("The Ideas area must be indexed by the service first")
    info, now = path.stat(), utc_now()
    prior = store.item_by_path(str(path.resolve())) or store.item_by_inode(info.st_dev, info.st_ino) or prior_promoted_record(store, path, info)
    store.conn.execute("BEGIN IMMEDIATE")
    private = store.conn.execute("SELECT payload_json FROM private_item_records WHERE id=? OR path=?", (prior["id"] if prior else "", str(path.resolve()))).fetchone()
    if private:
        payload = json.loads(private["payload_json"])
        from dataclasses import fields
        record = ItemRecord(**{f.name: payload[f.name] for f in fields(ItemRecord) if f.name in payload})
    else:
        record = ItemRecord(id=prior["id"] if prior else str(uuid.uuid4()), title=path.stem if path.is_file() else path.name, type="unclassified")
    if record.planning is None:
        record = replace(record, planning={"priority": 5 if record.priority == "high" else 1 if record.priority == "low" else 3, "ratings": {}, "needsSetup": True, **({"potential": record.type.lower()} if record.type.lower() in {"project", "feature", "milestone"} else {})})
    payload = record_payload(record)
    store.conn.execute("INSERT INTO private_item_records(id,path,payload_json) VALUES (?,?,?) ON CONFLICT(id) DO UPDATE SET path=excluded.path,payload_json=excluded.payload_json", (record.id, str(path.resolve()), json.dumps(payload, sort_keys=True)))
    store.upsert_item(item_id=record.id, folder_id=folder["id"], path=str(path.resolve()), title=record.title, item_type=record.type, status=record.status, metadata=record_payload(record), device=info.st_dev, inode=info.st_ino, timestamp=now)
    return idea_view(store, store.item_by_id(record.id))


def relocate_idea(store: CoreStore, workspace: Path, item_id: str, source: str, destination: str) -> dict[str, Any]:
    """Acknowledge a completed, inode-preserving Mac promotion. Never move files here."""
    row = store.item_by_id(item_id)
    if row is None:
        raise ValueError("Idea not found")
    old, new = Path(source), Path(destination)
    root = workspace.resolve()
    from .transparent_folders import is_visible_child
    if not is_visible_child(old, root / "Ideas") or new.parent.resolve() not in {root / "Projects", root / "Features", root / "Milestones"} or new.is_symlink() or not new.exists():
        raise ValueError("Idea promotion must stay in the declared workspace areas")
    if row["path"] not in {str(old), str(new)}:
        raise ValueError("Idea changed location")
    info = new.stat()
    if (row["device"], row["inode"]) != (info.st_dev, info.st_ino):
        raise ValueError("Promoted idea identity changed")
    private = store.conn.execute("SELECT payload_json FROM private_item_records WHERE id=?", (item_id,)).fetchone()
    if private:
        payload = json.loads(private["payload_json"])
        provenance = dict(payload.get("provenance") or {})
        provenance["bw_promotion_birthtime"] = getattr(info, "st_birthtime", None)
        payload["provenance"] = provenance
        store.conn.execute("UPDATE private_item_records SET path=?,payload_json=? WHERE id=?", (str(new), json.dumps(payload, sort_keys=True), item_id))
    store.conn.execute("UPDATE intent_items SET path=?,exists_flag=0,updated_at=? WHERE id=?", (str(new), utc_now(), item_id))
    store.conn.commit()
    return {"id": item_id, "path": str(new)}
