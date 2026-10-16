"""Bounded local delivery for persisted notifications and routed messages."""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
from typing import Callable

from .core_events import WorkspaceEvent
from .core_store import CoreStore
from .notifications import notify


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def _retry_at(now: str, attempts: int) -> str:
    # 10s, 20s, 40s, 80s, then give up. The service stays deterministic when
    # callers supply a clock, and no permanently invalid record loops forever.
    delay = min(80, 10 * (2 ** max(0, attempts - 1)))
    return (datetime.fromisoformat(now) + timedelta(seconds=delay)).isoformat()


class NotificationDeliveryService:
    def __init__(self, store: CoreStore, deliver: Callable[[str, str], None] = notify, *, max_attempts: int = 5) -> None:
        self.store, self.deliver, self.max_attempts = store, deliver, max_attempts

    def tick(self, now: str | None = None) -> dict[str, int]:
        current, delivered, failed = now or now_iso(), 0, 0
        expired = self.store.expire_notifications(current)
        for row in self.store.notifications_due_for_delivery(current):
            if int(row["attempt_count"]) >= self.max_attempts:
                self.store.update_notification_delivery(row["id"], state="failed_permanent", now=current, error="retry limit reached")
                failed += 1
                continue
            try:
                self.deliver(str(row["title"]), str(row["body"]))
            except Exception as error:  # delivery is an optional boundary
                self.store.update_notification_delivery(row["id"], state="failed", now=current, error=str(error), next_attempt_at=_retry_at(current, int(row["attempt_count"]) + 1))
                failed += 1
            else:
                self.store.update_notification_delivery(row["id"], state="delivered", now=current)
                self.store.record_event(WorkspaceEvent(type="notification.delivered", entity_id=row["entity_id"], payload={"notification_id": row["id"]}, source="delivery"))
                delivered += 1
        return {"delivered": delivered, "failed": failed, "expired": expired}


class MessageDeliveryService:
    """A local transport boundary; future project clients can replace ``send``."""

    def __init__(self, store: CoreStore, send: Callable[[str, str], None] | None = None, *, max_attempts: int = 5) -> None:
        self.store, self.send, self.max_attempts = store, send or self._local_accept, max_attempts

    @staticmethod
    def _local_accept(destination: str, _: str) -> None:
        if ":" not in destination or not destination.split(":", 1)[1].strip():
            raise ValueError("message destination is invalid")

    def tick(self, now: str | None = None) -> dict[str, int]:
        current, delivered, failed = now or now_iso(), 0, 0
        for row in self.store.messages_due_for_delivery(current):
            if int(row["attempt_count"]) >= self.max_attempts:
                self.store.update_message_delivery(row["id"], state="failed_permanent", now=current, error="retry limit reached")
                failed += 1
                continue
            try:
                self.send(str(row["destination"]), str(row["payload_json"]))
            except Exception as error:
                self.store.update_message_delivery(row["id"], state="failed", now=current, error=str(error), next_attempt_at=_retry_at(current, int(row["attempt_count"]) + 1))
                failed += 1
            else:
                self.store.update_message_delivery(row["id"], state="delivered", now=current)
                self.store.record_event(WorkspaceEvent(type="message.delivered", entity_id=row["entity_id"], payload={"message_id": row["id"], "destination": row["destination"]}, source="delivery"))
                delivered += 1
        return {"delivered": delivered, "failed": failed}
