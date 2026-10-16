from __future__ import annotations

from pathlib import Path

from workspace_watcher.actions_v2 import ActionDispatcher
from workspace_watcher.core_engine import IntentIndexer
from workspace_watcher.core_events import EventTypes, WorkspaceEvent
from workspace_watcher.core_store import CoreStore
from workspace_watcher.intents import IntentFolderDetector, IntentFolderSettings
from workspace_watcher.item_records import initialize_item_record
from workspace_watcher.rules_v2 import Rule, RuleEvaluator


def test_move_between_intents_preserves_metadata_id_and_journals_change(tmp_path):
    inbox = tmp_path / "Temporary" / "[[Inbox]]" / "Thought"
    ideas = tmp_path / "Temporary" / "[[Ideas]]" / "Thought"
    inbox.mkdir(parents=True)
    ideas.parent.mkdir()
    record = initialize_item_record(inbox)
    with CoreStore(tmp_path / "core.db") as store:
        index = IntentIndexer(IntentFolderDetector(IntentFolderSettings.for_workspace(tmp_path)), store)
        assert index.rebuild()["items"] == 1
        inbox.rename(ideas)
        index.rebuild()
        item = store.item_by_path(str(ideas.resolve()))
        assert item and item["id"] == record.id
        assert any(row["type"] == EventTypes.INTENT_ITEM_INTENT_CHANGED for row in store.recent_events(20))


def test_rule_explanation_and_typed_actions_are_persisted(tmp_path):
    with CoreStore(tmp_path / "core.db") as store:
        event = WorkspaceEvent(type="project.activated", entity_id="project-1")
        store.record_event(event)
        rule = Rule("resurface", "project.activated", {"intent": "Ideas", "tags": ["dashboard"]})
        result = RuleEvaluator().evaluate_and_record(store, rule, event, {"intent": "Ideas", "tags": ["dashboard", "voice"]})
        assert result.passed and all(check["passed"] for check in result.checks)
        dispatcher = ActionDispatcher(store)
        assert dispatcher.dispatch({"type": "notification", "notification_type": "idea", "title": "Dashboard idea", "dedupe_key": "dashboard-1"}, event)
        assert not dispatcher.dispatch({"type": "notification", "notification_type": "idea", "title": "Duplicate", "dedupe_key": "dashboard-1"}, event)
        assert dispatcher.dispatch({"type": "route_message", "destination": "project:dashboard", "message_type": "intent_item.needs_testing"}, event)
