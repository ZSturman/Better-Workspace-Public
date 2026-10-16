"""Optional bidirectional sync between local Ideas and the existing Notion
Ideas database.

Private SQLite item records are the primary working state: the
Ideas tab, resurfacing, and every other local feature keep working fully
with Notion disabled. This module is strictly additive on top of that --
mirroring ``work_logs_v2.py``'s ``NotionWorkLogSync`` pattern (the one other
concrete Notion push/pull example in this codebase) rather than growing a
second sync design:

* A local idea's stable link to its Notion page lives in SQLite only
  (``idea_notion_links``, see core_store.py) -- never in the portable TOML
  sidecar, matching item_records.py's own "runtime facts belong in SQLite"
  contract.
* Duplicate prevention mirrors the Work Log sync's ``event_hash`` trick: each
  Notion page carries the local item id in a small ``Workspace Watcher ID``
  rich_text property (added to the live database on first use, if missing --
  the same kind of additive schema change ``update_data_source`` already
  performs elsewhere), so a crash between ``create_page`` succeeding and the
  local link committing can self-heal by querying for that id instead of
  creating a second page.
* Conflict safety: a hash of the fields we last pushed is stored alongside
  the link. If local has changed since that hash *and* Notion's own
  ``last_edited_time`` has also moved past what we last recorded, neither
  side is written -- a notification is raised instead so a person resolves
  it, rather than either side silently clobbering the other.
* A Notion page with no recognized ``Workspace Watcher ID`` is a genuinely
  new, Notion-authored idea: pulling it creates a new local idea folder
  under the discovered ``[[Ideas]]`` folder, which is the one direction this
  module treats as safe to create unattended (nothing local is overwritten).
"""

from __future__ import annotations

import hashlib
import json
import re
from pathlib import Path
from typing import Any

from .core_config import NotionSettings
from .core_store import CoreStore
from .item_records import ItemRecord
from .private_items import initialize_record, load_record, save_record
from .notion_client_v2 import ExistingProjectsAdapter, NotionCacheError

LOCAL_ID_PROPERTY = "Workspace Watcher ID"

# Local field -> candidate Notion property names/kinds. `SchemaMap.find`
# normalizes case/spacing/underscores, so "one_liner" and "one liner" match
# the same property without listing every spelling here.
_TEXT_FIELDS = {
    "one_liner": (("one liner",), ("rich_text",)),
    "description": (("capture notes",), ("rich_text",)),
    "notes": (("bullet points",), ("rich_text",)),
}
_SELECT_FIELDS = {"type": (("type",), ("select",)), "status": (("status",), ("select", "status")), "impact": (("impact",), ("select",))}
_MULTI_SELECT_FIELDS = {"tags": (("tags",), ("multi_select",)), "domains": (("potential domain",), ("multi_select",)), "tools": (("tools / technologies", "tools/technologies"), ("multi_select",))}
_RELATION_FIELDS = {"related_projects": (("projects",), ("relation",)), "potential_projects": (("potential projects",), ("relation",)), "excluded_projects": (("exclude projects",), ("relation",))}


def _looks_like_page_gone(error: Exception) -> bool:
    return "HTTP 404" in str(error) or "HTTP 400" in str(error) and "archived" in str(error).casefold()


# `type`/`status` are the two fields where the local convention
# (lowercase_with_underscores, e.g. "to_implement") and the live Notion
# select options (Title Case With Spaces, e.g. "To Implement") are the same
# vocabulary in a different case -- every local status value already has an
# exact-match Notion option (Raw, Exploring, Plan, To Implement, To Write,
# Archived), and several type values do too (Feature, Story, Experiment).
# Converting case round-trips onto the *existing* option instead of Notion
# silently creating a near-duplicate ("to_implement" alongside "To
# Implement") the first time either side pushes a value the other iaven't
# seen in that exact casing.
def _to_notion_select_name(value: str) -> str:
    return " ".join(word.capitalize() for word in value.replace("-", "_").split("_") if word)


def _from_notion_select_name(value: str) -> str:
    return value.strip().casefold().replace(" ", "_").replace("-", "_")


def _decode_multi_select(raw: dict[str, Any] | None) -> list[str]:
    # `notion_api.decode_property` doesn't handle multi_select (only
    # title/rich_text/select/status/checkbox/relation/date/number) -- decoded
    # directly here rather than changing the shared decoder for one kind.
    if not isinstance(raw, dict) or raw.get("type") != "multi_select":
        return []
    return [str(item.get("name") or "") for item in raw.get("multi_select") or [] if isinstance(item, dict) and item.get("name")]


class IdeasNotionSync:
    def __init__(self, store: CoreStore, workspace_root: Path, settings: NotionSettings, *, adapter: Any | None = None) -> None:
        self.store = store
        self.workspace_root = workspace_root
        self.settings = settings
        self.adapter = adapter or ExistingProjectsAdapter(workspace_root, settings)

    # -- schema -----------------------------------------------------------

    def _schema(self) -> tuple[Any, str, Any]:
        client = self.adapter._client()
        source_id = client.data_source_id(self.settings.ideas_database_id)
        source = client.data_source(source_id)
        try:
            from .notion_api import SchemaMap
        except Exception as exc:  # noqa: BLE001
            raise NotionCacheError(f"Existing schema helpers unavailable: {exc}") from exc
        return client, source_id, SchemaMap(source)

    def _ensure_local_id_property(self, client: Any, source_id: str, schema: Any) -> Any:
        ref = schema.find((LOCAL_ID_PROPERTY,), ("rich_text",))
        if ref is not None:
            return ref
        client.update_data_source(source_id, {LOCAL_ID_PROPERTY: {"rich_text": {}}})
        from .notion_api import SchemaMap
        return SchemaMap(client.data_source(source_id)).find((LOCAL_ID_PROPERTY,), ("rich_text",))

    # -- local -> Notion field mapping --------------------------------------

    def _properties(self, record: ItemRecord, schema: Any, local_id_ref: Any) -> dict[str, Any]:
        from .notion_api import property_value
        properties: dict[str, Any] = {}
        title = schema.title()
        if title:
            properties[title.name] = property_value(title.kind, record.title)
        if local_id_ref:
            properties[local_id_ref.name] = property_value("rich_text", record.id)
        for field, (aliases, kinds) in _TEXT_FIELDS.items():
            value = getattr(record, field)
            ref = schema.find(aliases, kinds)
            if ref and value:
                properties[ref.name] = property_value(ref.kind, value)
        for field, (aliases, kinds) in _SELECT_FIELDS.items():
            value = getattr(record, field)
            if field == "type" and value == "unclassified":
                continue  # the local "not yet decided" default -- nothing meaningful to push
            if field in {"type", "status"} and value:
                value = _to_notion_select_name(value)
            ref = schema.find(aliases, kinds)
            if ref and value:
                properties[ref.name] = property_value(ref.kind, value)
        for field, (aliases, kinds) in _MULTI_SELECT_FIELDS.items():
            values = getattr(record, field)
            ref = schema.find(aliases, kinds)
            if ref and values:
                properties[ref.name] = property_value("multi_select", list(values))
        if record.confidence is not None and (ref := schema.find(("confidence",), ("number",))):
            properties[ref.name] = property_value("number", record.confidence)
        if record.effort is not None and (ref := schema.find(("effort",), ("select",))):
            properties[ref.name] = property_value("select", str(record.effort))
        if (ref := schema.find(("keep suggesting",), ("checkbox",))):
            properties[ref.name] = property_value("checkbox", record.keep_suggesting)
        if record.defer_until and (ref := schema.find(("defer until",), ("date",))):
            properties[ref.name] = property_value("date", record.defer_until)
        by_name = {row["name"].casefold(): row["id"] for row in self.store.projects(status=None)}
        for field, (aliases, kinds) in _RELATION_FIELDS.items():
            names = getattr(record, field)
            ref = schema.find(aliases, kinds)
            if not ref:
                continue
            notion_ids = []
            for name in names:
                local_project = by_name.get(str(name).casefold())
                mapped = self.store.notion_project_for(local_project) if local_project else None
                if mapped:
                    notion_ids.append(str(mapped["notion_project_id"]))
            if notion_ids:
                properties[ref.name] = property_value("relation", notion_ids)
        return properties

    def _decode_into_record(self, base: ItemRecord, page: dict[str, Any], schema: Any) -> ItemRecord:
        """Apply a Notion page's field values onto ``base``, decoding
        text/select/multi_select/relation properties -- shared by both the
        create-from-Notion path (``pull_new_ideas``) and the update-from-
        Notion path (``sync_item``, when only the remote side changed)."""
        from .notion_api import decode_property, page_property
        enriched = base
        for field, (aliases, kinds) in _TEXT_FIELDS.items():
            ref = schema.find(aliases, kinds)
            value = decode_property(page_property(page, ref.name)) if ref else None
            if value:
                enriched = _with_field(enriched, field, value)
        for field, (aliases, kinds) in _SELECT_FIELDS.items():
            ref = schema.find(aliases, kinds)
            value = decode_property(page_property(page, ref.name)) if ref else None
            if not value:
                continue
            if field in {"type", "status"}:
                value = _from_notion_select_name(str(value))
            enriched = _with_field(enriched, field, value)
        for field, (aliases, kinds) in _MULTI_SELECT_FIELDS.items():
            ref = schema.find(aliases, kinds)
            value = _decode_multi_select(page_property(page, ref.name)) if ref else None
            if value:
                enriched = _with_field(enriched, field, tuple(value))
        by_notion_id: dict[str, str | None] = {}
        for field, (aliases, kinds) in _RELATION_FIELDS.items():
            ref = schema.find(aliases, kinds)
            notion_ids = decode_property(page_property(page, ref.name)) if ref else None
            if not notion_ids:
                continue
            names = []
            for notion_id in notion_ids:
                if notion_id not in by_notion_id:
                    row = self.store.project_for_notion_id(notion_id)
                    by_notion_id[notion_id] = row["name"] if row else None
                if by_notion_id[notion_id]:
                    names.append(by_notion_id[notion_id])
            if names:
                enriched = _with_field(enriched, field, tuple(names))
        return enriched

    def _pushed_hash(self, properties: dict[str, Any]) -> str:
        return hashlib.sha256(json.dumps(properties, sort_keys=True, default=str).encode()).hexdigest()

    def _find_existing_page_by_local_id(self, client: Any, source_id: str, local_id_ref: Any, item_id: str) -> str | None:
        if local_id_ref is None:
            return None
        try:
            results = client.query(source_id, filter_payload={"property": local_id_ref.name, "rich_text": {"equals": item_id}}, limit=1)
        except Exception:  # noqa: BLE001
            return None
        return str(results[0].get("id") or "") if results else None

    # -- one idea, one direction each way ----------------------------------

    def sync_item(self, item_row: Any, path: Path, now: str) -> dict[str, Any]:
        """Push this idea if it changed locally since the last successful
        sync; detect (never silently resolve) a two-sided conflict."""

        record = load_record(self.store, path)
        client, source_id, schema = self._schema()
        local_id_ref = self._ensure_local_id_property(client, source_id, schema)
        properties = self._properties(record, schema, local_id_ref)
        if len(properties) <= 1:  # only ever a lone title property
            return {"item_id": record.id, "action": "skipped", "reason": "no writable compatible Notion fields"}
        current_hash = self._pushed_hash(properties)

        link = self.store.idea_notion_link(record.id)
        page_id = str(link["notion_page_id"]) if link and link["notion_page_id"] else None
        if not page_id:
            page_id = self._find_existing_page_by_local_id(client, source_id, local_id_ref, record.id)

        remote_last_edited: str | None = None
        if page_id:
            try:
                page = client.page(page_id)
                remote_last_edited = page.get("last_edited_time")
            except Exception as error:  # noqa: BLE001
                if _looks_like_page_gone(error):
                    page_id = None
                else:
                    self.store.upsert_idea_notion_link(record.id, notion_page_id=page_id, synced_hash=link["synced_hash"] if link else None, notion_last_edited_time=link["notion_last_edited_time"] if link else None, sync_error=str(error), timestamp=now)
                    return {"item_id": record.id, "action": "error", "error": str(error)}

        local_changed = link is None or link["synced_hash"] != current_hash
        remote_changed = bool(link and link["notion_last_edited_time"] and remote_last_edited and remote_last_edited != link["notion_last_edited_time"])
        if page_id and local_changed and remote_changed:
            self._raise_conflict(record, page_id, now)
            return {"item_id": record.id, "action": "conflict"}
        if page_id and not local_changed and remote_changed:
            # Only Notion changed since the last sync -- safe to pull down:
            # nothing local is being overwritten that a person actually
            # touched (that's exactly the case the conflict check above
            # catches instead).
            updated = self._decode_into_record(record, page, schema)
            save_record(self.store, path, updated)
            pulled_hash = self._pushed_hash(self._properties(updated, schema, local_id_ref))
            self.store.upsert_idea_notion_link(record.id, notion_page_id=page_id, synced_hash=pulled_hash, notion_last_edited_time=remote_last_edited, sync_error=None, timestamp=now)
            return {"item_id": record.id, "action": "pulled", "notion_page_id": page_id}
        if page_id and not local_changed:
            return {"item_id": record.id, "action": "unchanged"}

        was_creating = not page_id
        try:
            if page_id:
                page = client.update_page(page_id, properties)
            else:
                page = client.create_page(source_id, properties)
                page_id = str(page.get("id") or "")
        except Exception as error:  # noqa: BLE001
            self.store.upsert_idea_notion_link(record.id, notion_page_id=page_id, synced_hash=link["synced_hash"] if link else None, notion_last_edited_time=link["notion_last_edited_time"] if link else None, sync_error=str(error), timestamp=now)
            return {"item_id": record.id, "action": "error", "error": str(error)}

        self.store.upsert_idea_notion_link(record.id, notion_page_id=page_id, synced_hash=current_hash, notion_last_edited_time=page.get("last_edited_time"), sync_error=None, timestamp=now)
        return {"item_id": record.id, "action": "created" if was_creating else "updated", "notion_page_id": page_id}

    def resolve_conflict(self, path: Path, resolution: str, now: str) -> dict[str, Any]:
        """Explicit human resolution for a flagged conflict -- the one
        place either side is intentionally allowed to overwrite the other,
        because a person asked for it by name rather than it happening as a
        side effect of an ordinary sync pass."""
        if resolution not in {"keep_local", "keep_notion"}:
            raise ValueError("resolution must be 'keep_local' or 'keep_notion'")
        record = load_record(self.store, path)
        link = self.store.idea_notion_link(record.id)
        if link is None or not link["notion_page_id"]:
            raise ValueError("this idea has no linked Notion page to resolve against")
        page_id = str(link["notion_page_id"])
        client, source_id, schema = self._schema()
        local_id_ref = self._ensure_local_id_property(client, source_id, schema)
        page = client.page(page_id)

        if resolution == "keep_local":
            properties = self._properties(record, schema, local_id_ref)
            updated_page = client.update_page(page_id, properties)
            self.store.upsert_idea_notion_link(record.id, notion_page_id=page_id, synced_hash=self._pushed_hash(properties), notion_last_edited_time=updated_page.get("last_edited_time"), sync_error=None, timestamp=now)
            return {"item_id": record.id, "action": "kept_local"}

        updated_record = self._decode_into_record(record, page, schema)
        save_record(self.store, path, updated_record)
        pulled_hash = self._pushed_hash(self._properties(updated_record, schema, local_id_ref))
        self.store.upsert_idea_notion_link(record.id, notion_page_id=page_id, synced_hash=pulled_hash, notion_last_edited_time=page.get("last_edited_time"), sync_error=None, timestamp=now)
        return {"item_id": record.id, "action": "kept_notion"}

    def _raise_conflict(self, record: ItemRecord, page_id: str, now: str) -> None:
        self.store.create_notification({
            "id": f"idea-conflict:{record.id}", "type": "idea_sync_conflict",
            "title": f'"{record.title}" changed in both places',
            "body": "This idea was edited locally and in Notion since the last sync. Review both before syncing again -- nothing was overwritten.",
            "entity_id": record.id, "source_event_id": None, "source_rule_id": None, "priority": "normal",
            "dedupe_key": f"idea_sync_conflict:{record.id}", "state": "pending", "actions_json": json.dumps(["review", "dismiss"]),
            "created_at": now, "expires_at": None,
        })

    # -- Notion -> local: only ever *creates* a new local idea -------------

    def pull_new_ideas(self, ideas_folder_path: Path, now: str, *, limit: int = 25) -> list[dict[str, Any]]:
        client, source_id, schema = self._schema()
        local_id_ref = self._ensure_local_id_property(client, source_id, schema)
        known_ids = {str(row["notion_page_id"]) for row in self.store.idea_notion_links() if row["notion_page_id"]}
        results: list[dict[str, Any]] = []
        for page in client.query(source_id, limit=200):
            if len(results) >= limit:
                break
            page_id = str(page.get("id") or "")
            if not page_id or page_id in known_ids:
                continue
            from .notion_api import decode_property, page_property
            local_id_value = decode_property(page_property(page, local_id_ref.name)) if local_id_ref else None
            if local_id_value:
                continue  # already linked to a local idea, just not cached above yet
            title_ref = schema.title()
            title = str(decode_property(page_property(page, title_ref.name)) or "Untitled idea from Notion") if title_ref else "Untitled idea from Notion"
            directory = _unique_child_directory(ideas_folder_path, title)
            directory.mkdir(parents=True, exist_ok=False)
            enriched = self._decode_into_record(initialize_record(self.store, directory, title=title, idea=True), page, schema)
            save_record(self.store, directory, enriched)
            # Compute and store the hash a push of this exact record would
            # produce, so the very next sync sees "unchanged" instead of
            # immediately pushing a needless round-trip straight back --
            # idempotency starts at the moment of the pull itself.
            pushed_hash = self._pushed_hash(self._properties(enriched, schema, local_id_ref))
            self.store.upsert_idea_notion_link(enriched.id, notion_page_id=page_id, synced_hash=pushed_hash, notion_last_edited_time=page.get("last_edited_time"), sync_error=None, timestamp=now)
            results.append({"item_id": enriched.id, "notion_page_id": page_id, "title": title, "directory": str(directory)})
        return results


def _with_field(record: ItemRecord, field: str, value: Any) -> ItemRecord:
    from dataclasses import replace
    return replace(record, **{field: value})


def _unique_child_directory(parent: Path, title: str) -> Path:
    safe = re.sub(r"[/:]+", "-", title).strip() or "Untitled idea"
    candidate = parent / safe
    suffix = 2
    while candidate.exists():
        candidate = parent / f"{safe} ({suffix})"
        suffix += 1
    return candidate
