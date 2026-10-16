"""Legacy ``watcher.item.toml`` codec and explicit compatibility helpers.

The running service imports these records into private SQLite storage and never
uses these file-writing helpers. They remain for legacy fixtures and tooling.
Runtime metadata access lives in private_items.py.
"""

from __future__ import annotations

import os
import tempfile
import tomllib
import uuid
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any


ITEM_FILENAME = "watcher.item.toml"
CURRENT_SCHEMA_VERSION = 1


class ItemMetadataError(ValueError):
    pass


@dataclass(frozen=True)
class ItemRecord:
    id: str
    title: str
    schema_version: int = CURRENT_SCHEMA_VERSION
    type: str = "item"
    status: str = "active"
    one_liner: str = ""
    description: str = ""
    notes: str = ""
    source: str = ""
    priority: str | None = None
    tags: tuple[str, ...] = ()
    domains: tuple[str, ...] = ()
    tools: tuple[str, ...] = ()
    mediums: tuple[str, ...] = ()
    related_projects: tuple[str, ...] = ()
    potential_projects: tuple[str, ...] = ()
    excluded_projects: tuple[str, ...] = ()
    related_ideas: tuple[str, ...] = ()
    confidence: float | None = None
    effort: int | None = None
    impact: str | None = None
    defer_until: str | None = None
    keep_suggesting: bool = True
    provenance: dict[str, Any] | None = None
    extra: dict[str, Any] | None = None
    planning: dict[str, Any] | None = None


# `type` doubles as an idea's classification for items discovered inside an
# "Ideas" intent folder (see notion_ideas_v2.py's docstring for the full
# rationale) -- these are the values the GUI offers a picker for, but any
# string is accepted so a person is never blocked from writing their own.
SUGGESTED_IDEA_TYPES = ("unclassified", "project", "feature", "story", "experiment", "media", "task")
SUGGESTED_IDEA_STATUSES = ("raw", "exploring", "plan", "to_implement", "to_write", "archived")

_KNOWN = frozenset({
    "schema_version", "id", "title", "type", "status", "one_liner", "description", "notes", "source", "priority",
    "tags", "domains", "tools", "mediums", "related_projects", "potential_projects", "excluded_projects", "related_ideas",
    "confidence", "effort", "impact", "resurfacing", "provenance",
})


def item_metadata_path(item_directory: Path) -> Path:
    return item_directory / ITEM_FILENAME


def parse_item_record(path: Path) -> ItemRecord:
    try:
        with path.open("rb") as stream:
            raw = tomllib.load(stream)
    except FileNotFoundError:
        raise
    except (OSError, tomllib.TOMLDecodeError) as error:
        raise ItemMetadataError(f"cannot parse {path.name}: {error}") from error
    version = raw.get("schema_version")
    if version != CURRENT_SCHEMA_VERSION:
        raise ItemMetadataError(f"unsupported item schema_version {version!r}")
    item_id, title = raw.get("id"), raw.get("title")
    if not isinstance(item_id, str) or not _is_uuid(item_id):
        raise ItemMetadataError("id must be a UUID string")
    if not isinstance(title, str) or not title.strip():
        raise ItemMetadataError("title must be a non-empty string")
    resurfacing = raw.get("resurfacing", {})
    if not isinstance(resurfacing, dict):
        raise ItemMetadataError("[resurfacing] must be a TOML table")
    return ItemRecord(
        id=item_id, title=title.strip(), schema_version=version,
        type=_string(raw.get("type"), "item"), status=_string(raw.get("status"), "active"),
        one_liner=_string(raw.get("one_liner"), ""), description=_string(raw.get("description"), ""),
        notes=_string(raw.get("notes"), ""), source=_string(raw.get("source"), ""), priority=_optional_string(raw.get("priority")),
        tags=_strings(raw.get("tags")), domains=_strings(raw.get("domains")), tools=_strings(raw.get("tools")), mediums=_strings(raw.get("mediums")),
        related_projects=_strings(raw.get("related_projects")), potential_projects=_strings(raw.get("potential_projects")),
        excluded_projects=_strings(raw.get("excluded_projects")), related_ideas=_strings(raw.get("related_ideas")),
        confidence=_number_or_none(raw.get("confidence")),
        effort=_int_or_none(raw.get("effort")), impact=_optional_string(raw.get("impact")),
        defer_until=_optional_string(resurfacing.get("defer_until")),
        keep_suggesting=bool(resurfacing.get("keep_suggesting", True)),
        provenance=raw.get("provenance") if isinstance(raw.get("provenance"), dict) else None,
        extra={key: value for key, value in raw.items() if key not in _KNOWN},
    )


def initialize_item_record(item_directory: Path, *, title: str | None = None) -> ItemRecord:
    """Atomically create a starter metadata file, never replacing one."""

    path = item_metadata_path(item_directory)
    item_directory.mkdir(parents=True, exist_ok=True)
    record = ItemRecord(id=str(uuid.uuid4()), title=title or item_directory.name)
    payload = render_item_record(record)
    try:
        descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)
    except FileExistsError:
        return parse_item_record(path)
    with os.fdopen(descriptor, "w", encoding="utf-8") as output:
        output.write(payload)
        output.flush()
        os.fsync(output.fileno())
    _fsync_directory(item_directory)
    return record


def replace_item_record_identity(path: Path, item_id: str) -> ItemRecord:
    """Assign a new UUID without rewriting user-owned TOML fields.

    A copied item directory also copies its metadata UUID.  Leaving two live
    directories with that UUID would corrupt the canonical identity model, so
    reconciliation calls this narrowly-scoped repair on the copied record.
    """

    if not _is_uuid(item_id):
        raise ItemMetadataError("replacement id must be a UUID string")
    source = path.read_text(encoding="utf-8")
    updated, count = re.subn(r'(?m)^id[ \t]*=[ \t]*"[^"]+"[ \t]*$', f'id = "{item_id}"', source, count=1)
    if count != 1:
        raise ItemMetadataError("cannot safely replace item id")
    descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent, text=True)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as output:
            output.write(updated)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
        _fsync_directory(path.parent)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    return parse_item_record(path)


def update_item_record(path: Path, *, status: str | None = None, defer_until: str | None = None) -> ItemRecord:
    """Safely patch operational fields while retaining unknown TOML content."""
    source = path.read_text(encoding="utf-8")
    updated = source
    if status is not None:
        if not status.strip():
            raise ItemMetadataError("status must be non-empty")
        updated, count = re.subn(r'(?m)^status[ \t]*=[^\n]*$', f"status = {_quote(status)}", updated, count=1)
        if not count:
            marker = re.search(r"(?m)^\[resurfacing\]", updated)
            updated = updated[:marker.start()] + f"status = {_quote(status)}\n\n" + updated[marker.start():] if marker else updated + f"\nstatus = {_quote(status)}\n"
    if defer_until is not None:
        if "[resurfacing]" not in updated:
            updated += "\n[resurfacing]\n"
        section = re.search(r"(?ms)(^\[resurfacing\]\n)(.*?)(?=^\[|\Z)", updated)
        assert section is not None
        body = section.group(2)
        line = f"defer_until = {_quote(defer_until)}\n"
        if re.search(r"(?m)^defer_until[ \t]*=", body):
            body = re.sub(r"(?m)^defer_until[ \t]*=[^\n]*\n?", line, body, count=1)
        else:
            body += line
        updated = updated[:section.start(2)] + body + updated[section.end(2):]
    if updated == source:
        return parse_item_record(path)
    descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent, text=True)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as output:
            output.write(updated); output.flush(); os.fsync(output.fileno())
        os.replace(temporary, path); _fsync_directory(path.parent)
    finally:
        if os.path.exists(temporary): os.unlink(temporary)
    return parse_item_record(path)


def render_item_record(record: ItemRecord) -> str:
    """Render the known core fields; consumers retain unknown TOML fields on read."""

    lines = [
        "# Human-owned portable item metadata. Operational state is stored locally in SQLite.",
        f"schema_version = {record.schema_version}", f'id = "{record.id}"', f"title = {_quote(record.title)}",
        f"type = {_quote(record.type)}", f"status = {_quote(record.status)}",
    ]
    for key in ("one_liner", "description", "notes", "source", "priority"):
        value = getattr(record, key)
        if value:
            lines.append(f"{key} = {_quote(value)}")
    for key in ("tags", "domains", "tools", "mediums", "related_projects", "potential_projects", "excluded_projects", "related_ideas"):
        values = getattr(record, key)
        if values:
            lines.append(f"{key} = [{', '.join(_quote(value) for value in values)}]")
    for key in ("confidence", "effort", "impact"):
        value = getattr(record, key)
        if value is not None:
            lines.append(f"{key} = {_quote(value) if isinstance(value, str) else value}")
    # Unknown top-level keys must be rendered here -- before any `[table]`
    # header -- or TOML would parse them as belonging to that table on the
    # next read, silently relocating (and eventually losing) them.
    for key, value in sorted((record.extra or {}).items()):
        if isinstance(value, (str, int, float, bool)) or (isinstance(value, list) and all(isinstance(v, str) for v in value)):
            lines.append(f"{key} = {_toml_scalar(value)}")
    lines += ["", "[resurfacing]", f"keep_suggesting = {'true' if record.keep_suggesting else 'false'}"]
    if record.defer_until:
        lines.append(f"defer_until = {_quote(record.defer_until)}")
    if record.provenance:
        lines += ["", "[provenance]"] + [f"{key} = {_quote(value)}" for key, value in sorted(record.provenance.items()) if isinstance(value, (str, int, float, bool))]
    return "\n".join(lines) + "\n"


def _toml_scalar(value: Any) -> str:
    if isinstance(value, list):
        return "[" + ", ".join(_quote(v) for v in value) + "]"
    return _quote(value) if isinstance(value, str) else str(value)


def save_item_record(path: Path, record: ItemRecord) -> ItemRecord:
    """Fully re-render and atomically replace the sidecar for a GUI-driven edit.

    A person editing an idea's fields through the Ideas tab is, per this
    file's own contract, exactly as authoritative as one editing the TOML by
    hand -- so a full, canonical re-render (rather than `update_item_record`'s
    narrow line-patching) is appropriate here. Unknown keys survive via
    ``record.extra``.
    """

    payload = render_item_record(record)
    descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent, text=True)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as output:
            output.write(payload); output.flush(); os.fsync(output.fileno())
        os.replace(temporary, path)
        _fsync_directory(path.parent)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    return parse_item_record(path)


def initialize_idea_record(item_directory: Path, *, title: str | None = None) -> ItemRecord:
    """Like ``initialize_item_record``, but starts an idea as "unclassified"
    rather than the generic "item" default -- ideas should not be forced into
    a classification before a person chooses one."""

    path = item_metadata_path(item_directory)
    item_directory.mkdir(parents=True, exist_ok=True)
    record = ItemRecord(id=str(uuid.uuid4()), title=title or item_directory.name, type="unclassified")
    payload = render_item_record(record)
    try:
        descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)
    except FileExistsError:
        return parse_item_record(path)
    with os.fdopen(descriptor, "w", encoding="utf-8") as output:
        output.write(payload)
        output.flush()
        os.fsync(output.fileno())
    _fsync_directory(item_directory)
    return record


def _quote(value: object) -> str:
    return '"' + str(value).replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n") + '"'


def _is_uuid(value: str) -> bool:
    try:
        uuid.UUID(value)
        return True
    except ValueError:
        return False


def _string(value: Any, default: str) -> str:
    return value if isinstance(value, str) else default


def _optional_string(value: Any) -> str | None:
    return value if isinstance(value, str) and value else None


def _strings(value: Any) -> tuple[str, ...]:
    return tuple(item for item in value if isinstance(item, str)) if isinstance(value, list) else ()


def _number_or_none(value: Any) -> float | None:
    return float(value) if isinstance(value, (int, float)) and not isinstance(value, bool) else None


def _int_or_none(value: Any) -> int | None:
    return value if isinstance(value, int) and not isinstance(value, bool) else None


def _fsync_directory(directory: Path) -> None:
    try:
        descriptor = os.open(directory, os.O_RDONLY)
    except OSError:
        return
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
