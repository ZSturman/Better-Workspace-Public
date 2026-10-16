"""Durable, idempotent inbox for Hammerspoon-produced macOS-level events.

A producer (Hammerspoon, or anything else local) appends one JSON object per
line to ``settings.path`` -- app-focus changes, idle/away transitions, system
sleep/wake, and similar signals a filesystem watcher cannot see on its own.
Ingestion here is byte-offset based, so a line is read exactly once under
normal operation, and every event is recorded into the same ``event_journal``
this runtime already uses for filesystem-derived facts, keyed by a stable
event id. ``CoreStore.record_event`` is ``INSERT OR IGNORE`` on that primary
key, so the producer never needs Workspace Watcher online at the moment an
event happens -- it can keep appending to the file while the watcher is
stopped, and replaying the same line later (a retried append, an offset reset
after truncation, a restart mid-read) can never create a duplicate fact.
"""

from __future__ import annotations

import hashlib
import json
from typing import Any

from .core_config import HammerspoonInboxSettings
from .core_engine import utc_now
from .core_events import WorkspaceEvent
from .core_store import CoreStore

OFFSET_STATE_KEY = "hammerspoon_inbox.offset"
LAST_EVENT_STATE_KEY = "hammerspoon_inbox.last_event_at"
RESERVED_FIELDS = {"kind", "event_id", "id", "entity_id", "timestamp"}


def event_id_for(row: dict[str, Any], raw_line: str) -> str:
    """Prefer the producer's own id; otherwise hash the raw line so an
    identical retried append still dedupes to the same journal row."""
    explicit = row.get("event_id") or row.get("id")
    if isinstance(explicit, str) and explicit:
        return f"hammerspoon:{explicit}"
    digest = hashlib.sha256(raw_line.encode("utf-8")).hexdigest()
    return f"hammerspoon:{digest}"


class HammerspoonInbox:
    def __init__(self, store: CoreStore, settings: HammerspoonInboxSettings) -> None:
        self.store = store
        self.settings = settings

    def ingest(self) -> list[WorkspaceEvent]:
        """Read any lines appended since the last call and record them.

        Returns only genuinely new events (skips ids already present in the
        journal), so a caller can run rule evaluation just for those without
        reprocessing history on every tick.
        """
        if not self.settings.enabled or not self.settings.path.exists():
            return []
        offset = int((self.store.get_state(OFFSET_STATE_KEY) or {}).get("offset", 0))
        size = self.settings.path.stat().st_size
        if offset > size:
            # The file was rotated or truncated out from under us. Restart at
            # the top rather than silently drop content the producer wrote.
            offset = 0
        recorded: list[WorkspaceEvent] = []
        latest_occurred_at: str | None = None
        with self.settings.path.open("r", encoding="utf-8") as handle:
            handle.seek(offset)
            for raw_line in handle:
                raw = raw_line.strip()
                if not raw:
                    continue
                try:
                    row = json.loads(raw)
                except json.JSONDecodeError:
                    # A malformed line must not stop every later line from
                    # being ingested.
                    continue
                if not isinstance(row, dict):
                    continue
                kind = str(row.get("kind") or "unknown")
                occurred_at = str(row["timestamp"]) if row.get("timestamp") else utc_now()
                event = WorkspaceEvent(
                    id=event_id_for(row, raw),
                    type=f"hammerspoon.{kind}",
                    entity_id=(str(row["entity_id"]) if row.get("entity_id") else None),
                    payload={key: value for key, value in row.items() if key not in RESERVED_FIELDS},
                    source="hammerspoon",
                    occurred_at=occurred_at,
                )
                if self.store.record_event(event):
                    recorded.append(event)
                latest_occurred_at = occurred_at
            new_offset = handle.tell()
        now = utc_now()
        self.store.set_state(OFFSET_STATE_KEY, {"offset": new_offset}, now)
        if latest_occurred_at is not None:
            self.store.set_state(LAST_EVENT_STATE_KEY, {"occurred_at": latest_occurred_at}, now)
        return recorded
