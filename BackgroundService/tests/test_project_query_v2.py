"""The Finder-style query/filter model: compound conditions, sorting, and
grouping over the shared ProjectView shape -- no SQL, no fabricated fields."""

from __future__ import annotations

import pytest

from workspace_watcher.project_query_v2 import filter_projects, group_projects, matches, sort_projects

ALPHA = {"id": "p1", "name": "Alpha", "domain": "Software", "tags": [{"id": "t1", "display": "AI"}], "score": 80.0, "status": "active", "days_since_last_session": 1.0, "open_goals_count": 2, "needs_attention": False, "has_active_session": True, "is_current": True, "notion_linked": True, "session_count": 5}
BETA = {"id": "p2", "name": "Beta", "domain": "Software", "tags": [], "score": 40.0, "status": "active", "days_since_last_session": 30.0, "open_goals_count": 0, "needs_attention": False, "has_active_session": False, "is_current": False, "notion_linked": False, "session_count": 1}
GAMMA = {"id": "p3", "name": "Gamma", "domain": "Writing", "tags": [{"id": "t2", "display": "Fiction"}], "score": 60.0, "status": "archived", "days_since_last_session": None, "open_goals_count": 1, "needs_attention": True, "has_active_session": False, "is_current": False, "notion_linked": True, "session_count": 0}
ALL = [ALPHA, BETA, GAMMA]


def test_bare_condition_is_treated_as_a_single_and():
    assert matches(ALPHA, {"field": "domain", "op": "eq", "value": "Software"})
    assert not matches(BETA, {"field": "score", "op": "gt", "value": 50})


def test_domain_equality_is_case_insensitive():
    assert matches(ALPHA, {"field": "domain", "op": "eq", "value": "software"})
    assert matches(ALPHA, {"field": "domain", "op": "neq", "value": "writing"})


def test_empty_query_matches_everything():
    assert filter_projects(ALL, None) == ALL
    assert filter_projects(ALL, {}) == ALL


def test_compound_and_query_matches_the_readme_example():
    query = {"op": "and", "conditions": [
        {"field": "domain", "op": "eq", "value": "Software"},
        {"field": "tags", "op": "contains", "value": "AI"},
        {"field": "score", "op": "gte", "value": 70},
        {"field": "status", "op": "neq", "value": "archived"},
    ]}
    result = filter_projects(ALL, query)
    assert [p["name"] for p in result] == ["Alpha"]


def test_or_query():
    query = {"op": "or", "conditions": [{"field": "domain", "op": "eq", "value": "Writing"}, {"field": "score", "op": "gte", "value": 75}]}
    result = filter_projects(ALL, query)
    assert {p["name"] for p in result} == {"Alpha", "Gamma"}


def test_tags_not_contains():
    result = filter_projects(ALL, {"field": "tags", "op": "not_contains", "value": "AI"})
    assert {p["name"] for p in result} == {"Beta", "Gamma"}


def test_exists_and_not_exists_for_a_nullable_field():
    assert [p["name"] for p in filter_projects(ALL, {"field": "days_since_last_session", "op": "exists"})] == ["Alpha", "Beta"]
    assert [p["name"] for p in filter_projects(ALL, {"field": "days_since_last_session", "op": "not_exists"})] == ["Gamma"]


def test_a_missing_value_never_satisfies_a_comparison_operator():
    # Gamma has no days_since_last_session -- a >= comparison must not
    # crash or silently coerce None into 0.
    result = filter_projects(ALL, {"field": "days_since_last_session", "op": "gte", "value": 0})
    assert "Gamma" not in {p["name"] for p in result}


def test_boolean_field_equality():
    assert [p["name"] for p in filter_projects(ALL, {"field": "needs_attention", "op": "eq", "value": True})] == ["Gamma"]


def test_name_search_is_case_insensitive_substring():
    assert [p["name"] for p in filter_projects(ALL, {"field": "name", "op": "contains", "value": "alph"})] == ["Alpha"]


def test_unknown_field_raises_a_clear_error():
    with pytest.raises(ValueError, match="unknown query field"):
        matches(ALPHA, {"field": "not_a_real_field", "op": "eq", "value": 1})


def test_unsupported_operator_for_a_field_raises_a_clear_error():
    with pytest.raises(ValueError, match="not supported for field"):
        matches(ALPHA, {"field": "domain", "op": "gte", "value": 1})


def test_sort_descending_by_score_puts_none_last_regardless_of_direction():
    result = sort_projects(ALL, "days_since_last_session", "asc")
    assert result[-1]["name"] == "Gamma"  # None sorts last even ascending
    result_desc = sort_projects(ALL, "days_since_last_session", "desc")
    assert result_desc[-1]["name"] == "Gamma"


def test_sort_ascending_by_score():
    result = sort_projects(ALL, "score", "asc")
    assert [p["name"] for p in result] == ["Beta", "Gamma", "Alpha"]


def test_group_by_domain():
    groups = group_projects(ALL, "domain")
    assert set(groups.keys()) == {"Software", "Writing"}
    assert {p["name"] for p in groups["Software"]} == {"Alpha", "Beta"}


def test_group_by_tags_puts_untagged_projects_in_their_own_bucket():
    groups = group_projects(ALL, "tags")
    assert "(untagged)" in groups and groups["(untagged)"][0]["name"] == "Beta"
    assert groups["AI"][0]["name"] == "Alpha"


def test_no_group_field_returns_one_bucket_with_everything():
    groups = group_projects(ALL, None)
    assert list(groups.values())[0] == ALL


# -- Organizational lenses (By Medium / By Status) ---------------------------
#
# These back the project browser's expandable hierarchies. `status_label` is
# the human "am I pursuing this?" answer and is deliberately separate from
# `status`, the filesystem active/deleted fact.

MOBILE = {"id": "m1", "name": "Mobile App", "domain": "Technology",
          "status_label": "Active", "mediums": [{"id": "d1", "display": "Mobile"}, {"id": "d2", "display": "Web"}],
          "tags": [], "score": 10.0, "status": "active", "days_since_last_session": 2.0,
          "open_goals_count": 0, "needs_attention": False, "has_active_session": False,
          "is_current": False, "notion_linked": True, "session_count": 1}
PAUSED = {"id": "m2", "name": "Paused Thing", "domain": "Technology",
          "status_label": "Paused", "mediums": [{"id": "d3", "display": "Hardware"}],
          "tags": [], "score": 5.0, "status": "active", "days_since_last_session": 90.0,
          "open_goals_count": 0, "needs_attention": False, "has_active_session": False,
          "is_current": False, "notion_linked": True, "session_count": 1}
UNFILED = {"id": "m3", "name": "Unfiled", "domain": None, "status_label": None, "mediums": [],
           "tags": [], "score": 1.0, "status": "active", "days_since_last_session": None,
           "open_goals_count": 0, "needs_attention": False, "has_active_session": False,
           "is_current": False, "notion_linked": False, "session_count": 0}
FACETED = [MOBILE, PAUSED, UNFILED]


def test_group_by_medium_places_a_project_under_every_medium_it_has():
    """A project that is both Mobile and Web genuinely belongs under both --
    the same multi-value semantics tags already have."""
    groups = group_projects(FACETED, "mediums")
    assert sorted(groups) == ["(none)", "Hardware", "Mobile", "Web"]
    assert [p["id"] for p in groups["Mobile"]] == ["m1"]
    assert [p["id"] for p in groups["Web"]] == ["m1"]
    assert [p["id"] for p in groups["(none)"]] == ["m3"]


def test_group_by_status_label_separates_human_status_from_filesystem_status():
    groups = group_projects(FACETED, "status_label")
    assert sorted(groups) == ["(none)", "Active", "Paused"]
    # All three are filesystem-active; only one is a project I am pursuing.
    assert {p["status"] for p in FACETED} == {"active"}


def test_medium_membership_is_case_insensitive():
    assert matches(MOBILE, {"field": "mediums", "op": "contains", "value": "mobile"})
    assert matches(MOBILE, {"field": "mediums", "op": "not_contains", "value": "Hardware"})
    assert not matches(UNFILED, {"field": "mediums", "op": "contains", "value": "Mobile"})


def test_status_label_equality_is_case_insensitive_and_absence_is_explicit():
    assert matches(PAUSED, {"field": "status_label", "op": "eq", "value": "paused"})
    assert matches(UNFILED, {"field": "status_label", "op": "not_exists", "value": None})
    # A project with no status never matches a comparison, only not_exists.
    assert not matches(UNFILED, {"field": "status_label", "op": "eq", "value": "Active"})


def test_filtering_by_status_label_leaves_the_filesystem_status_alone():
    result = filter_projects(FACETED, {"field": "status_label", "op": "eq", "value": "Active"})
    assert [p["id"] for p in result] == ["m1"]
