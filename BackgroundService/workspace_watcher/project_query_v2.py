"""The Finder-style query/filter model: one structured filter tree that
powers the sidebar's smart views, saved searches, interactive filtering,
counts, grouping, and sorting -- all from the same `ProjectView` shape
`project_model_v2.py` builds. The GUI never writes SQL; it builds this JSON
tree from native controls, and this module is the only place that
interprets it.

A query is a tree of conditions combined with "and"/"or":

    {"op": "and", "conditions": [
        {"field": "domain", "op": "eq", "value": "Software"},
        {"field": "tags", "op": "contains", "value": "AI"},
        {"field": "score", "op": "gte", "value": 70},
        {"field": "status", "op": "neq", "value": "archived"},
    ]}

A bare condition (no "op"/"conditions" wrapper) is also accepted and treated
as a single-condition "and" -- convenient for the common one-filter case.
An empty/missing query matches everything.
"""

from __future__ import annotations

import json
from typing import Any

from .core_engine import utc_now
from .core_store import CoreStore

# Ship with the app, always present, not user-deletable (`built_in=1`).
# Fixed ids so re-running `ensure_builtin_saved_views` is idempotent
# (INSERT OR IGNORE by id) rather than accumulating duplicates on every
# startup.
BUILT_IN_VIEWS: list[dict[str, Any]] = [
    {"id": "builtin-all", "name": "All Projects", "query": {}, "sort_field": "name", "sort_direction": "asc", "group_by": None},
    {"id": "builtin-highest-priority", "name": "Highest Priority", "query": {"field": "score", "op": "gt", "value": 0}, "sort_field": "score", "sort_direction": "desc", "group_by": None},
    {"id": "builtin-needs-attention", "name": "Needs Attention", "query": {"field": "needs_attention", "op": "eq", "value": True}, "sort_field": "days_since_last_session", "sort_direction": "desc", "group_by": None},
    {"id": "builtin-recently-active", "name": "Recently Active", "query": {"field": "days_since_last_session", "op": "lte", "value": 3}, "sort_field": "days_since_last_session", "sort_direction": "asc", "group_by": None},
    {"id": "builtin-open-goals", "name": "Has Open Goals", "query": {"field": "open_goals_count", "op": "gt", "value": 0}, "sort_field": "score", "sort_direction": "desc", "group_by": None},
    {"id": "builtin-by-domain", "name": "By Domain", "query": {}, "sort_field": "name", "sort_direction": "asc", "group_by": "domain"},
    {"id": "builtin-by-tag", "name": "By Tag", "query": {}, "sort_field": "name", "sort_direction": "asc", "group_by": "tags"},
]


def ensure_builtin_saved_views(store: CoreStore) -> None:
    existing_ids = {row["id"] for row in store.saved_views()}
    now = utc_now()
    for index, view in enumerate(BUILT_IN_VIEWS):
        if view["id"] in existing_ids:
            continue
        store.create_saved_view({
            "id": view["id"], "name": view["name"], "query_json": json.dumps(view["query"]),
            "sort_field": view["sort_field"], "sort_direction": view["sort_direction"], "group_by": view["group_by"],
            "built_in": 1, "sort_order": index, "created_at": now, "updated_at": now,
        })

Condition = dict[str, Any]
Query = dict[str, Any]

# Every supported field, and the operators that make sense for it -- used by
# the GUI to build native controls (a picker for "eq", a slider for
# "score", etc.) rather than exposing raw operator strings as freeform text.
FIELD_SPECS: dict[str, dict[str, Any]] = {
    "domain": {"type": "string", "operators": ["eq", "neq", "exists", "not_exists"]},
    "tags": {"type": "list", "operators": ["contains", "not_contains"]},
    "mediums": {"type": "list", "operators": ["contains", "not_contains"]},
    # The human "am I actively pursuing this?" label, mirrored from Notion.
    # Deliberately distinct from `status`, which is the filesystem
    # active/deleted fact and answers a completely different question.
    "status_label": {"type": "string", "operators": ["eq", "neq", "exists", "not_exists"]},
    "status": {"type": "string", "operators": ["eq", "neq"]},
    "name": {"type": "string", "operators": ["contains"]},
    "score": {"type": "number", "operators": ["gt", "gte", "lt", "lte", "eq"]},
    "days_since_last_session": {"type": "number", "operators": ["gt", "gte", "lt", "lte", "exists", "not_exists"]},
    "open_goals_count": {"type": "number", "operators": ["gt", "gte", "lt", "lte", "eq"]},
    "session_count": {"type": "number", "operators": ["gt", "gte", "lt", "lte", "eq"]},
    "needs_attention": {"type": "boolean", "operators": ["eq"]},
    "has_active_session": {"type": "boolean", "operators": ["eq"]},
    "is_current": {"type": "boolean", "operators": ["eq"]},
    "notion_linked": {"type": "boolean", "operators": ["eq"]},
}


def _condition_matches(view: dict[str, Any], condition: Condition) -> bool:
    field = condition.get("field")
    op = condition.get("op")
    value = condition.get("value")
    if field not in FIELD_SPECS:
        raise ValueError(f"unknown query field: {field!r}")
    if op not in FIELD_SPECS[field]["operators"]:
        raise ValueError(f"operator {op!r} not supported for field {field!r}")
    actual = view.get(field)

    if field == "tags":
        names = {str(tag["display"]).casefold() for tag in (actual or [])}
        target = str(value or "").casefold()
        return (target in names) if op == "contains" else (target not in names)
    if field == "mediums":
        names = {str(medium["display"]).casefold() for medium in (actual or [])}
        target = str(value or "").casefold()
        return (target in names) if op == "contains" else (target not in names)
    if op == "exists":
        return actual is not None
    if op == "not_exists":
        return actual is None
    if actual is None:
        # A None field never satisfies a comparison operator (missing
        # domain never equals "Software", missing recency never satisfies
        # a numeric threshold) -- only exists/not_exists reason about
        # absence explicitly.
        return False
    # Domains are user-facing categories, not case-sensitive identifiers.
    # This makes a filter such as `domain == "technology"` match the
    # existing `Technology` value while retaining exact comparisons for
    # fields such as status.
    if field in ("domain", "status_label") and isinstance(actual, str) and isinstance(value, str):
        if op == "eq":
            return actual.casefold() == value.casefold()
        if op == "neq":
            return actual.casefold() != value.casefold()
    if op == "eq":
        return actual == value
    if op == "neq":
        return actual != value
    if op == "contains":
        return str(value or "").casefold() in str(actual).casefold()
    if op in {"gt", "gte", "lt", "lte"}:
        left, right = float(actual), float(value)
        return {"gt": left > right, "gte": left >= right, "lt": left < right, "lte": left <= right}[op]
    raise ValueError(f"unsupported operator: {op!r}")


def matches(view: dict[str, Any], query: Query | None) -> bool:
    if not query:
        return True
    if "conditions" in query:
        op = query.get("op", "and")
        conditions = query["conditions"]
        if op == "and":
            return all(matches(view, condition) for condition in conditions)
        if op == "or":
            return any(matches(view, condition) for condition in conditions)
        raise ValueError(f"unsupported combinator: {op!r}")
    return _condition_matches(view, query)


def filter_projects(views: list[dict[str, Any]], query: Query | None) -> list[dict[str, Any]]:
    return [view for view in views if matches(view, query)]


def sort_projects(views: list[dict[str, Any]], field: str = "score", direction: str = "desc") -> list[dict[str, Any]]:
    """None always sorts last, regardless of direction -- "unknown" should
    never jump to the top just because a naive descending sort treats None
    as smaller than everything. Sorting each partition (known values, then
    None values) separately, rather than a single `reverse=True` sort over
    a combined key, is what actually achieves that: `reverse=True` would
    otherwise flip the "is this None" flag too, putting None first."""
    reverse = direction != "asc"
    known = [view for view in views if view.get(field) is not None]
    unknown = [view for view in views if view.get(field) is None]
    known.sort(key=lambda view: view[field], reverse=reverse)
    return known + unknown


def group_projects(views: list[dict[str, Any]], field: str | None) -> dict[str, list[dict[str, Any]]]:
    if not field:
        return {"": views}
    groups: dict[str, list[dict[str, Any]]] = {}
    for view in views:
        if field == "tags":
            keys = [tag["display"] for tag in view.get("tags") or []] or ["(untagged)"]
        elif field == "mediums":
            # Multi-valued like tags: a project that is both Mobile and Web
            # genuinely belongs under both headings.
            keys = [medium["display"] for medium in (view.get("mediums") or [])] or ["(none)"]
        else:
            raw = view.get(field)
            keys = [str(raw) if raw not in (None, "") else "(none)"]
        for key in keys:
            groups.setdefault(key, []).append(view)
    return groups
