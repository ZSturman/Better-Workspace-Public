"""Typed dimension filters and named views; unknown numbers always sort last."""
from .model import DIMENSIONS, number


def condition(dimension, op, value=None, attribute="value"):
    return {"dimension": dimension, "attribute": attribute, "op": op, "value": value}


NAMED_VIEWS = {
    "closest-to-finishing": {"name": "Closest to Finishing", "sort": "near_done", "query": condition("near_done", "lt", 100)},
    "small-finishes": {"name": "Small Finishes", "sort": "finishability", "query": {"and": [condition("finishability", "exists"), condition("finishability", "eq", False, "blocked")]}},
    "most-invested": {"name": "Most Invested", "sort": "investment_observed", "query": condition("investment_observed", "exists")},
    "moving-forward": {"name": "Moving Forward", "sort": "momentum_30d", "query": condition("momentum_30d", "gt", 0)},
    "recently-active": {"name": "Recently Active", "sort": "activity_age", "direction": "asc", "query": condition("activity_age", "exists")},
    "most-important": {"name": "Most Important", "sort": "importance", "query": condition("importance", "exists")},
    "highest-potential": {"name": "Highest Potential", "sort": "potential", "query": condition("potential", "exists")},
    "important-neglected": {"name": "Important but Neglected", "sort": "neglect", "query": {"and": [condition("importance", "gte", 75), condition("neglect", "gt", 0)]}},
    "active-without-delivery": {"name": "Active Without Delivery", "sort": "activity_30d", "query": {"and": [condition("activity_30d", "gte", 25), condition("momentum_30d", "eq", 0), condition("momentum_30d", "eq", "known", "state")]}},
    "needs-data": {"name": "Needs Data", "sort": "importance", "query": {"or": [condition(k, "eq", "unknown", "state") for k in ("importance", "potential", "progress", "near_done", "finishability", "momentum_30d")]}},
}


def validate_query(query, depth=0):
    if not isinstance(query, dict) or depth > 8:
        raise ValueError("query must be an object with maximum depth 8")
    if not query:
        return
    if "and" in query or "or" in query:
        if len(query) != 1:
            raise ValueError("use one query combinator")
        children = next(iter(query.values()))
        if not isinstance(children, list) or not children or len(children) > 100:
            raise ValueError("combinator requires 1–100 conditions")
        for child in children:
            validate_query(child, depth+1)
        return
    if query.get("dimension") not in DIMENSIONS:
        raise ValueError("unsupported dimension")
    attr = query.get("attribute", "value")
    if attr not in {"value", "state", "blocked"}:
        raise ValueError("attribute must be value, state or blocked")
    op = query.get("op")
    if attr == "blocked":
        if query["dimension"] != "finishability" or op not in {"eq", "neq"} or not isinstance(query.get("value"), bool):
            raise ValueError("blocked requires a boolean finishability comparison")
    elif attr == "state":
        if op not in {"eq", "neq"} or query.get("value") not in {"known", "provisional", "unknown"}:
            raise ValueError("invalid state comparison")
    elif op not in {"exists", "missing"}:
        if op not in {"eq", "neq", "gt", "gte", "lt", "lte"}:
            raise ValueError("invalid numeric operator")
        number(query.get("value"), minimum=-float("inf"))


def _matches(row, query):
    if not query:
        return True
    if "and" in query:
        return all(_matches(row, q) for q in query["and"])
    if "or" in query:
        return any(_matches(row, q) for q in query["or"])
    metric = row["dimensions"][query["dimension"]]
    value = metric["components"].get("blocked") if query.get("attribute") == "blocked" else metric[query.get("attribute", "value")]
    op, target = query["op"], query.get("value")
    if op == "exists":
        return value is not None
    if op == "missing":
        return value is None
    if value is None:
        return False
    if op == "eq":
        return value == target
    if op == "neq":
        return value != target
    if op == "gt":
        return value > target
    if op == "gte":
        return value >= target
    if op == "lt":
        return value < target
    return value <= target


def select(rows, *, query=None, sort="importance", direction="desc", view=None, profile_id=None):
    if view:
        if view not in NAMED_VIEWS:
            raise ValueError("unknown named view")
        spec = NAMED_VIEWS[view]
        query = {"and": [spec["query"], query]} if query else spec["query"]
        sort, direction = spec["sort"], spec.get("direction", "desc")
    validate_query(query or {})  # validate even when there are no rows
    if sort not in DIMENSIONS or direction not in {"asc", "desc"}:
        raise ValueError("invalid sort dimension or direction")
    rows = sorted((r for r in rows if _matches(r, query)), key=lambda r: (r["name"].casefold(), r["id"]))
    def value(row):
        if profile_id:
            if profile_id not in row["composites"]:
                raise ValueError("unknown profile")
            return row["composites"][profile_id]["value"]
        return row["dimensions"][sort]["value"]
    known = [r for r in rows if value(r) is not None]
    unknown = [r for r in rows if value(r) is None]
    return sorted(known, key=value, reverse=direction == "desc") + unknown
