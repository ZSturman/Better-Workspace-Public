"""resurfacing.py's relevance signals: explicit/potential project
association, tag overlap with the active project, domain/medium overlap,
and "not reviewed in a while" -- plus the noise floor that keeps a
directionless idea out of the surfaced set."""

from __future__ import annotations

from workspace_watcher.actions_v2 import ActionDispatcher
from workspace_watcher.core_store import CoreStore
from workspace_watcher.resurfacing import ResurfacingService

NOW = "2026-06-01T00:00:00+00:00"
OLD = "2026-01-01T00:00:00+00:00"  # ~150 days before NOW


def _idea(store: CoreStore, item_id: str, *, tags=(), domains=(), timestamp=NOW) -> None:
    store.upsert_intent_folder(folder_id="ideas", path="/ideas", root_path="/", name="Ideas", config={}, timestamp=timestamp)
    store.upsert_item(item_id=item_id, folder_id="ideas", path=f"/ideas/{item_id}", title=item_id, item_type="item", status="active",
                       metadata={"keep_suggesting": True, "tags": list(tags), "domains": list(domains)}, device=None, inode=None, timestamp=timestamp)


def _active_project(store: CoreStore, project_id: str, *, domain: str | None = None, tags: tuple[str, ...] = ()) -> None:
    store.create_project(project_id=project_id, path=f"Projects/{project_id}", root_path="Projects", name=project_id, device=None, inode=None, timestamp=NOW)
    if domain:
        store.set_project_domain(project_id, domain, NOW)
    for tag in tags:
        row = store.create_tag(tag)
        store.assign_project_tag(project_id, row["id"], NOW)


def test_explicit_project_relationship_outscores_a_potential_one(tmp_path):
    with CoreStore(tmp_path / "core.db") as store:
        _active_project(store, "p1")
        _idea(store, "related", timestamp=OLD)
        _idea(store, "potential", timestamp=OLD)
        store.create_relationship("related", "project:p1", "related_to_project", NOW)
        store.create_relationship("potential", "project:p1", "potentially_related_to_project", NOW)
        service = ResurfacingService(store, ActionDispatcher(store))
        results = {row["item_id"]: row for row in service.run(NOW, active_project="p1")}
        assert results["related"]["eligible"] and results["potential"]["eligible"]
        assert results["related"]["score"] > results["potential"]["score"]
        assert "associated with the active project" in results["related"]["signals"]


def test_excluded_from_active_project_is_never_eligible(tmp_path):
    with CoreStore(tmp_path / "core.db") as store:
        _active_project(store, "p1")
        _idea(store, "excluded", timestamp=OLD)
        store.create_relationship("excluded", "project:p1", "excluded_from_project", NOW)
        service = ResurfacingService(store, ActionDispatcher(store))
        result = service.run(NOW, active_project="p1")[0]
        assert not result["eligible"]
        assert "excluded from active project" in result["reasons"]


def test_tag_overlap_with_active_project_is_a_real_signal(tmp_path):
    with CoreStore(tmp_path / "core.db") as store:
        _active_project(store, "p1", tags=("dashboards", "ai"))
        _idea(store, "overlaps", tags=("ai",), timestamp=OLD)
        _idea(store, "no_overlap", tags=("unrelated-topic",), timestamp=NOW)
        # Reconcile canonical tags the same way IntentIndexer would, since
        # resurfacing compares canonical tags (shared with project_tags),
        # not the raw TOML tag strings.
        store.reconcile_filesystem_tags("overlaps", ["ai"])
        store.reconcile_filesystem_tags("no_overlap", ["unrelated-topic"])
        service = ResurfacingService(store, ActionDispatcher(store))
        results = {row["item_id"]: row for row in service.run(NOW, active_project="p1")}
        assert results["overlaps"]["eligible"]
        assert not results["no_overlap"]["eligible"]
        assert any("shares tags" in signal for signal in results["overlaps"]["signals"])


def test_domain_overlap_with_active_project_is_a_real_signal(tmp_path):
    with CoreStore(tmp_path / "core.db") as store:
        _active_project(store, "p1", domain="Technology")
        _idea(store, "matches_domain", domains=("technology",), timestamp=OLD)
        service = ResurfacingService(store, ActionDispatcher(store))
        result = service.run(NOW, active_project="p1")[0]
        assert result["eligible"]
        assert any("matches the active project's domain" in signal for signal in result["signals"])


def test_not_reviewed_in_a_while_is_a_real_signal_on_its_own(tmp_path):
    with CoreStore(tmp_path / "core.db") as store:
        _idea(store, "stale", timestamp=OLD)
        service = ResurfacingService(store, ActionDispatcher(store))
        result = service.run(NOW)[0]
        assert result["eligible"]
        assert any("not reviewed in" in signal for signal in result["signals"])


def test_a_fresh_idea_with_no_signal_is_not_eligible(tmp_path):
    """The noise-avoidance floor: a brand-new idea with no project match, no
    tag overlap, and no long gap since review should not spam suggestions."""
    with CoreStore(tmp_path / "core.db") as store:
        _idea(store, "brand_new", timestamp=NOW)
        service = ResurfacingService(store, ActionDispatcher(store))
        result = service.run(NOW)[0]
        assert not result["eligible"]
        assert "no strong enough signal" in result["reasons"]


def test_run_reads_the_current_active_project_from_state_when_not_passed(tmp_path):
    with CoreStore(tmp_path / "core.db") as store:
        _active_project(store, "p1")
        _idea(store, "related", timestamp=OLD)
        store.create_relationship("related", "project:p1", "related_to_project", NOW)
        store.set_state("project.current", {"project_id": "p1"}, NOW)
        service = ResurfacingService(store, ActionDispatcher(store))
        result = service.run(NOW)[0]  # no active_project kwarg at all
        assert result["eligible"]
        assert "associated with the active project" in result["signals"]
