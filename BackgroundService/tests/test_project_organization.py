"""Local overrides of Notion-mirrored organizational fields, and the medium
facet built on the shared tag vocabulary.

The invariant these all protect: a choice made in this app must survive every
later Notion refresh, and "I deliberately set none" must stay distinguishable
from "nobody has ever said".
"""

from __future__ import annotations

import pytest

from workspace_watcher.core_store import CoreStore
from workspace_watcher.project_model_v2 import effective_field, field_source

NOW = "2026-01-01T00:00:00+00:00"
LATER = "2026-02-01T00:00:00+00:00"


@pytest.fixture
def store(tmp_path):
    with CoreStore(tmp_path / "core.db") as store:
        store.create_project(project_id="p1", path="Projects/Demo", root_path="Projects",
                             name="Demo", device=1, inode=1, timestamp=NOW)
        yield store


# -- Single-valued mirrored fields ------------------------------------------

def test_a_mirrored_value_is_used_when_there_is_no_local_opinion(store):
    store.set_project_mirrored_field("p1", "domain", "Technology", NOW)
    row = store.project_by_id("p1")
    assert effective_field(row, "domain") == "Technology"
    assert field_source(row, "domain") == "notion"


def test_a_local_value_wins_over_the_mirror(store):
    store.set_project_mirrored_field("p1", "domain", "Technology", NOW)
    store.set_project_field("p1", "domain", "Personal", LATER)
    row = store.project_by_id("p1")
    assert effective_field(row, "domain") == "Personal"
    assert field_source(row, "domain") == "local"
    # The mirror is still recorded, so "Notion disagrees" stays inspectable.
    assert row["domain"] == "Technology"


def test_clearing_locally_is_an_opinion_not_an_absence(store):
    """Without the `_local_set` flag these two cases are identical, and the
    next refresh silently refills a value someone deliberately emptied."""
    store.set_project_field("p1", "domain", None, NOW)
    store.set_project_mirrored_field("p1", "domain", "Technology", LATER)
    row = store.project_by_id("p1")
    assert effective_field(row, "domain") is None
    assert field_source(row, "domain") == "local"


def test_dropping_the_override_falls_back_to_the_mirror(store):
    store.set_project_mirrored_field("p1", "domain", "Technology", NOW)
    store.set_project_field("p1", "domain", "Personal", NOW)
    store.clear_project_field_override("p1", "domain", LATER)
    row = store.project_by_id("p1")
    assert effective_field(row, "domain") == "Technology"
    assert field_source(row, "domain") == "notion"


def test_status_label_is_independent_of_filesystem_status(store):
    """`status` answers "does this folder still exist"; `status_label` answers
    "am I pursuing it". Conflating them would make Paused mean deleted."""
    store.set_project_mirrored_field("p1", "status_label", "Paused", NOW)
    row = store.project_by_id("p1")
    assert row["status"] == "active"
    assert effective_field(row, "status_label") == "Paused"


def test_whitespace_only_values_are_stored_as_absent(store):
    store.set_project_field("p1", "domain", "   ", NOW)
    assert effective_field(store.project_by_id("p1"), "domain") is None


@pytest.mark.parametrize("field", ["notes", "score", "status", ""])
def test_an_unknown_field_is_refused(store, field):
    with pytest.raises(ValueError):
        store.set_project_field("p1", field, "x", NOW)
    with pytest.raises(ValueError):
        store.set_project_mirrored_field("p1", field, "x", NOW)


# -- The medium facet on the shared tag vocabulary --------------------------

def test_a_medium_is_a_categorized_tag_and_stays_out_of_the_tag_lens(store):
    medium = store.create_tag("Mobile", category="medium")
    plain = store.create_tag("automation")
    store.assign_project_tag("p1", medium["id"], NOW)
    store.assign_project_tag("p1", plain["id"], NOW)
    assert [r["display"] for r in store.project_tags_for("p1", category="medium")] == ["Mobile"]
    assert [r["display"] for r in store.project_tags_for("p1")] == ["automation"]
    # Both are still one vocabulary, visible together where that is wanted.
    assert {r["display"] for r in store.all_project_tags_for("p1")} == {"Mobile", "automation"}


def test_removing_a_mirrored_tag_leaves_a_tombstone_that_survives_refresh(store):
    tag = store.create_tag("Mobile", category="medium")
    store.replace_mirrored_project_tags("p1", [tag["id"]], NOW, category="medium")
    assert store.remove_project_tag("p1", tag["id"]) is True
    # A plain delete would be undone by the very next refresh; the tombstone
    # is what makes the removal durable.
    store.replace_mirrored_project_tags("p1", [tag["id"]], LATER, category="medium")
    assert store.project_tags_for("p1", category="medium") == []


def test_removing_a_purely_local_tag_just_removes_it(store):
    tag = store.create_tag("Hardware", category="medium")
    store.assign_project_tag("p1", tag["id"], NOW)
    assert store.remove_project_tag("p1", tag["id"]) is True
    assert store.conn.execute("SELECT COUNT(*) FROM project_tags WHERE project_id='p1'").fetchone()[0] == 0
    # Removing something that is not there is reported, not silently accepted.
    assert store.remove_project_tag("p1", tag["id"]) is False


def test_re_adding_locally_lifts_a_previous_local_removal(store):
    tag = store.create_tag("Mobile", category="medium")
    store.replace_mirrored_project_tags("p1", [tag["id"]], NOW, category="medium")
    store.remove_project_tag("p1", tag["id"])
    store.assign_project_tag("p1", tag["id"], LATER)
    assert [r["display"] for r in store.project_tags_for("p1", category="medium")] == ["Mobile"]


def test_a_mirrored_refresh_never_discards_a_local_addition(store):
    mirrored = store.create_tag("Mobile", category="medium")
    local = store.create_tag("Hardware", category="medium")
    store.replace_mirrored_project_tags("p1", [mirrored["id"]], NOW, category="medium")
    store.assign_project_tag("p1", local["id"], NOW)
    store.replace_mirrored_project_tags("p1", [mirrored["id"]], LATER, category="medium")
    assert {r["display"] for r in store.project_tags_for("p1", category="medium")} == {"Mobile", "Hardware"}


def test_a_mirrored_tag_notion_dropped_disappears(store):
    gone = store.create_tag("Web", category="medium")
    kept = store.create_tag("Mobile", category="medium")
    store.replace_mirrored_project_tags("p1", [gone["id"], kept["id"]], NOW, category="medium")
    store.replace_mirrored_project_tags("p1", [kept["id"]], LATER, category="medium")
    assert [r["display"] for r in store.project_tags_for("p1", category="medium")] == ["Mobile"]


def test_reconciling_one_category_leaves_other_categories_alone(store):
    medium = store.create_tag("Mobile", category="medium")
    plain = store.create_tag("automation")
    store.assign_project_tag("p1", plain["id"], NOW, source="notion")
    store.replace_mirrored_project_tags("p1", [medium["id"]], NOW, category="medium")
    store.replace_mirrored_project_tags("p1", [], LATER, category="medium")
    assert store.project_tags_for("p1", category="medium") == []
    assert [r["display"] for r in store.project_tags_for("p1")] == ["automation"]


def test_a_category_is_applied_to_a_name_that_already_existed_freeform(store):
    """One shared vocabulary means the name may already be present with no
    category; leaving it that way would drop it from By Medium."""
    store.create_tag("Mobile")
    promoted = store.create_tag("Mobile", category="medium")
    assert promoted["category"] == "medium"
    # A later caller that says nothing about category must not clear it.
    assert store.create_tag("Mobile")["category"] == "medium"


def test_an_excluded_pairing_is_hidden_from_every_consumer(store):
    tag = store.create_tag("Mobile", category="medium")
    store.replace_mirrored_project_tags("p1", [tag["id"]], NOW, category="medium")
    store.remove_project_tag("p1", tag["id"])
    # The full-portfolio query the browser uses must agree with the detail view.
    assert [row for row in store.all_project_tags() if row["project_id"] == "p1"] == []


@pytest.mark.parametrize("source", ["", "excluded", "bogus"])
def test_an_unknown_assignment_source_is_refused(store, source):
    tag = store.create_tag("Mobile", category="medium")
    with pytest.raises(ValueError):
        store.assign_project_tag("p1", tag["id"], NOW, source=source)
