"""Item-level metadata: the optional ``.item.toml`` sidecar.

Placed inside an item directory (``For Inspiration/Dashboard Screenshots/.item.toml``)
or beside a plain file (``For Inspiration/notes.md.item.toml``). TOML was
chosen -- not YAML -- to match ``config.toml`` and reuse the stdlib
``tomllib`` parser (no new dependency), and because TOML has native date
types, so ``after = 2027-10-10`` parses without any date-format guessing.

This file is **human-authored and authoritative**. The watcher never
overwrites a field a person set, and every value the watcher itself infers
(LM Studio tags/summaries, last-surfaced/last-dismissed timestamps, relevance
scores) lives only in SQLite -- derived, rebuildable, and never round-tripped
back into this file. The one exception is the small, explicit CLI actions
below (``items tag``, ``items defer``, ...), which a person invoked directly;
those edit the file the same way a person editing it by hand would.

An item does not need this file at all -- a plain, unannotated folder or
file inside a configured intent folder is still indexed (see ``intent.py``).
"""

from __future__ import annotations

import tomllib
from dataclasses import dataclass, field
from datetime import date, datetime
from pathlib import Path
from typing import Any

from .durations import parse_duration_seconds
from .tags import split_tag_list

METADATA_FILENAME = ".item.toml"

_KNOWN_KEYS = {
    "tags", "title", "description", "created", "last_reviewed", "source",
    "source_project", "action", "after", "defer_until", "snooze",
    "after_inactive", "priority", "requires_confirmation", "archive_state",
    "related_projects", "excluded_projects", "used_by_projects", "repeat",
}


def _iso(value: Any) -> str | None:
    if value is None:
        return None
    if isinstance(value, (date, datetime)):
        return value.isoformat()
    return str(value)


@dataclass
class ItemMetadata:
    tags: list[str] = field(default_factory=list)
    title: str | None = None
    description: str | None = None
    created: str | None = None
    last_reviewed: str | None = None
    source: str | None = None
    source_project: str | None = None
    action: str | None = None
    after: str | None = None            # absolute ISO date/datetime: not due before this
    defer_until: str | None = None      # ISO date/datetime, or the literal "next_project_session"
    snooze: str | None = None           # duration shorthand, e.g. "30d" (informational; defer_until is authoritative once set)
    after_inactive: str | None = None   # duration string, e.g. "90d"
    priority: str | None = None         # "low" | "normal" | "high"
    requires_confirmation: bool | None = None
    archive_state: str | None = None    # "active" | "archived"
    related_projects: list[str] = field(default_factory=list)
    excluded_projects: list[str] = field(default_factory=list)
    used_by_projects: list[str] = field(default_factory=list)
    repeat: str | None = None           # duration string: re-surface this often after a decision
    extra: dict[str, Any] = field(default_factory=dict)
    raw_hash_fields: tuple = ()

    def after_inactive_seconds(self) -> float | None:
        return parse_duration_seconds(self.after_inactive) if self.after_inactive else None

    def repeat_seconds(self) -> float | None:
        return parse_duration_seconds(self.repeat) if self.repeat else None


def metadata_path_for(item_path: Path, is_directory: bool) -> Path:
    return (item_path / METADATA_FILENAME) if is_directory else item_path.with_name(item_path.name + METADATA_FILENAME)


def parse_item_metadata(path: Path) -> ItemMetadata | None:
    """Return None if no sidecar file exists; raise nothing for a bad file --
    a malformed ``.item.toml`` degrades to "no metadata", not a crash, and is
    surfaced via reconciliation issues rather than stopping indexing."""

    try:
        raw = tomllib.loads(path.read_text(encoding="utf-8"))
    except (OSError, tomllib.TOMLDecodeError, UnicodeDecodeError):
        return None
    extra = {key: value for key, value in raw.items() if key not in _KNOWN_KEYS}
    return ItemMetadata(
        tags=split_tag_list(raw.get("tags")),
        title=raw.get("title"),
        description=raw.get("description"),
        created=_iso(raw.get("created")),
        last_reviewed=_iso(raw.get("last_reviewed")),
        source=raw.get("source"),
        source_project=raw.get("source_project"),
        action=raw.get("action"),
        after=_iso(raw.get("after")),
        defer_until=_iso(raw.get("defer_until")) if not isinstance(raw.get("defer_until"), str) else raw.get("defer_until"),
        snooze=raw.get("snooze"),
        after_inactive=raw.get("after_inactive"),
        priority=raw.get("priority"),
        requires_confirmation=raw.get("requires_confirmation"),
        archive_state=raw.get("archive_state"),
        related_projects=[str(x) for x in raw.get("related_projects", [])],
        excluded_projects=[str(x) for x in raw.get("excluded_projects", [])],
        used_by_projects=[str(x) for x in raw.get("used_by_projects", [])],
        repeat=raw.get("repeat"),
        extra=extra,
    )


def _toml_value(value: Any) -> str:
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (int, float)):
        return str(value)
    if isinstance(value, (list, tuple)):
        return "[" + ", ".join(_toml_value(v) for v in value) + "]"
    text = str(value).replace("\\", "\\\\").replace('"', '\\"')
    return f'"{text}"'


def render_new_item_toml(fields: dict[str, Any]) -> str:
    """A fresh, commented ``.item.toml`` for CLI-driven creation."""

    lines = [
        "# Item metadata for Workspace Watcher. Human-authored and authoritative --",
        "# the watcher never overwrites a value set here. See docs/tagging.md and",
        "# docs/intent-folders.md.",
        "",
    ]
    for key, value in fields.items():
        if value in (None, [], ""):
            continue
        lines.append(f"{key} = {_toml_value(value)}")
    return "\n".join(lines) + "\n"


def upsert_item_toml_fields(path: Path, updates: dict[str, Any]) -> None:
    """Set specific top-level keys in ``.item.toml``, preserving everything else.

    This is a targeted line editor, not a full TOML AST round-trip: it
    replaces a ``key = ...`` line if present, otherwise appends one. It
    intentionally never touches lines it doesn't recognize -- comments and
    unrelated keys survive untouched. Good enough for the small, single-key
    edits the CLI performs (add a tag, set a defer date); hand-editing
    remains the expected path for anything more elaborate.
    """

    existing_lines: list[str] = []
    if path.exists():
        existing_lines = path.read_text(encoding="utf-8").splitlines()
    remaining = dict(updates)
    new_lines: list[str] = []
    for line in existing_lines:
        stripped = line.strip()
        matched_key = None
        if stripped and not stripped.startswith("#") and "=" in stripped:
            candidate = stripped.split("=", 1)[0].strip()
            if candidate in remaining:
                matched_key = candidate
        if matched_key is not None:
            value = remaining.pop(matched_key)
            if value is None:
                continue  # drop the key entirely
            new_lines.append(f"{matched_key} = {_toml_value(value)}")
        else:
            new_lines.append(line)
    for key, value in remaining.items():
        if value is None:
            continue
        new_lines.append(f"{key} = {_toml_value(value)}")
    if not existing_lines:
        header = [
            "# Item metadata for Workspace Watcher. Human-authored and authoritative --",
            "# the watcher never overwrites a value set here. See docs/tagging.md and",
            "# docs/intent-folders.md.",
            "",
        ]
        new_lines = header + new_lines
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(new_lines) + "\n", encoding="utf-8")
