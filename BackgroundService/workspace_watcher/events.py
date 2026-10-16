"""The normalized event model.

Downstream consumers (handlers, the SQLite store, future external systems)
only ever see `NormalizedEvent`. Nothing about watchdog, FSEvents, or the
coalescing engine leaks past this module.
"""

from __future__ import annotations

import json
import uuid
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Any, Optional


class EventType:
    """String constants rather than a real Enum so the values serialize
    to SQLite / JSON without a custom encoder."""

    CREATED = "created"
    MODIFIED = "modified"
    DELETED = "deleted"
    RENAMED = "renamed"          # same parent directory, name changed
    MOVED = "moved"              # parent directory changed
    BULK_CHANGE = "bulk_change"  # synthetic: many raw events, one directory
    PROJECT_DETECTED = "project_detected"          # synthetic
    PROJECT_ACTIVE_CHANGED = "project_active_changed"  # synthetic

    FILESYSTEM_TYPES = frozenset({CREATED, MODIFIED, DELETED, RENAMED, MOVED, BULK_CHANGE})
    SYNTHETIC_TYPES = frozenset({BULK_CHANGE, PROJECT_DETECTED, PROJECT_ACTIVE_CHANGED})


@dataclass
class NormalizedEvent:
    type: str
    path: str                      # workspace-root-relative, POSIX separators
    is_directory: bool
    area: str                      # e.g. "Projects", "Unsorted", "Unclassified"
    area_kind: str                 # e.g. "projects", "inbox", "generic", "system"
    meaningful: bool
    prev_path: Optional[str] = None
    project_id: Optional[str] = None
    project_name: Optional[str] = None
    matched_rule: Optional[str] = None
    raw_event_count: int = 1
    metadata: dict[str, Any] = field(default_factory=dict)
    ts: float = field(default_factory=lambda: datetime.now(timezone.utc).timestamp())
    event_id: str = field(default_factory=lambda: str(uuid.uuid4()))

    @property
    def ts_iso(self) -> str:
        return datetime.fromtimestamp(self.ts, tz=timezone.utc).isoformat()

    def to_dict(self) -> dict[str, Any]:
        return {
            "event_id": self.event_id,
            "ts": self.ts,
            "ts_iso": self.ts_iso,
            "type": self.type,
            "path": self.path,
            "prev_path": self.prev_path,
            "is_directory": self.is_directory,
            "area": self.area,
            "area_kind": self.area_kind,
            "project_id": self.project_id,
            "project_name": self.project_name,
            "meaningful": self.meaningful,
            "matched_rule": self.matched_rule,
            "raw_event_count": self.raw_event_count,
            "metadata": self.metadata,
        }

    def to_json(self) -> str:
        return json.dumps(self.to_dict(), sort_keys=True)

    def summary(self) -> str:
        arrow = f" -> {self.prev_path}" if self.prev_path else ""
        tag = "" if self.meaningful else f" [ignored:{self.matched_rule}]"
        proj = f" (project={self.project_name})" if self.project_name else ""
        return f"{self.type:<22} {self.path}{arrow}{proj}{tag}"
