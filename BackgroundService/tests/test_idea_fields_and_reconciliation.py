"""The Ideas-oriented ItemRecord fields (round-trip through the sidecar) and
IntentIndexer's tag/relationship reconciliation, which is what makes an
idea's tags/project associations comparable to a project's own tags and
queryable via the shared `relationships` table."""

from __future__ import annotations

from dataclasses import replace

from workspace_watcher.core_engine import IntentIndexer
from workspace_watcher.core_store import CoreStore
from workspace_watcher.private_items import save_record
from workspace_watcher.intents import IntentFolderDetector, IntentFolderSettings
from workspace_watcher.item_records import (
    SUGGESTED_IDEA_STATUSES, SUGGESTED_IDEA_TYPES, initialize_idea_record, item_metadata_path,
    parse_item_record, save_item_record,
)


def _indexer(store: CoreStore, tmp_path) -> IntentIndexer:
    return IntentIndexer(IntentFolderDetector(IntentFolderSettings(search_roots=(tmp_path,))), store)


def test_idea_fields_round_trip_through_the_sidecar(tmp_path):
    directory = tmp_path / "An Idea"
    record = initialize_idea_record(directory, title="An Idea")
    assert record.type == "unclassified"
    updated = replace(
        record, type="feature", status="exploring", one_liner="Short pitch", description="Longer capture notes.",
        notes="Running notes.", source="Overheard on a call", priority="high",
        tags=("ai", "developer tools"), domains=("technology",), tools=("python",), mediums=("blog post",),
        related_projects=("Workspace Watcher",), potential_projects=("Some Other Project",),
        excluded_projects=("Retired Project",), related_ideas=("11111111-1111-1111-1111-111111111111",),
        confidence=0.8, effort=5, impact="High", defer_until="2026-03-01",
    )
    save_item_record(item_metadata_path(directory), updated)
    reloaded = parse_item_record(item_metadata_path(directory))
    for field in (
        "type", "status", "one_liner", "description", "notes", "source", "priority", "tags", "domains", "tools",
        "mediums", "related_projects", "potential_projects", "excluded_projects", "related_ideas", "confidence",
        "effort", "impact",
    ):
        assert getattr(reloaded, field) == getattr(updated, field), field
    assert reloaded.defer_until == "2026-03-01"


def test_save_item_record_preserves_unknown_extra_fields(tmp_path):
    directory = tmp_path / "An Idea"
    record = initialize_idea_record(directory, title="An Idea")
    path = item_metadata_path(directory)
    # Inserted *before* the trailing [resurfacing] table -- a key appended
    # after it would parse as belonging to that table, not as a top-level
    # (and therefore "extra") key.
    before_resurfacing, _, after = path.read_text().partition("[resurfacing]")
    path.write_text(f'{before_resurfacing}custom_field = "keep me"\n\n[resurfacing]{after}')
    reloaded = parse_item_record(path)
    assert reloaded.extra.get("custom_field") == "keep me"
    save_item_record(path, replace(reloaded, one_liner="now with a one-liner"))
    final = parse_item_record(path)
    assert final.one_liner == "now with a one-liner"
    assert final.extra.get("custom_field") == "keep me"


def test_suggested_vocabularies_are_non_empty_and_include_unclassified():
    assert "unclassified" in SUGGESTED_IDEA_TYPES
    assert len(SUGGESTED_IDEA_TYPES) >= 5
    assert len(SUGGESTED_IDEA_STATUSES) >= 3


def test_reconcile_derives_canonical_tags_from_the_sidecar(tmp_path):
    ideas = tmp_path / "[[Ideas]]"
    ideas.mkdir()
    directory = ideas / "Tagged Idea"
    record = initialize_idea_record(directory, title="Tagged Idea")
    save_item_record(item_metadata_path(directory), replace(record, tags=("ai", "automation")))
    with CoreStore(tmp_path / "core.db") as store:
        _indexer(store, tmp_path).rebuild(initialize_missing_metadata=True)
        item = store.item_by_path(str(directory.resolve()))
        canonical = {row["display"] for row in store.tags_for_item(item["id"])}
        assert canonical == {"ai", "automation"}

        # Updating a private tag removes the metadata-provenance assignment...
        save_record(store, directory, replace(record, tags=("ai",)))
        _indexer(store, tmp_path).rebuild()
        canonical = {row["display"] for row in store.tags_for_item(item["id"])}
        assert canonical == {"ai"}

        # ...but a manually (user-provenance) assigned tag survives reconcile.
        manual = store.create_tag("manually-curated")
        store.assign_tag(item["id"], manual["id"], provenance="user")
        _indexer(store, tmp_path).rebuild()
        canonical = {row["display"] for row in store.tags_for_item(item["id"])}
        assert canonical == {"ai", "manually-curated"}


def test_reconcile_derives_relationships_from_project_names_and_self_heals(tmp_path):
    ideas = tmp_path / "[[Ideas]]"
    ideas.mkdir()
    directory = ideas / "Idea With Project"
    record = initialize_idea_record(directory, title="Idea With Project")
    save_item_record(item_metadata_path(directory), replace(
        record, related_projects=("Demo Project",), potential_projects=("Maybe Project",),
    ))
    with CoreStore(tmp_path / "core.db") as store:
        indexer = _indexer(store, tmp_path)
        indexer.rebuild(initialize_missing_metadata=True)
        item = store.item_by_path(str(directory.resolve()))
        assert store.relationships_for(item["id"]) == []  # no matching project yet -- still a valid standalone idea

        store.create_project(project_id="proj-1", path="Projects/Demo Project", root_path="Projects", name="Demo Project", device=None, inode=None, timestamp="2026-01-01T00:00:00+00:00")
        store.create_project(project_id="proj-2", path="Projects/Maybe Project", root_path="Projects", name="Maybe Project", device=None, inode=None, timestamp="2026-01-01T00:00:00+00:00")
        save_record(store, directory, replace(record, related_projects=("Demo Project",), potential_projects=("Maybe Project",), notes="touch to force a metadata change"))
        indexer.rebuild()

        relationships = {(row["type"], row["to_id"]) for row in store.relationships_for(item["id"])}
        assert ("related_to_project", "project:proj-1") in relationships
        assert ("potentially_related_to_project", "project:proj-2") in relationships

        # Withdrawing the association on disk withdraws the relationship too.
        save_record(store, directory, replace(record, related_projects=(), potential_projects=(), notes="withdraw"))
        indexer.rebuild()
        assert store.relationships_for(item["id"]) == []
