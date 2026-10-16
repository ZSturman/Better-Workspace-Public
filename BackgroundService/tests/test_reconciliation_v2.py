"""Local-vs-Notion Work Log reconciliation: missing/orphan/duplicate/mismatch
detection, and the two safe (local-only, reversible) repair actions --
against a fake adapter/client, never touching real Notion."""

from __future__ import annotations

import sys
from pathlib import Path

import pytest


from workspace_watcher.core_config import NotionSettings
from workspace_watcher.core_store import CoreStore
from workspace_watcher.reconciliation_v2 import reconcile_work_logs, repair_local_state
from workspace_watcher.work_logs_v2 import NotionWorkLogSync

SCHEMA_SOURCE = {"properties": {"Name": {"type": "title"}, "Event Hash": {"type": "rich_text"}}}


class FakeClient:
    def __init__(self, pages: list[dict] | None = None, *, query_error: Exception | None = None) -> None:
        self.pages = pages or []
        self.query_error = query_error

    def data_source_id(self, database_or_source_id: str) -> str:
        return "source-1"

    def data_source(self, source_id: str) -> dict:
        return SCHEMA_SOURCE

    def query(self, source_id: str, *, filter_payload=None, sorts=None, limit=200) -> list[dict]:
        if self.query_error:
            raise self.query_error
        return self.pages


class FakeAdapter:
    def __init__(self, client: FakeClient) -> None:
        self._client_obj = client

    def _client(self) -> FakeClient:
        return self._client_obj


def _hash_property(value: str) -> dict:
    return {"type": "rich_text", "rich_text": [{"plain_text": value}]}


def _page(page_id: str, event_hash: str) -> dict:
    return {"id": page_id, "properties": {"Event Hash": _hash_property(event_hash)}}


def _sync(client: FakeClient, tmp_path: Path, store: CoreStore) -> NotionWorkLogSync:
    return NotionWorkLogSync(store, tmp_path, NotionSettings(enabled=True), adapter=FakeAdapter(client))


def _seed_draft(store: CoreStore, draft_id: str, *, status: str, notion_page_id: str | None = None, project_id: str | None = None) -> None:
    store.upsert_work_log_draft({
        "id": draft_id, "project_id": project_id or draft_id, "project_name": "Demo", "date_key": "2026-01-01",
        "session_ids": [], "payload": {}, "status": status, "notion_page_id": notion_page_id, "sync_error": None,
        "created_at": "2026-01-01T00:00:00+00:00", "updated_at": "2026-01-01T00:00:00+00:00",
    })


def test_pending_and_failed_drafts_are_categorized(tmp_path):
    with CoreStore(tmp_path / "core.db") as store:
        _seed_draft(store, "worklog-a", status="prepared")
        _seed_draft(store, "worklog-b", status="sync_failed")
        client = FakeClient(pages=[])
        report = reconcile_work_logs(store, tmp_path, NotionSettings(enabled=True), sync=_sync(client, tmp_path, store))
        assert report["local_pending"] == ["worklog-a"]
        assert report["local_sync_failed"] == ["worklog-b"]


def test_synced_draft_missing_from_notion_is_flagged(tmp_path):
    with CoreStore(tmp_path / "core.db") as store:
        _seed_draft(store, "worklog-a", status="synced", notion_page_id="page-1")
        client = FakeClient(pages=[])  # Notion has nothing for this hash at all
        report = reconcile_work_logs(store, tmp_path, NotionSettings(enabled=True), sync=_sync(client, tmp_path, store))
        assert report["local_synced_missing_in_notion"] == ["worklog-a"]


def test_synced_draft_with_matching_page_is_clean(tmp_path):
    with CoreStore(tmp_path / "core.db") as store:
        _seed_draft(store, "worklog-a", status="synced", notion_page_id="page-1")
        client = FakeClient(pages=[_page("page-1", "worklog-a")])
        report = reconcile_work_logs(store, tmp_path, NotionSettings(enabled=True), sync=_sync(client, tmp_path, store))
        assert report["local_synced_missing_in_notion"] == []
        assert report["local_page_id_mismatch"] == []


def test_page_id_mismatch_is_detected(tmp_path):
    with CoreStore(tmp_path / "core.db") as store:
        _seed_draft(store, "worklog-a", status="synced", notion_page_id="page-OLD")
        client = FakeClient(pages=[_page("page-NEW", "worklog-a")])  # same hash, different real page id
        report = reconcile_work_logs(store, tmp_path, NotionSettings(enabled=True), sync=_sync(client, tmp_path, store))
        assert report["local_page_id_mismatch"] == [{"draft_id": "worklog-a", "local_page_id": "page-OLD", "notion_page_ids": ["page-NEW"]}]


def test_duplicate_notion_pages_for_the_same_hash_are_detected(tmp_path):
    with CoreStore(tmp_path / "core.db") as store:
        _seed_draft(store, "worklog-a", status="synced", notion_page_id="page-1")
        client = FakeClient(pages=[_page("page-1", "worklog-a"), _page("page-2", "worklog-a")])
        report = reconcile_work_logs(store, tmp_path, NotionSettings(enabled=True), sync=_sync(client, tmp_path, store))
        assert report["notion_duplicate_hashes"] == [{"event_hash": "worklog-a", "page_ids": ["page-1", "page-2"]}]


def test_orphan_notion_page_with_no_local_draft_is_detected(tmp_path):
    with CoreStore(tmp_path / "core.db") as store:
        client = FakeClient(pages=[_page("page-1", "worklog-ghost")])
        report = reconcile_work_logs(store, tmp_path, NotionSettings(enabled=True), sync=_sync(client, tmp_path, store))
        assert report["notion_orphan_pages"] == [{"event_hash": "worklog-ghost", "page_ids": ["page-1"]}]


def test_non_workspace_watcher_pages_are_ignored(tmp_path):
    with CoreStore(tmp_path / "core.db") as store:
        # A page whose event_hash doesn't start with "worklog-" belongs to a
        # different writer entirely (Hammerspoon/workspace_telemetry) --
        # reconciliation must not flag it as our orphan.
        client = FakeClient(pages=[_page("page-1", "work-session:some-other-system-id")])
        report = reconcile_work_logs(store, tmp_path, NotionSettings(enabled=True), sync=_sync(client, tmp_path, store))
        assert report["notion_orphan_pages"] == []
        assert report["notion_duplicate_hashes"] == []


def test_missing_event_hash_schema_field_is_reported_not_raised(tmp_path):
    class NoHashClient(FakeClient):
        def data_source(self, source_id):
            return {"properties": {"Name": {"type": "title"}}}

    with CoreStore(tmp_path / "core.db") as store:
        report = reconcile_work_logs(store, tmp_path, NotionSettings(enabled=True), sync=_sync(NoHashClient(), tmp_path, store))
        assert "event_hash" in report["error"]


def test_query_failure_is_reported_not_raised(tmp_path):
    with CoreStore(tmp_path / "core.db") as store:
        client = FakeClient(query_error=RuntimeError("Notion unreachable"))
        report = reconcile_work_logs(store, tmp_path, NotionSettings(enabled=True), sync=_sync(client, tmp_path, store))
        assert "Notion unreachable" in report["error"]


def test_repair_dry_run_reports_without_mutating_anything(tmp_path):
    with CoreStore(tmp_path / "core.db") as store:
        _seed_draft(store, "worklog-a", status="synced", notion_page_id="page-OLD")
        client = FakeClient(pages=[])
        report = reconcile_work_logs(store, tmp_path, NotionSettings(enabled=True), sync=_sync(client, tmp_path, store))
        outcome = repair_local_state(store, report, dry_run=True)
        assert outcome["dry_run"] is True
        assert len(outcome["actions"]) == 1
        assert store.get_work_log_draft("worklog-a")["status"] == "synced"  # unchanged


def test_repair_apply_resets_a_draft_missing_from_notion(tmp_path):
    with CoreStore(tmp_path / "core.db") as store:
        _seed_draft(store, "worklog-a", status="synced", notion_page_id="page-OLD")
        client = FakeClient(pages=[])
        report = reconcile_work_logs(store, tmp_path, NotionSettings(enabled=True), sync=_sync(client, tmp_path, store))
        repair_local_state(store, report, dry_run=False)
        row = store.get_work_log_draft("worklog-a")
        assert row["status"] == "prepared"
        assert row["notion_page_id"] is None  # actually cleared, not just left stale


def test_repair_apply_corrects_a_mismatched_page_id(tmp_path):
    with CoreStore(tmp_path / "core.db") as store:
        _seed_draft(store, "worklog-a", status="synced", notion_page_id="page-OLD")
        client = FakeClient(pages=[_page("page-NEW", "worklog-a")])
        report = reconcile_work_logs(store, tmp_path, NotionSettings(enabled=True), sync=_sync(client, tmp_path, store))
        repair_local_state(store, report, dry_run=False)
        row = store.get_work_log_draft("worklog-a")
        assert row["status"] == "synced"
        assert row["notion_page_id"] == "page-NEW"


def test_repair_never_touches_notion_itself(tmp_path):
    # The FakeClient here has no create_page/update_page at all -- if repair
    # ever tried to call either, this test would raise AttributeError.
    with CoreStore(tmp_path / "core.db") as store:
        _seed_draft(store, "worklog-a", status="synced", notion_page_id="page-OLD")
        client = FakeClient(pages=[_page("page-NEW", "worklog-a")])
        assert not hasattr(client, "create_page") and not hasattr(client, "update_page")
        report = reconcile_work_logs(store, tmp_path, NotionSettings(enabled=True), sync=_sync(client, tmp_path, store))
        repair_local_state(store, report, dry_run=False)  # must not raise
