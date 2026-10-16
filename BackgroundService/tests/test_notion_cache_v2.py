"""v2's Notion Projects cache: local-project matching (path then name),
refresh timing, and graceful failure -- against a fake adapter, no network."""

from __future__ import annotations

from pathlib import Path

from workspace_watcher.core_config import NotionSettings
from workspace_watcher.core_store import CoreStore
from workspace_watcher.notion_client_v2 import NotionCacheError
from workspace_watcher.notion_cache_v2 import NotionProjectCache
from workspace_watcher.project_model_v2 import effective_field


class FakeAdapter:
    def __init__(self, pages=None, error: Exception | None = None) -> None:
        self.pages = pages or []
        self.error = error

    def fetch_projects(self):
        if self.error:
            raise self.error
        return self.pages


def _title_property(value: str) -> dict:
    return {"type": "title", "title": [{"plain_text": value}]}


def _rich_text_property(value: str) -> dict:
    return {"type": "rich_text", "rich_text": [{"plain_text": value}]}


def _select_property(value: str) -> dict:
    return {"type": "select", "select": {"name": value}}


def _multi_select_property(values: list[str]) -> dict:
    return {"type": "multi_select", "multi_select": [{"name": v} for v in values]}


def _page(page_id: str, name: str, local_directory: str = "", *, domain: str = "", tags: list[str] | None = None,
          status: str = "", mediums: list[str] | None = None) -> dict:
    properties = {"Name": _title_property(name)}
    if local_directory:
        properties["Local Directory"] = _rich_text_property(local_directory)
    if domain:
        properties["Domain"] = _select_property(domain)
    if tags:
        properties["Tags"] = _multi_select_property(tags)
    if status:
        properties["Status"] = _select_property(status)
    if mediums:
        properties["Mediums"] = _multi_select_property(mediums)
    return {"id": page_id, "properties": properties}


def _store_with_project(tmp_path: Path, store: CoreStore, *, path: str, name: str) -> None:
    store.create_project(project_id=f"proj-{name}", path=path, root_path="Projects", name=name, device=1, inode=1, timestamp="2026-01-01T00:00:00+00:00")


def test_refresh_matches_by_local_directory_path(tmp_path):
    with CoreStore(tmp_path / "core.db") as store:
        _store_with_project(tmp_path, store, path="Projects/Demo", name="Demo")
        adapter = FakeAdapter(pages=[_page("page-1", "Demo (Notion Title)", local_directory=str(tmp_path / "Projects" / "Demo"))])
        cache = NotionProjectCache(store, tmp_path, NotionSettings(enabled=True), adapter=adapter)
        result = cache.refresh("2026-01-01T00:00:00+00:00")
        assert result["ok"] is True
        rows = store.cached_notion_projects()
        assert len(rows) == 1 and rows[0]["project_id"] == "proj-Demo"


def test_refresh_falls_back_to_unambiguous_name_match(tmp_path):
    with CoreStore(tmp_path / "core.db") as store:
        _store_with_project(tmp_path, store, path="Projects/Demo", name="Demo")
        adapter = FakeAdapter(pages=[_page("page-1", "Demo")])  # no Local Directory property at all
        cache = NotionProjectCache(store, tmp_path, NotionSettings(enabled=True), adapter=adapter)
        cache.refresh("2026-01-01T00:00:00+00:00")
        rows = store.cached_notion_projects()
        assert rows[0]["project_id"] == "proj-Demo"
        import json
        assert json.loads(rows[0]["metadata_json"])["mapping_reason"] == "project_name"


def test_refresh_leaves_unmapped_when_name_is_ambiguous(tmp_path):
    with CoreStore(tmp_path / "core.db") as store:
        _store_with_project(tmp_path, store, path="Projects/Demo", name="Demo")
        store.create_project(project_id="proj-Demo-2", path="Projects/Demo2", root_path="Projects", name="Demo", device=2, inode=2, timestamp="2026-01-01T00:00:00+00:00")
        adapter = FakeAdapter(pages=[_page("page-1", "Demo")])
        cache = NotionProjectCache(store, tmp_path, NotionSettings(enabled=True), adapter=adapter)
        cache.refresh("2026-01-01T00:00:00+00:00")
        rows = store.cached_notion_projects()
        assert rows[0]["project_id"] is None  # two local projects named "Demo" -- can't disambiguate safely
        import json
        assert json.loads(rows[0]["metadata_json"])["mapping_reason"] == "ambiguous_name"


def test_refresh_distinguishes_stale_local_directory_from_no_directory_at_all(tmp_path):
    with CoreStore(tmp_path / "core.db") as store:
        adapter = FakeAdapter(pages=[_page("page-1", "Ghost Project", local_directory="/nowhere/Ghost Project")])
        cache = NotionProjectCache(store, tmp_path, NotionSettings(enabled=True), adapter=adapter)
        cache.refresh("2026-01-01T00:00:00+00:00")
        row = store.cached_notion_projects()[0]
        assert row["project_id"] is None
        import json
        assert json.loads(row["metadata_json"])["mapping_reason"] == "stale_local_directory"


def test_refresh_with_no_local_match_still_caches_the_page(tmp_path):
    with CoreStore(tmp_path / "core.db") as store:
        adapter = FakeAdapter(pages=[_page("page-1", "Unrelated Project")])
        cache = NotionProjectCache(store, tmp_path, NotionSettings(enabled=True), adapter=adapter)
        cache.refresh("2026-01-01T00:00:00+00:00")
        rows = store.cached_notion_projects()
        assert len(rows) == 1 and rows[0]["project_id"] is None


def test_refresh_failure_is_recorded_not_raised_and_preserves_existing_cache(tmp_path):
    with CoreStore(tmp_path / "core.db") as store:
        good_adapter = FakeAdapter(pages=[_page("page-1", "Demo")])
        cache = NotionProjectCache(store, tmp_path, NotionSettings(enabled=True), adapter=good_adapter)
        cache.refresh("2026-01-01T00:00:00+00:00")
        assert len(store.cached_notion_projects()) == 1

        failing_cache = NotionProjectCache(store, tmp_path, NotionSettings(enabled=True), adapter=FakeAdapter(error=NotionCacheError("boom")))
        result = failing_cache.refresh("2026-01-01T01:00:00+00:00")
        assert result["ok"] is False and "boom" in result["error"]
        assert len(store.cached_notion_projects()) == 1  # unchanged, not wiped by the failed attempt


def test_disabled_notion_settings_refresh_is_a_clean_skip(tmp_path):
    with CoreStore(tmp_path / "core.db") as store:
        cache = NotionProjectCache(store, tmp_path, NotionSettings(enabled=False), adapter=FakeAdapter())
        result = cache.refresh("2026-01-01T00:00:00+00:00")
        assert result == {"ok": False, "skipped": True, "reason": "notion_disabled"}
        assert cache.is_due("2026-01-01T00:00:00+00:00") is False


def test_refresh_populates_local_domain_and_tags_from_notion(tmp_path):
    with CoreStore(tmp_path / "core.db") as store:
        _store_with_project(tmp_path, store, path="Projects/Demo", name="Demo")
        adapter = FakeAdapter(pages=[_page("page-1", "Demo", domain="Technology", tags=["AI", "Showcase"])])
        cache = NotionProjectCache(store, tmp_path, NotionSettings(enabled=True), adapter=adapter)
        cache.refresh("2026-01-01T00:00:00+00:00")

        project = store.project_by_id("proj-Demo")
        assert project["domain"] == "Technology"
        tag_names = {row["display"] for row in store.project_tags_for("proj-Demo")}
        assert tag_names == {"AI", "Showcase"}


def test_refresh_does_not_touch_domain_or_tags_for_an_unmapped_page(tmp_path):
    with CoreStore(tmp_path / "core.db") as store:
        adapter = FakeAdapter(pages=[_page("page-1", "Unrelated Project", domain="Technology", tags=["AI"])])
        cache = NotionProjectCache(store, tmp_path, NotionSettings(enabled=True), adapter=adapter)
        # Must not raise despite there being no local project to apply to.
        result = cache.refresh("2026-01-01T00:00:00+00:00")
        assert result["ok"] is True


def test_refresh_leaves_domain_untouched_when_notion_has_none(tmp_path):
    """A local domain is an override, so it outlives any refresh -- including
    one where Notion reports no Domain at all."""
    with CoreStore(tmp_path / "core.db") as store:
        _store_with_project(tmp_path, store, path="Projects/Demo", name="Demo")
        store.set_project_domain("proj-Demo", "Personal", "2025-12-01T00:00:00+00:00")
        adapter = FakeAdapter(pages=[_page("page-1", "Demo")])  # no Domain property at all
        cache = NotionProjectCache(store, tmp_path, NotionSettings(enabled=True), adapter=adapter)
        cache.refresh("2026-01-01T00:00:00+00:00")
        assert effective_field(store.project_by_id("proj-Demo"), "domain") == "Personal"


def test_a_local_domain_survives_a_refresh_that_disagrees(tmp_path):
    """The whole point of the override: Notion keeps its own answer, this app
    keeps mine, and both stay inspectable rather than one silently winning."""
    with CoreStore(tmp_path / "core.db") as store:
        _store_with_project(tmp_path, store, path="Projects/Demo", name="Demo")
        store.set_project_domain("proj-Demo", "Personal", "2025-12-01T00:00:00+00:00")
        adapter = FakeAdapter(pages=[_page("page-1", "Demo", domain="Technology")])
        NotionProjectCache(store, tmp_path, NotionSettings(enabled=True), adapter=adapter).refresh("2026-01-01T00:00:00+00:00")
        row = store.project_by_id("proj-Demo")
        assert effective_field(row, "domain") == "Personal"
        assert row["domain"] == "Technology"  # the mirror still records upstream
        # Dropping the override falls back to Notion rather than to nothing.
        store.clear_project_field_override("proj-Demo", "domain", "2026-01-02T00:00:00+00:00")
        assert effective_field(store.project_by_id("proj-Demo"), "domain") == "Technology"


def test_clearing_a_domain_locally_is_not_undone_by_the_next_refresh(tmp_path):
    """"I deliberately have no domain for this" must be distinguishable from
    "nobody has ever set one", or the next refresh silently refills it."""
    with CoreStore(tmp_path / "core.db") as store:
        _store_with_project(tmp_path, store, path="Projects/Demo", name="Demo")
        store.set_project_field("proj-Demo", "domain", None, "2025-12-01T00:00:00+00:00")
        adapter = FakeAdapter(pages=[_page("page-1", "Demo", domain="Technology")])
        NotionProjectCache(store, tmp_path, NotionSettings(enabled=True), adapter=adapter).refresh("2026-01-01T00:00:00+00:00")
        assert effective_field(store.project_by_id("proj-Demo"), "domain") is None


def test_status_and_mediums_are_mirrored_for_browsing(tmp_path):
    """`By Medium`/`By Status` browsing needs these locally; nothing in the
    real portfolio's own project documents supplies them."""
    with CoreStore(tmp_path / "core.db") as store:
        _store_with_project(tmp_path, store, path="Projects/Demo", name="Demo")
        adapter = FakeAdapter(pages=[_page("page-1", "Demo", status="Active", mediums=["Mobile", "Web"])])
        NotionProjectCache(store, tmp_path, NotionSettings(enabled=True), adapter=adapter).refresh("2026-01-01T00:00:00+00:00")
        assert effective_field(store.project_by_id("proj-Demo"), "status_label") == "Active"
        assert [row["display"] for row in store.project_tags_for("proj-Demo", category="medium")] == ["Mobile", "Web"]
        # A medium is a facet of the shared tag vocabulary, not an ordinary
        # freeform tag, so it must not leak into the By Tag lens.
        assert store.project_tags_for("proj-Demo") == []


def test_mirrored_mediums_reconcile_but_never_discard_local_choices(tmp_path):
    with CoreStore(tmp_path / "core.db") as store:
        _store_with_project(tmp_path, store, path="Projects/Demo", name="Demo")
        cache = NotionProjectCache(store, tmp_path, NotionSettings(enabled=True),
                                   adapter=FakeAdapter(pages=[_page("page-1", "Demo", mediums=["Mobile", "Web"])]))
        cache.refresh("2026-01-01T00:00:00+00:00")
        hardware = store.create_tag("Hardware", category="medium")
        store.assign_project_tag("proj-Demo", hardware["id"], "2026-01-02T00:00:00+00:00")
        store.remove_project_tag("proj-Demo", next(r["id"] for r in store.project_tags_for("proj-Demo", category="medium") if r["display"] == "Web"))

        cache.adapter = FakeAdapter(pages=[_page("page-1", "Demo", mediums=["Mobile", "Web"])])
        cache.refresh("2026-01-03T00:00:00+00:00")
        mediums = [row["display"] for row in store.project_tags_for("proj-Demo", category="medium")]
        # The local addition survives, and the local removal is not undone
        # even though Notion still reports it.
        assert mediums == ["Hardware", "Mobile"]

        # A medium Notion genuinely dropped disappears, since nothing local
        # ever claimed it.
        cache.adapter = FakeAdapter(pages=[_page("page-1", "Demo", mediums=["Mobile"])])
        cache.refresh("2026-01-04T00:00:00+00:00")
        assert [row["display"] for row in store.project_tags_for("proj-Demo", category="medium")] == ["Hardware", "Mobile"]


def test_a_freeform_tag_is_promoted_when_notion_reports_it_as_a_medium(tmp_path):
    """One shared tag vocabulary means the name may already exist without a
    category; leaving it uncategorized would drop it from By Medium."""
    with CoreStore(tmp_path / "core.db") as store:
        _store_with_project(tmp_path, store, path="Projects/Demo", name="Demo")
        store.create_tag("Mobile")  # freeform, category NULL
        NotionProjectCache(store, tmp_path, NotionSettings(enabled=True),
                           adapter=FakeAdapter(pages=[_page("page-1", "Demo", mediums=["Mobile"])])).refresh("2026-01-01T00:00:00+00:00")
        assert [row["display"] for row in store.project_tags_for("proj-Demo", category="medium")] == ["Mobile"]


def test_is_due_respects_the_refresh_interval(tmp_path):
    with CoreStore(tmp_path / "core.db") as store:
        cache = NotionProjectCache(store, tmp_path, NotionSettings(enabled=True, refresh_minutes=30.0), adapter=FakeAdapter())
        assert cache.is_due("2026-01-01T00:00:00+00:00") is True
        cache.refresh("2026-01-01T00:00:00+00:00")
        assert cache.is_due("2026-01-01T00:10:00+00:00") is False
        assert cache.is_due("2026-01-01T00:31:00+00:00") is True
