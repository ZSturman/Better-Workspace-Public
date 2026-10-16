"""GO/NO-GO cutover preflight: v2's own operational readiness (schema
reachability + internal consistency via reconciliation_v2), not historical
import coverage. Against a fake adapter/client, never touching real Notion."""

from __future__ import annotations

import sys
from pathlib import Path

import pytest


from workspace_watcher.core_config import NotionSettings, WorkLogsSettings
from workspace_watcher.core_store import CoreStore
from workspace_watcher.cutover_preflight_v2 import cutover_preflight
from workspace_watcher.work_logs_v2 import NotionWorkLogSync, _draft_id

SCHEMA_SOURCE = {
    "properties": {
        "Name": {"type": "title"},
        "Date": {"type": "date"},
        "Project": {"type": "relation"},
        "What happened": {"type": "rich_text"},
        "Event Hash": {"type": "rich_text"},
    }
}


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


def _text(value: str) -> dict:
    return {"type": "rich_text", "rich_text": [{"plain_text": value}]}


def _page(page_id: str, event_hash: str) -> dict:
    return {"id": page_id, "properties": {"Event Hash": _text(event_hash)}}


def _sync(client: FakeClient, tmp_path: Path, store: CoreStore) -> NotionWorkLogSync:
    return NotionWorkLogSync(store, tmp_path, NotionSettings(enabled=True), adapter=FakeAdapter(client))


def _seed_draft(store: CoreStore, draft_id: str, *, status: str, notion_page_id: str | None = None) -> None:
    store.upsert_work_log_draft({
        "id": draft_id, "project_id": "proj-1", "project_name": "Demo", "date_key": "2026-01-01",
        "session_ids": [], "payload": {}, "status": status, "notion_page_id": notion_page_id, "sync_error": None,
        "created_at": "2026-01-01T00:00:00+00:00", "updated_at": "2026-01-01T00:00:00+00:00",
    })


def test_no_go_when_notion_is_off(tmp_path):
    with CoreStore(tmp_path / "core.db") as store:
        report = cutover_preflight(store, tmp_path, NotionSettings(enabled=False), WorkLogsSettings())
        assert report["go"] is False
        assert any("enabled is false" in b for b in report["blockers"])


def test_go_when_nothing_is_wrong(tmp_path):
    with CoreStore(tmp_path / "core.db") as store:
        client = FakeClient(pages=[])
        report = cutover_preflight(store, tmp_path, NotionSettings(enabled=True), WorkLogsSettings(), sync=_sync(client, tmp_path, store))
        assert report["go"] is True
        assert report["blockers"] == []


def test_no_go_when_schema_is_unreachable(tmp_path):
    with CoreStore(tmp_path / "core.db") as store:
        client = FakeClient(query_error=RuntimeError("Notion unreachable"))
        report = cutover_preflight(store, tmp_path, NotionSettings(enabled=True), WorkLogsSettings(), sync=_sync(client, tmp_path, store))
        assert report["go"] is False
        assert any("Notion unreachable" in b for b in report["blockers"])


def test_no_go_when_reconciliation_finds_a_page_id_mismatch(tmp_path):
    with CoreStore(tmp_path / "core.db") as store:
        draft_id = _draft_id("proj-1", "2026-01-01")
        _seed_draft(store, draft_id, status="synced", notion_page_id="page-OLD")
        client = FakeClient(pages=[_page("page-NEW", draft_id)])  # same hash, different real page id
        report = cutover_preflight(store, tmp_path, NotionSettings(enabled=True), WorkLogsSettings(), sync=_sync(client, tmp_path, store))
        assert report["go"] is False
        assert any("wrong Notion page id" in b for b in report["blockers"])


def test_no_go_when_a_synced_draft_is_missing_from_notion(tmp_path):
    with CoreStore(tmp_path / "core.db") as store:
        draft_id = _draft_id("proj-1", "2026-01-01")
        _seed_draft(store, draft_id, status="synced", notion_page_id="page-1")
        client = FakeClient(pages=[])
        report = cutover_preflight(store, tmp_path, NotionSettings(enabled=True), WorkLogsSettings(), sync=_sync(client, tmp_path, store))
        assert report["go"] is False
        assert any("no longer exists" in b for b in report["blockers"])


def test_orphan_pages_and_sync_failed_drafts_are_warnings_not_blockers(tmp_path):
    with CoreStore(tmp_path / "core.db") as store:
        draft_id = _draft_id("proj-1", "2026-01-01")
        _seed_draft(store, draft_id, status="sync_failed")
        client = FakeClient(pages=[_page("page-ghost", "worklog-orphan")])
        report = cutover_preflight(store, tmp_path, NotionSettings(enabled=True), WorkLogsSettings(), sync=_sync(client, tmp_path, store))
        assert report["go"] is True
        assert any("sync_failed" in w for w in report["warnings"])
        assert any("no matching local draft" in w for w in report["warnings"])


def test_already_flipped_settings_are_warnings_not_blockers(tmp_path):
    with CoreStore(tmp_path / "core.db") as store:
        client = FakeClient(pages=[])
        report = cutover_preflight(
            store, tmp_path, NotionSettings(enabled=True),
            WorkLogsSettings(notion_sync=True, authoritative_writer="v2"), sync=_sync(client, tmp_path, store),
        )
        assert report["go"] is True
        assert any("already true" in w for w in report["warnings"])
        assert any("already 'v2'" in w for w in report["warnings"])


def test_work_logs_disabled_is_a_blocker(tmp_path):
    with CoreStore(tmp_path / "core.db") as store:
        client = FakeClient(pages=[])
        report = cutover_preflight(store, tmp_path, NotionSettings(enabled=True), WorkLogsSettings(enabled=False), sync=_sync(client, tmp_path, store))
        assert report["go"] is False
        assert any("Work Log generation itself is off" in b for b in report["blockers"])
