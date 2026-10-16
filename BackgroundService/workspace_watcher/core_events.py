"""Versioned events used beyond the filesystem sensor boundary."""

from __future__ import annotations

import uuid
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from typing import Any


@dataclass(frozen=True)
class WorkspaceEvent:
    type: str
    entity_id: str | None = None
    payload: dict[str, Any] = field(default_factory=dict)
    source: str = "filesystem"
    occurred_at: str = field(default_factory=lambda: datetime.now(timezone.utc).isoformat())
    id: str = field(default_factory=lambda: str(uuid.uuid4()))
    schema_version: int = 1
    causation_id: str | None = None
    correlation_id: str | None = None

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


class EventTypes:
    FILESYSTEM_CHANGED = "filesystem.changed"
    INTENT_DISCOVERED = "intent.discovered"
    INTENT_ITEM_CREATED = "intent_item.created"
    INTENT_ITEM_UPDATED = "intent_item.updated"
    INTENT_ITEM_MOVED = "intent_item.moved"
    INTENT_ITEM_INTENT_CHANGED = "intent_item.intent_changed"
    INTENT_ITEM_METADATA_CHANGED = "intent_item.metadata_changed"
    INTENT_ITEM_DELETED = "intent_item.deleted"
    INTENT_ITEM_IDENTITY_COLLISION = "intent_item.identity_collision_resolved"
    RESURFACING_DUE = "resurfacing.item_due"
    NOTIFICATION_CREATED = "notification.created"
    MESSAGE_QUEUED = "message.queued"
    PROJECT_DISCOVERED = "project.discovered"
    PROJECT_RENAMED = "project.renamed"
    PROJECT_DELETED = "project.deleted"
    PROJECT_ACTIVATED = "project.activated"
    SESSION_STARTED = "session.started"
    SESSION_RESUMED = "session.resumed"
    SESSION_CLOSED = "session.closed"
