"""NotionWorkLogSync's actual schema-mapping logic, using the real
`notion_api.SchemaMap`/`property_value` (pure, offline -- no
network) with a fake NotionClient standing in for the network boundary, so
this proves genuine integration with the reused sibling package without
ever touching real Notion. Skips cleanly if the sibling checkout isn't
present in this environment (same pattern as
the service's own `notion_api` client)."""

from __future__ import annotations

import json
import sys
from pathlib import Path

import pytest

from workspace_watcher.core_config import NotionSettings
from workspace_watcher.core_store import CoreStore
from workspace_watcher.work_logs_v2 import NotionWorkLogSync


SCHEMA_SOURCE = {
    "properties": {
        "Name": {"type": "title"},
        "Session Start": {"type": "date"},
        "Session End": {"type": "date"},
        "Date": {"type": "date"},
        "What Happened": {"type": "rich_text"},
        "Progress Summary": {"type": "rich_text"},
        "Event Hash": {"type": "rich_text"},
        "Active Seconds": {"type": "number"},
        "Sessions Count": {"type": "number"},
        "Project": {"type": "relation"},
    }
}


class FakeClient:
    def __init__(self, schema_source: dict, *, existing_pages: list[dict] | None = None) -> None:
        self.schema_source = schema_source
        self.created: list[tuple[str, dict]] = []
        self.updated: list[tuple[str, dict]] = []
        self.queries: list[dict] = []
        self._existing_pages = existing_pages or []

    def data_source_id(self, database_or_source_id: str) -> str:
        return "source-1"

    def data_source(self, source_id: str) -> dict:
        return self.schema_source

    def query(self, source_id: str, *, filter_payload: dict | None = None, sorts=None, limit: int = 200) -> list[dict]:
        self.queries.append(filter_payload or {})
        if not filter_payload:
            return list(self._existing_pages)
        prop = filter_payload.get("property")
        wanted = (filter_payload.get("rich_text") or {}).get("equals")
        return [page for page in self._existing_pages if page.get("_event_hash") == wanted] if prop else list(self._existing_pages)

    def create_page(self, source_id: str, properties: dict, **_kwargs) -> dict:
        page = {"id": f"page-{len(self.created) + 1}"}
        self.created.append((source_id, properties))
        return page

    def update_page(self, page_id: str, properties: dict) -> dict:
        self.updated.append((page_id, properties))
        return {"id": page_id}


class FakeAdapter:
    def __init__(self, client: FakeClient) -> None:
        self._client_obj = client

    def _client(self) -> FakeClient:
        return self._client_obj


def _draft(*, notion_page_id: str | None = None, project_id: str = "p1") -> dict:
    payload = {
        "start": "2026-01-01T10:00:00+00:00", "end": "2026-01-01T10:30:00+00:00", "date": "2026-01-01",
        "summary": "3 meaningful changes across 2 file(s).", "active_minutes": 10.0, "session_count": 1,
    }
    return {
        "id": "worklog-abc123", "project_id": project_id, "project_name": "Demo",
        "payload_json": json.dumps(payload), "notion_page_id": notion_page_id,
    }


def test_sync_creates_a_new_page_with_mapped_fields(tmp_path):
    with CoreStore(tmp_path / "core.db") as store:
        client = FakeClient(SCHEMA_SOURCE)
        sync = NotionWorkLogSync(store, tmp_path, NotionSettings(enabled=True), adapter=FakeAdapter(client))
        page_id = sync.sync(_draft())
        assert page_id == "page-1"
        assert len(client.created) == 1 and client.updated == []
        _source_id, properties = client.created[0]
        assert "Name" in properties
        assert properties["Event Hash"] == {"rich_text": [{"type": "text", "text": {"content": "worklog-abc123"}}]}
        assert properties["Active Seconds"] == {"number": 600}
        assert properties["Sessions Count"] == {"number": 1}
        assert "Project" not in properties  # no notion_project_cache mapping yet -- gracefully omitted


def test_sync_updates_the_existing_page_when_one_is_already_known(tmp_path):
    with CoreStore(tmp_path / "core.db") as store:
        client = FakeClient(SCHEMA_SOURCE)
        sync = NotionWorkLogSync(store, tmp_path, NotionSettings(enabled=True), adapter=FakeAdapter(client))
        page_id = sync.sync(_draft(notion_page_id="page-existing"))
        assert page_id == "page-existing"
        assert client.created == [] and len(client.updated) == 1
        assert client.updated[0][0] == "page-existing"


def test_sync_includes_the_project_relation_when_a_mapping_exists(tmp_path):
    with CoreStore(tmp_path / "core.db") as store:
        store.replace_notion_project_cache([{"notion_project_id": "notion-page-xyz", "project_id": "p1", "name": "Demo", "local_directory": None, "metadata": {}}], "2026-01-01T00:00:00+00:00")
        client = FakeClient(SCHEMA_SOURCE)
        sync = NotionWorkLogSync(store, tmp_path, NotionSettings(enabled=True), adapter=FakeAdapter(client))
        sync.sync(_draft())
        _source_id, properties = client.created[0]
        assert properties["Project"] == {"relation": [{"id": "notion-page-xyz"}]}


def test_preview_shows_the_same_properties_but_never_calls_create_or_update(tmp_path):
    with CoreStore(tmp_path / "core.db") as store:
        client = FakeClient(SCHEMA_SOURCE)
        sync = NotionWorkLogSync(store, tmp_path, NotionSettings(enabled=True), adapter=FakeAdapter(client))
        preview = sync.preview(_draft())
        assert preview["action"] == "create"
        assert "Event Hash" in preview["properties"]
        assert client.created == [] and client.updated == []  # the whole point of a dry run


def test_sync_finds_an_existing_page_by_event_hash_instead_of_duplicating(tmp_path):
    # Simulates the crash window: create_page succeeded on a previous run,
    # but the process died before notion_page_id was ever saved locally --
    # draft["notion_page_id"] is empty even though a real page exists.
    with CoreStore(tmp_path / "core.db") as store:
        client = FakeClient(SCHEMA_SOURCE, existing_pages=[{"id": "page-from-before-the-crash", "_event_hash": "worklog-abc123"}])
        sync = NotionWorkLogSync(store, tmp_path, NotionSettings(enabled=True), adapter=FakeAdapter(client))
        page_id = sync.sync(_draft(notion_page_id=None))
        assert page_id == "page-from-before-the-crash"
        assert client.created == [], "must never create a second page when one is found by hash"
        assert len(client.updated) == 1 and client.updated[0][0] == "page-from-before-the-crash"
        assert len(client.queries) == 1  # confirms the safety-net lookup actually ran, not skipped


def test_sync_creates_normally_when_no_existing_page_is_found_by_hash(tmp_path):
    with CoreStore(tmp_path / "core.db") as store:
        client = FakeClient(SCHEMA_SOURCE, existing_pages=[])
        sync = NotionWorkLogSync(store, tmp_path, NotionSettings(enabled=True), adapter=FakeAdapter(client))
        page_id = sync.sync(_draft(notion_page_id=None))
        assert page_id == "page-1"
        assert len(client.created) == 1
        assert len(client.queries) == 1  # still checked first, just found nothing


def test_sync_skips_the_hash_lookup_entirely_when_a_page_id_is_already_known(tmp_path):
    with CoreStore(tmp_path / "core.db") as store:
        client = FakeClient(SCHEMA_SOURCE, existing_pages=[{"id": "some-other-page", "_event_hash": "worklog-abc123"}])
        sync = NotionWorkLogSync(store, tmp_path, NotionSettings(enabled=True), adapter=FakeAdapter(client))
        page_id = sync.sync(_draft(notion_page_id="page-existing"))
        assert page_id == "page-existing"
        assert client.queries == []  # already know the page -- no need to look it up
        assert len(client.updated) == 1 and client.updated[0][0] == "page-existing"


def test_sync_recreates_when_the_known_page_was_deleted_in_notion(tmp_path):
    class GonePageClient(FakeClient):
        def update_page(self, page_id, properties):
            if page_id == "page-deleted":
                raise RuntimeError("Notion HTTP 404: Could not find page with ID: page-deleted")
            return super().update_page(page_id, properties)

    with CoreStore(tmp_path / "core.db") as store:
        client = GonePageClient(SCHEMA_SOURCE)
        sync = NotionWorkLogSync(store, tmp_path, NotionSettings(enabled=True), adapter=FakeAdapter(client))
        page_id = sync.sync(_draft(notion_page_id="page-deleted"))
        assert page_id == "page-1"  # fell back to a fresh create
        assert len(client.created) == 1


def test_sync_reraises_a_non_404_update_failure(tmp_path):
    class FlakyClient(FakeClient):
        def update_page(self, page_id, properties):
            raise RuntimeError("Notion HTTP 503: Service Unavailable")

    with CoreStore(tmp_path / "core.db") as store:
        client = FlakyClient(SCHEMA_SOURCE)
        sync = NotionWorkLogSync(store, tmp_path, NotionSettings(enabled=True), adapter=FakeAdapter(client))
        try:
            sync.sync(_draft(notion_page_id="page-existing"))
            assert False, "expected the 503 to propagate, not be swallowed"
        except RuntimeError as error:
            assert "503" in str(error)
        assert client.created == []  # must not paper over a transient failure by silently creating a duplicate


def test_sync_falls_through_to_create_if_the_hash_lookup_itself_fails(tmp_path):
    class BrokenQueryClient(FakeClient):
        def query(self, *args, **kwargs):
            raise RuntimeError("Notion query endpoint unreachable")

    with CoreStore(tmp_path / "core.db") as store:
        client = BrokenQueryClient(SCHEMA_SOURCE)
        sync = NotionWorkLogSync(store, tmp_path, NotionSettings(enabled=True), adapter=FakeAdapter(client))
        page_id = sync.sync(_draft(notion_page_id=None))
        assert page_id == "page-1"  # the safety net's own failure never blocks a normal sync
        assert len(client.created) == 1
