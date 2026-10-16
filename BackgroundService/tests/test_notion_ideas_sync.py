"""IdeasNotionSync's schema-mapping, stable-id dedup, and conflict-safety
logic, using the real `notion_api.SchemaMap`/`property_value`
with a fake NotionClient standing in for the network boundary -- same
approach as tests/test_notion_work_log_sync.py, applied to the Ideas
database. Skips cleanly if the sibling checkout isn't present."""

from __future__ import annotations

import json
import sys
from pathlib import Path

import pytest

from workspace_watcher.core_config import NotionSettings
from workspace_watcher.core_store import CoreStore
from workspace_watcher.private_items import load_record, save_record
from workspace_watcher.item_records import initialize_idea_record, item_metadata_path
from workspace_watcher.notion_ideas_v2 import LOCAL_ID_PROPERTY, IdeasNotionSync


SCHEMA_SOURCE = {
    "properties": {
        "idea": {"type": "title"},
        "one liner": {"type": "rich_text"},
        "capture notes": {"type": "rich_text"},
        "bullet points": {"type": "rich_text"},
        "type": {"type": "select"},
        "status": {"type": "select"},
        "impact": {"type": "select"},
        "tags": {"type": "multi_select"},
        "potential domain": {"type": "multi_select"},
        "tools / technologies": {"type": "multi_select"},
        "confidence": {"type": "number"},
        "effort": {"type": "select"},
        "keep suggesting": {"type": "checkbox"},
        "defer until": {"type": "date"},
        "projects": {"type": "relation"},
        "potential projects": {"type": "relation"},
        "exclude projects": {"type": "relation"},
    }
}


class FakeClient:
    def __init__(self, schema_source: dict, *, existing_pages: list[dict] | None = None) -> None:
        self.schema_source = {"properties": dict(schema_source["properties"])}
        self.created: list[tuple[str, dict]] = []
        self.updated: list[tuple[str, dict]] = []
        self.queries: list[dict] = []
        self.pages: dict[str, dict] = {}
        self._existing_pages = existing_pages or []

    def data_source_id(self, database_or_source_id: str) -> str:
        return "source-1"

    def data_source(self, source_id: str) -> dict:
        return self.schema_source

    def update_data_source(self, source_id: str, properties: dict) -> dict:
        self.schema_source["properties"].update({name: {"type": list(config.keys())[0]} for name, config in properties.items()})
        return self.schema_source

    def query(self, source_id: str, *, filter_payload: dict | None = None, sorts=None, limit: int = 200) -> list[dict]:
        self.queries.append(filter_payload or {})
        if not filter_payload:
            return list(self._existing_pages)
        wanted = (filter_payload.get("rich_text") or {}).get("equals")
        return [page for page in self._existing_pages if page.get("_local_id") == wanted]

    def page(self, page_id: str) -> dict:
        return self.pages.get(page_id, {"id": page_id, "last_edited_time": "2026-01-01T00:00:00.000Z"})

    def create_page(self, source_id: str, properties: dict, **_kwargs) -> dict:
        page = {"id": f"page-{len(self.created) + 1}", "last_edited_time": "2026-01-01T00:00:00.000Z"}
        self.created.append((source_id, properties))
        self.pages[page["id"]] = page
        return page

    def update_page(self, page_id: str, properties: dict) -> dict:
        self.updated.append((page_id, properties))
        page = {"id": page_id, "last_edited_time": "2026-01-02T00:00:00.000Z"}
        self.pages[page_id] = page
        return page


class FakeAdapter:
    def __init__(self, client: FakeClient) -> None:
        self._client_obj = client

    def _client(self) -> FakeClient:
        return self._client_obj


def _idea(tmp_path: Path, **overrides) -> Path:
    directory = tmp_path / overrides.pop("dirname", "My Idea")
    record = initialize_idea_record(directory, title=overrides.pop("title", "My Idea"))
    if overrides:
        from dataclasses import replace
        from workspace_watcher.item_records import save_item_record
        save_item_record(item_metadata_path(directory), replace(record, **overrides))
    return directory


def test_sync_item_creates_a_new_page_with_the_local_id_stamped(tmp_path):
    with CoreStore(tmp_path / "core.db") as store:
        directory = _idea(tmp_path, tags=("ai", "automation"), one_liner="A neat idea", impact="High")
        client = FakeClient(SCHEMA_SOURCE)
        sync = IdeasNotionSync(store, tmp_path, NotionSettings(enabled=True), adapter=FakeAdapter(client))
        item_row = {"id": "will-be-overwritten"}  # sync_item reads the id from the sidecar itself
        result = sync.sync_item(item_row, directory, "2026-01-01T00:00:00+00:00")
        assert result["action"] == "created"
        assert len(client.created) == 1
        _source_id, properties = client.created[0]
        assert properties["tags"] == {"multi_select": [{"name": "ai"}, {"name": "automation"}]}
        assert properties["impact"] == {"select": {"name": "High"}}
        assert LOCAL_ID_PROPERTY in client.schema_source["properties"]
        assert properties[LOCAL_ID_PROPERTY]["rich_text"][0]["text"]["content"]
        link = store.idea_notion_link(result["item_id"])
        assert link is not None and link["notion_page_id"] == "page-1"


def test_sync_item_is_idempotent_when_nothing_changed(tmp_path):
    with CoreStore(tmp_path / "core.db") as store:
        directory = _idea(tmp_path, tags=("ai",))
        client = FakeClient(SCHEMA_SOURCE)
        sync = IdeasNotionSync(store, tmp_path, NotionSettings(enabled=True), adapter=FakeAdapter(client))
        first = sync.sync_item({}, directory, "2026-01-01T00:00:00+00:00")
        second = sync.sync_item({}, directory, "2026-01-01T01:00:00+00:00")
        assert first["action"] == "created"
        assert second["action"] == "unchanged"
        assert len(client.created) == 1 and client.updated == []


def test_sync_item_pushes_an_update_when_the_local_record_changes(tmp_path):
    with CoreStore(tmp_path / "core.db") as store:
        directory = _idea(tmp_path, tags=("ai",))
        client = FakeClient(SCHEMA_SOURCE)
        sync = IdeasNotionSync(store, tmp_path, NotionSettings(enabled=True), adapter=FakeAdapter(client))
        sync.sync_item({}, directory, "2026-01-01T00:00:00+00:00")
        from dataclasses import replace
        record = load_record(store, directory)
        save_record(store, directory, replace(record, tags=("ai", "new-tag")))
        result = sync.sync_item({}, directory, "2026-01-01T00:05:00+00:00")
        assert result["action"] == "updated"
        assert len(client.updated) == 1


def test_sync_item_populates_the_projects_relation_when_a_notion_mapping_exists(tmp_path):
    with CoreStore(tmp_path / "core.db") as store:
        store.create_project(project_id="p1", path="Projects/Workspace Watcher", root_path="Projects", name="Workspace Watcher", device=None, inode=None, timestamp="2026-01-01T00:00:00+00:00")
        store.replace_notion_project_cache([{"notion_project_id": "notion-page-ww", "project_id": "p1", "name": "Workspace Watcher", "local_directory": None, "metadata": {}}], "2026-01-01T00:00:00+00:00")
        directory = _idea(tmp_path, related_projects=("Workspace Watcher",), potential_projects=("Workspace Watcher",))
        client = FakeClient(SCHEMA_SOURCE)
        sync = IdeasNotionSync(store, tmp_path, NotionSettings(enabled=True), adapter=FakeAdapter(client))
        sync.sync_item({}, directory, "2026-01-01T00:00:00+00:00")
        _source_id, properties = client.created[0]
        assert properties["projects"] == {"relation": [{"id": "notion-page-ww"}]}
        assert properties["potential projects"] == {"relation": [{"id": "notion-page-ww"}]}


def test_sync_item_omits_the_relation_when_no_notion_mapping_exists_yet(tmp_path):
    """No cached Notion project mapping for "Some Project" -- the
    association stays valid locally (via `relationships`) and simply isn't
    pushed yet, rather than erroring or guessing an id."""
    with CoreStore(tmp_path / "core.db") as store:
        directory = _idea(tmp_path, related_projects=("Some Project",))
        client = FakeClient(SCHEMA_SOURCE)
        sync = IdeasNotionSync(store, tmp_path, NotionSettings(enabled=True), adapter=FakeAdapter(client))
        sync.sync_item({}, directory, "2026-01-01T00:00:00+00:00")
        _source_id, properties = client.created[0]
        assert "projects" not in properties


def test_sync_item_finds_an_existing_page_by_local_id_instead_of_duplicating(tmp_path):
    with CoreStore(tmp_path / "core.db") as store:
        directory = _idea(tmp_path)
        item_id = load_record(store, directory).id
        client = FakeClient(SCHEMA_SOURCE, existing_pages=[{"id": "page-from-before-the-crash", "_local_id": item_id}])
        sync = IdeasNotionSync(store, tmp_path, NotionSettings(enabled=True), adapter=FakeAdapter(client))
        result = sync.sync_item({}, directory, "2026-01-01T00:00:00+00:00")
        assert result["action"] == "updated"
        assert client.created == []
        assert len(client.updated) == 1 and client.updated[0][0] == "page-from-before-the-crash"


def test_sync_item_pulls_a_notion_only_change_into_the_local_sidecar(tmp_path):
    """Only Notion changed since the last sync (a person edited the page
    directly) -- this must pull down to local, not just report "unchanged"."""
    with CoreStore(tmp_path / "core.db") as store:
        directory = _idea(tmp_path, tags=("ai",), status="raw")
        client = FakeClient(SCHEMA_SOURCE)
        sync = IdeasNotionSync(store, tmp_path, NotionSettings(enabled=True), adapter=FakeAdapter(client))
        first = sync.sync_item({}, directory, "2026-01-01T00:00:00+00:00")
        page_id = first["notion_page_id"]

        # Simulate a real edit made directly in Notion: change status and
        # bump last_edited_time, with nothing changing locally.
        client.pages[page_id] = {
            "id": page_id, "last_edited_time": "2026-01-03T00:00:00.000Z",
            "properties": {"status": {"type": "select", "select": {"name": "Exploring"}}},
        }

        result = sync.sync_item({}, directory, "2026-01-02T00:00:00+00:00")
        assert result["action"] == "pulled"
        record = load_record(store, directory)
        assert record.status == "exploring"

        # And it's now stable -- the next sync sees nothing further to do.
        again = sync.sync_item({}, directory, "2026-01-02T00:05:00+00:00")
        assert again["action"] == "unchanged"


def test_sync_item_raises_a_conflict_notification_instead_of_overwriting(tmp_path):
    with CoreStore(tmp_path / "core.db") as store:
        directory = _idea(tmp_path, tags=("ai",))
        client = FakeClient(SCHEMA_SOURCE)
        sync = IdeasNotionSync(store, tmp_path, NotionSettings(enabled=True), adapter=FakeAdapter(client))
        first = sync.sync_item({}, directory, "2026-01-01T00:00:00+00:00")
        page_id = first["notion_page_id"]
        # Notion side changes (simulated by a later last_edited_time)...
        client.pages[page_id] = {"id": page_id, "last_edited_time": "2026-01-03T00:00:00.000Z"}
        # ...and the local side changes too, since the last successful sync.
        from dataclasses import replace
        record = load_record(store, directory)
        save_record(store, directory, replace(record, tags=("ai", "diverged-locally")))
        result = sync.sync_item({}, directory, "2026-01-02T00:00:00+00:00")
        assert result["action"] == "conflict"
        assert client.updated == [], "must never silently overwrite a two-sided change"
        notifications = store.notifications()
        assert any(row["type"] == "idea_sync_conflict" for row in notifications)


def test_push_maps_local_status_and_type_onto_the_existing_notion_option_casing(tmp_path):
    """Local uses lowercase_with_underscores; Notion's real options are
    Title Case With Spaces. Pushing must land on the *existing* option
    (e.g. "To Implement") rather than creating a near-duplicate
    ("to_implement") the first time this runs."""
    with CoreStore(tmp_path / "core.db") as store:
        directory = _idea(tmp_path, type="feature", status="to_implement")
        client = FakeClient(SCHEMA_SOURCE)
        sync = IdeasNotionSync(store, tmp_path, NotionSettings(enabled=True), adapter=FakeAdapter(client))
        sync.sync_item({}, directory, "2026-01-01T00:00:00+00:00")
        _source_id, properties = client.created[0]
        assert properties["type"] == {"select": {"name": "Feature"}}
        assert properties["status"] == {"select": {"name": "To Implement"}}


def test_push_never_writes_a_type_for_the_unclassified_default(tmp_path):
    with CoreStore(tmp_path / "core.db") as store:
        directory = _idea(tmp_path, tags=("ai",))  # type stays "unclassified"
        client = FakeClient(SCHEMA_SOURCE)
        sync = IdeasNotionSync(store, tmp_path, NotionSettings(enabled=True), adapter=FakeAdapter(client))
        sync.sync_item({}, directory, "2026-01-01T00:00:00+00:00")
        _source_id, properties = client.created[0]
        assert "type" not in properties


def test_pull_normalizes_notion_status_and_type_casing_to_the_local_convention(tmp_path):
    with CoreStore(tmp_path / "core.db") as store:
        ideas_folder = tmp_path / "[[Ideas]]"
        ideas_folder.mkdir()
        page = {
            "id": "notion-page-casing",
            "properties": {
                "idea": {"type": "title", "title": [{"type": "text", "text": {"content": "Casing Test"}, "plain_text": "Casing Test"}]},
                "type": {"type": "select", "select": {"name": "Feature"}},
                "status": {"type": "select", "select": {"name": "To Implement"}},
            },
        }
        client = FakeClient(SCHEMA_SOURCE, existing_pages=[page])
        sync = IdeasNotionSync(store, tmp_path, NotionSettings(enabled=True), adapter=FakeAdapter(client))
        results = sync.pull_new_ideas(ideas_folder, "2026-01-01T00:00:00+00:00")
        record = load_record(store, Path(results[0]["directory"]))
        assert record.type == "feature"
        assert record.status == "to_implement"


def test_pull_then_sync_is_immediately_idempotent_no_wasted_round_trip(tmp_path):
    with CoreStore(tmp_path / "core.db") as store:
        ideas_folder = tmp_path / "[[Ideas]]"
        ideas_folder.mkdir()
        page = {
            "id": "notion-page-stable",
            "properties": {"idea": {"type": "title", "title": [{"type": "text", "text": {"content": "Stable"}, "plain_text": "Stable"}]}},
        }
        client = FakeClient(SCHEMA_SOURCE, existing_pages=[page])
        sync = IdeasNotionSync(store, tmp_path, NotionSettings(enabled=True), adapter=FakeAdapter(client))
        results = sync.pull_new_ideas(ideas_folder, "2026-01-01T00:00:00+00:00")
        directory = Path(results[0]["directory"])
        result = sync.sync_item({}, directory, "2026-01-01T00:01:00+00:00")
        assert result["action"] == "unchanged"
        assert client.created == [] and client.updated == []


def test_resolve_conflict_keep_local_pushes_and_clears_the_stuck_state(tmp_path):
    with CoreStore(tmp_path / "core.db") as store:
        directory = _idea(tmp_path, tags=("ai",))
        client = FakeClient(SCHEMA_SOURCE)
        sync = IdeasNotionSync(store, tmp_path, NotionSettings(enabled=True), adapter=FakeAdapter(client))
        first = sync.sync_item({}, directory, "2026-01-01T00:00:00+00:00")
        page_id = first["notion_page_id"]

        from dataclasses import replace
        save_record(store, directory, replace(load_record(store, directory), tags=("ai", "local-wins")))
        client.pages[page_id] = {"id": page_id, "last_edited_time": "2026-01-03T00:00:00.000Z", "properties": {}}
        assert sync.sync_item({}, directory, "2026-01-02T00:00:00+00:00")["action"] == "conflict"

        result = sync.resolve_conflict(directory, "keep_local", "2026-01-04T00:00:00+00:00")
        assert result["action"] == "kept_local"
        _source_id, pushed = client.updated[-1]
        assert pushed["tags"] == {"multi_select": [{"name": "ai"}, {"name": "local-wins"}]}
        # And it's genuinely resolved -- the next ordinary sync is a no-op.
        assert sync.sync_item({}, directory, "2026-01-04T00:01:00+00:00")["action"] == "unchanged"


def test_resolve_conflict_keep_notion_pulls_and_clears_the_stuck_state(tmp_path):
    with CoreStore(tmp_path / "core.db") as store:
        directory = _idea(tmp_path, tags=("ai",), status="raw")
        client = FakeClient(SCHEMA_SOURCE)
        sync = IdeasNotionSync(store, tmp_path, NotionSettings(enabled=True), adapter=FakeAdapter(client))
        first = sync.sync_item({}, directory, "2026-01-01T00:00:00+00:00")
        page_id = first["notion_page_id"]

        from dataclasses import replace
        save_record(store, directory, replace(load_record(store, directory), status="exploring"))
        client.pages[page_id] = {"id": page_id, "last_edited_time": "2026-01-03T00:00:00.000Z", "properties": {"status": {"type": "select", "select": {"name": "Plan"}}}}
        assert sync.sync_item({}, directory, "2026-01-02T00:00:00+00:00")["action"] == "conflict"

        result = sync.resolve_conflict(directory, "keep_notion", "2026-01-04T00:00:00+00:00")
        assert result["action"] == "kept_notion"
        assert load_record(store, directory).status == "plan"
        assert sync.sync_item({}, directory, "2026-01-04T00:01:00+00:00")["action"] == "unchanged"


def test_resolve_conflict_rejects_an_unknown_resolution(tmp_path):
    with CoreStore(tmp_path / "core.db") as store:
        directory = _idea(tmp_path)
        client = FakeClient(SCHEMA_SOURCE)
        sync = IdeasNotionSync(store, tmp_path, NotionSettings(enabled=True), adapter=FakeAdapter(client))
        sync.sync_item({}, directory, "2026-01-01T00:00:00+00:00")
        try:
            sync.resolve_conflict(directory, "keep_both", "2026-01-01T00:00:00+00:00")
            assert False, "expected a ValueError"
        except ValueError:
            pass


def test_pull_new_ideas_creates_a_local_idea_for_an_unlinked_notion_page(tmp_path):
    with CoreStore(tmp_path / "core.db") as store:
        ideas_folder = tmp_path / "[[Ideas]]"
        ideas_folder.mkdir()
        page = {
            "id": "notion-only-page",
            "properties": {
                "idea": {"type": "title", "title": [{"type": "text", "text": {"content": "Notion-authored idea"}, "plain_text": "Notion-authored idea"}]},
                "one liner": {"type": "rich_text", "rich_text": [{"type": "text", "text": {"content": "Came from Notion"}, "plain_text": "Came from Notion"}]},
                "type": {"type": "select", "select": {"name": "story"}},
            },
        }
        client = FakeClient(SCHEMA_SOURCE, existing_pages=[page])
        sync = IdeasNotionSync(store, tmp_path, NotionSettings(enabled=True), adapter=FakeAdapter(client))
        results = sync.pull_new_ideas(ideas_folder, "2026-01-01T00:00:00+00:00")
        assert len(results) == 1
        assert results[0]["title"] == "Notion-authored idea"
        directory = Path(results[0]["directory"])
        assert directory.exists()
        record = load_record(store, directory)
        assert record.one_liner == "Came from Notion"
        assert record.type == "story"
        link = store.idea_notion_link(record.id)
        assert link is not None and link["notion_page_id"] == "notion-only-page"


def test_pull_new_ideas_skips_pages_already_linked_locally(tmp_path):
    with CoreStore(tmp_path / "core.db") as store:
        ideas_folder = tmp_path / "[[Ideas]]"
        ideas_folder.mkdir()
        directory = _idea(tmp_path / "existing")
        item_id = load_record(store, directory).id
        store.upsert_idea_notion_link(item_id, notion_page_id="already-linked-page", synced_hash="x", notion_last_edited_time=None, sync_error=None, timestamp="2026-01-01T00:00:00+00:00")
        page = {"id": "already-linked-page", "properties": {"idea": {"type": "title", "title": [{"type": "text", "text": {"content": "X"}, "plain_text": "X"}]}}}
        client = FakeClient(SCHEMA_SOURCE, existing_pages=[page])
        sync = IdeasNotionSync(store, tmp_path, NotionSettings(enabled=True), adapter=FakeAdapter(client))
        results = sync.pull_new_ideas(ideas_folder, "2026-01-01T00:00:00+00:00")
        assert results == []
