"""Deterministic reminder/condition evaluation for actionable intent folders.

Every check here is plain arithmetic over already-persisted facts (item
metadata, ``last_seen_at``, ``last_reviewed_at``, activity sessions) -- no
LLM involvement, matching the project's rule that dates/conditions stay
deterministic. See docs/intent-folders.md ("Reminders") for the supported
condition vocabulary: ``after``, ``defer_until`` (absolute or
``next_project_session``), ``after_inactive``, and ``repeat``.
"""

from __future__ import annotations

import json
import time
from datetime import date, datetime
from typing import Any

from .config import Config
from .durations import parse_duration_seconds
from .store import WorkspaceStore

DEFAULT_REVIEW_COOLDOWN_SECONDS = 7 * 86400.0


def _parse_when(value: Any) -> float | None:
    if value in (None, ""):
        return None
    if isinstance(value, (int, float)):
        return float(value)
    text = str(value)
    try:
        parsed = date.fromisoformat(text) if len(text) == 10 else datetime.fromisoformat(text)
    except ValueError:
        return None
    if isinstance(parsed, date) and not isinstance(parsed, datetime):
        parsed = datetime(parsed.year, parsed.month, parsed.day)
    if parsed.tzinfo is None:
        parsed = parsed.astimezone()
    return parsed.timestamp()


class ReminderEngine:
    def __init__(self, store: WorkspaceStore, config: Config) -> None:
        self.store = store
        self.config = config

    def _folder_cfg(self, name: str):
        return next((f for f in self.config.intent_folders if f.name == name), None)

    def is_item_due(self, item_row: Any, now: float | None = None) -> tuple[bool, str]:
        """Return (due, reason). ``reason`` is always populated for auditability."""

        now = time.time() if now is None else now
        metadata = json.loads(item_row["metadata_json"] or "{}")
        folder_cfg = self._folder_cfg(item_row["intent_folder"])

        after_at = _parse_when(metadata.get("after"))
        if after_at is not None and now < after_at:
            return False, "not_yet_after"

        defer_until = metadata.get("defer_until")
        if defer_until == "next_project_session":
            source_project = item_row["source_project"]
            reference = item_row["last_reviewed_at"] or item_row["created_at"]
            if not source_project or not self.store.has_activity_session_started_since(source_project, float(reference)):
                return False, "deferred_until_next_session"
        elif defer_until:
            defer_at = _parse_when(defer_until)
            if defer_at is not None and now < defer_at:
                return False, "deferred"

        # A folder-level inactivity default (e.g. "To Archive" -> 90d) only
        # applies when the item has no other explicit condition of its own;
        # it is a fallback default, not an additional requirement stacked on
        # top of an explicit after/defer_until the item already set.
        explicit_after_or_defer = bool(metadata.get("after") or defer_until)
        inactivity_value = metadata.get("after_inactive") or (
            folder_cfg.inactivity_threshold if folder_cfg and not explicit_after_or_defer else ""
        )
        inactivity_seconds = parse_duration_seconds(inactivity_value) if inactivity_value else None
        if inactivity_seconds is not None:
            if now - float(item_row["last_seen_at"]) < inactivity_seconds:
                return False, "not_yet_inactive"
        elif not explicit_after_or_defer:
            return False, "no_condition"

        repeat_value = metadata.get("repeat") or (folder_cfg.default_snooze if folder_cfg else "")
        repeat_seconds = parse_duration_seconds(repeat_value) if repeat_value else DEFAULT_REVIEW_COOLDOWN_SECONDS
        if item_row["last_reviewed_at"] and now - float(item_row["last_reviewed_at"]) < repeat_seconds:
            return False, "recently_reviewed"

        return True, "due"

    def due_items(self, now: float | None = None) -> dict[str, list[dict[str, Any]]]:
        now = time.time() if now is None else now
        result: dict[str, list[dict[str, Any]]] = {}
        for row in self.store.all_items(only_existing=True):
            due, reason = self.is_item_due(row, now)
            if due:
                result.setdefault(row["intent_folder"], []).append(
                    {"item_id": row["item_id"], "path": row["path"], "title": row["title"] or row["name"], "reason": reason}
                )
        return result
