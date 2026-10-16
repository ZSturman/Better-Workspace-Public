"""Validated actions and durable local notification/message dispatch."""

from __future__ import annotations

import json
import uuid
from datetime import datetime, timezone
from typing import Any

from .core_events import EventTypes, WorkspaceEvent
from .core_store import CoreStore


ALLOWED_ACTIONS = frozenset({"notification", "emit_event", "route_message", "update_item", "resurface_item", "request_review", "open_item"})
NOTIFICATION_TYPES = frozenset({"information", "suggestion", "idea", "inspiration", "review", "testing", "action_required", "warning", "error", "success", "project"})


class ActionDispatcher:
    def __init__(self, store: CoreStore) -> None:
        self.store = store

    def dispatch(self, action: dict[str, Any], event: WorkspaceEvent) -> bool:
        action_type = action.get("type")
        if action_type not in ALLOWED_ACTIONS:
            raise ValueError(f"unsupported action type: {action_type!r}")
        now = datetime.now(timezone.utc).isoformat()
        action_id = str(uuid.uuid4())
        try:
            result = self._dispatch(action, event, now)
            self.store.add_action_result({"id": action_id, "action_type": action_type, "source_event_id": event.id, "source_rule_id": action.get("rule_id"), "status": "completed" if result else "deduplicated", "result_json": json.dumps({"created": result}, sort_keys=True), "failure_reason": None, "created_at": now})
            return result
        except (KeyError, TypeError, ValueError) as error:
            self.store.add_action_result({"id": action_id, "action_type": str(action_type), "source_event_id": event.id, "source_rule_id": action.get("rule_id"), "status": "failed", "result_json": "{}", "failure_reason": str(error), "created_at": now})
            raise

    def _dispatch(self, action: dict[str, Any], event: WorkspaceEvent, now: str) -> bool:
        action_type = action["type"]
        if action_type == "emit_event":
            self.store.record_event(WorkspaceEvent(type=str(action["event_type"]), entity_id=event.entity_id, payload=dict(action.get("payload", {})), source="rule", causation_id=event.id, correlation_id=event.correlation_id or event.id)); return True
        if action_type == "notification":
            notification_type = action.get("notification_type", "information")
            if notification_type not in NOTIFICATION_TYPES:
                raise ValueError(f"unsupported notification type: {notification_type!r}")
            notification_id = str(uuid.uuid4())
            created = self.store.create_notification({"id": notification_id, "type": notification_type, "title": str(action["title"]), "body": str(action.get("body", "")), "entity_id": event.entity_id, "source_event_id": event.id, "source_rule_id": action.get("rule_id"), "priority": str(action.get("priority", "normal")), "dedupe_key": action.get("dedupe_key"), "actions_json": json.dumps(action.get("actions", [])), "created_at": now, "expires_at": action.get("expires_at")})
            if created:
                self.store.record_event(WorkspaceEvent(type=EventTypes.NOTIFICATION_CREATED, entity_id=event.entity_id, payload={"notification_id": notification_id}, source="action", causation_id=event.id))
            return created
        if action_type == "route_message":
            destination = str(action["destination"])
            if not destination or ":" not in destination:
                raise ValueError("route_message destination must use a typed target such as project:name")
            message_id = str(uuid.uuid4())
            self.store.queue_message({"id": message_id, "destination": destination, "type": str(action.get("message_type", "workspace.event")), "entity_id": event.entity_id, "source_event_id": event.id, "payload_json": json.dumps(action.get("payload", {}), sort_keys=True), "created_at": now})
            self.store.record_event(WorkspaceEvent(type=EventTypes.MESSAGE_QUEUED, entity_id=event.entity_id, payload={"message_id": message_id, "destination": action["destination"]}, source="action", causation_id=event.id)); return True
        # These are intentionally stateful requests, not shell execution.
        self.store.record_event(WorkspaceEvent(type=f"action.{action_type}", entity_id=event.entity_id, payload=action, source="action", causation_id=event.id)); return True
