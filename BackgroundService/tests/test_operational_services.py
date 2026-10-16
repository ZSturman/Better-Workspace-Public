from __future__ import annotations

from datetime import datetime, timezone

from workspace_watcher.actions_v2 import ActionDispatcher
from workspace_watcher.core_events import WorkspaceEvent
from workspace_watcher.core_store import CoreStore
from workspace_watcher.delivery import MessageDeliveryService, NotificationDeliveryService
from workspace_watcher.resurfacing import ResurfacingService
from workspace_watcher.item_records import initialize_item_record, item_metadata_path, update_item_record


def test_notification_delivery_failure_retries_then_delivers(tmp_path):
    attempts: list[str] = []
    def flaky(title: str, _: str) -> None:
        attempts.append(title)
        if len(attempts) == 1: raise RuntimeError("temporarily unavailable")
    with CoreStore(tmp_path / "core.db") as store:
        event = WorkspaceEvent(type="item.created", entity_id="item")
        store.record_event(event)
        ActionDispatcher(store).dispatch({"type": "notification", "title": "Review", "dedupe_key": "review"}, event)
        service = NotificationDeliveryService(store, flaky)
        now = "2026-01-01T00:00:00+00:00"
        assert service.tick(now)["failed"] == 1
        assert store.notifications()[0]["state"] == "failed"
        assert service.tick("2026-01-01T00:00:10+00:00")["delivered"] == 1
        assert store.notifications()[0]["state"] == "delivered"


def test_message_delivery_retries_and_tag_relationship_mutations(tmp_path):
    calls = 0
    def flaky(_: str, __: str) -> None:
        nonlocal calls; calls += 1
        if calls == 1: raise RuntimeError("offline")
    with CoreStore(tmp_path / "core.db") as store:
        now = "2026-01-01T00:00:00+00:00"
        store.upsert_intent_folder(folder_id="folder", path="/folder", root_path="/", name="Ideas", config={}, timestamp=now)
        store.upsert_item(item_id="item", folder_id="folder", path="/folder/item", title="Item", item_type="item", status="active", metadata={}, device=None, inode=None, timestamp=now)
        event = WorkspaceEvent(type="item.created", entity_id="item")
        store.record_event(event)
        ActionDispatcher(store).dispatch({"type": "route_message", "destination": "project:demo"}, event)
        service = MessageDeliveryService(store, flaky)
        assert service.tick(now)["failed"] == 1
        assert service.tick("2026-01-01T00:00:10+00:00")["delivered"] == 1
        assert store.messages()[0]["state"] == "delivered"
        tag = store.create_tag("Dashboard Design")
        store.add_tag_alias(tag["id"], "dashboard-design")
        store.assign_tag("item", tag["id"])
        assert store.tags_for_item("item")[0]["display"] == "Dashboard Design"
        relationship = store.create_relationship("item", "project:demo", "related_to_project", now)
        assert store.relationships_for("project:demo")[0]["id"] == relationship
        assert store.remove_relationship(relationship)


def test_resurfacing_respects_deferral_and_cooldown(tmp_path):
    with CoreStore(tmp_path / "core.db") as store:
        now = "2026-01-01T00:00:00+00:00"
        store.upsert_intent_folder(folder_id="ideas", path="/ideas", root_path="/", name="Ideas", config={}, timestamp=now)
        # Backdated `created_at` (via the upsert timestamp) gives this item a
        # genuine "not reviewed in a while" signal -- resurfacing now
        # requires at least one real signal, not just any tag, to avoid
        # noisy suggestions (see resurfacing.MINIMUM_ELIGIBLE_SCORE).
        store.upsert_item(item_id="item", folder_id="ideas", path="/ideas/item", title="Item", item_type="item", status="active", metadata={"keep_suggesting": True, "tags": ["dashboard"]}, device=None, inode=None, timestamp="2025-11-01T00:00:00+00:00")
        service = ResurfacingService(store, ActionDispatcher(store), minimum_days=7)
        assert service.run(now)[0]["eligible"]
        assert not service.run("2026-01-02T00:00:00+00:00")[0]["eligible"]
        store.upsert_item(item_id="item", folder_id="ideas", path="/ideas/item", title="Item", item_type="item", status="active", metadata={"defer_until": "2026-02-01T00:00:00+00:00"}, device=None, inode=None, timestamp=now)
        assert not service.run("2026-01-10T00:00:00+00:00")[0]["eligible"]


def test_item_operational_updates_preserve_unknown_metadata(tmp_path):
    item = tmp_path / "item"; record = initialize_item_record(item)
    path = item_metadata_path(item)
    path.write_text(path.read_text() + "custom_value = \"preserve me\"\n")
    updated = update_item_record(path, status="archived", defer_until="2026-02-01T00:00:00+00:00")
    assert updated.status == "archived" and updated.defer_until == "2026-02-01T00:00:00+00:00"
    assert "custom_value = \"preserve me\"" in path.read_text()
