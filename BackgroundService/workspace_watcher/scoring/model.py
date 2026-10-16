"""JSON contracts and validation shared by the calculator, storage and API."""
from __future__ import annotations

from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
import math
from typing import Any

VERSION = "1.1"


def timestamp(value: str) -> datetime:
    if not isinstance(value, str):
        raise ValueError("timestamp must be an ISO-8601 string with timezone")
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as exc:
        raise ValueError("invalid ISO-8601 timestamp") from exc
    if parsed.tzinfo is None:
        raise ValueError("timestamp must include timezone")
    return parsed.astimezone(timezone.utc)


def number(value: Any, *, minimum: float = 0, maximum: float = float("inf")) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
        raise ValueError("expected a finite number")
    if not minimum <= value <= maximum:
        raise ValueError(f"number must be between {minimum} and {maximum}")
    return float(value)


@dataclass(frozen=True)
class Dimension:
    value: float | None = None
    raw_value: Any = None
    unit: str = "score"
    state: str = "unknown"
    source: str = "local"
    provenance: str = "deterministic"
    input_provenance: list[str] = field(default_factory=list)
    coverage: dict = field(default_factory=dict)
    window: dict = field(default_factory=dict)
    formula_version: str = VERSION
    calculated_at: str = ""
    explanation: str = "Required data is unavailable."
    components: dict = field(default_factory=dict)

    def json(self) -> dict:
        return asdict(self)


BASE_DIMENSIONS = {
    "manual_assessment", "importance", "potential", "urgency", "progress",
    "near_done", "finishability", "staleness", "neglect", "activity_age",
    "investment_observed",
}
GROUPS = {
    "personalValue": (20, ("qualityOfLife", "personalImportance", "enjoyment")),
    "financialValue": (10, ("incomePotential", "costSavings", "financialCost")),
    "professionalValue": (15, ("careerRelevance", "demonstrationValue", "opportunityPotential")),
    "learningGrowth": (10, ("skillDevelopment", "knowledgeGain", "explorationValue")),
    "strategicValue": (20, ("goalAlignment", "leverage", "dependencyImportance")),
    "timeExecution": (15, ("urgency", "effort", "readiness")),
    "riskConsequences": (10, ("outcomeUncertainty", "ongoingBurden", "abandonmentCost")),
}
COSTS = {"financialCost", "effort", "outcomeUncertainty", "ongoingBurden", "abandonmentCost"}
METRICS = {m for _, metrics in GROUPS.values() for m in metrics}
DIMENSIONS = BASE_DIMENSIONS | {f"value_{g}" for g in GROUPS} | {
    f"{kind}_{days}d" for kind in ("investment", "activity", "momentum") for days in (7, 30, 90)
} | {"consistency_28d", "consistency_84d"}


def validate_profile(profile: dict) -> dict:
    if not isinstance(profile, dict):
        raise ValueError("profile must be an object")
    if not isinstance(profile.get("id"), str) or not profile["id"].strip():
        raise ValueError("profile id is required")
    if not isinstance(profile.get("name"), str) or not profile["name"].strip():
        raise ValueError("profile name is required")
    weights = profile.get("weights")
    if not isinstance(weights, dict) or not weights or set(weights) - DIMENSIONS:
        raise ValueError("weights must reference supported dimensions")
    if any(k == "activity_age" for k in weights):
        raise ValueError("activity_age is in days, not a 0–100 composite component")
    for weight in weights.values():
        number(weight, minimum=0.000001)
    if profile.get("missing_policy", "require_all") not in {"require_all", "fixed_zero"}:
        raise ValueError("missing_policy must be require_all or fixed_zero")
    if not isinstance(profile.get("allow_provisional", False), bool):
        raise ValueError("allow_provisional must be boolean")
    return {"id": profile["id"], "name": profile["name"], "weights": weights,
            "missing_policy": profile.get("missing_policy", "require_all"),
            "allow_provisional": profile.get("allow_provisional", False)}


def validate_inputs(data: dict) -> dict:
    """Versioned supplemental local facts; no inferred planning from text/status names.

    Scopes contain non-overlapping accepted leaf outcomes. History is a complete
    accept/reopen ledger for those same IDs, not a stream of cumulative snapshots.
    """
    if not isinstance(data, dict) or data.get("version") != 1:
        raise ValueError("scoring inputs require version: 1")
    if "cadence_days" in data:
        number(data["cadence_days"], minimum=1)
    if "activated_at" in data:
        timestamp(data["activated_at"])
    if "observation" in data:
        obs = data["observation"]
        if not isinstance(obs, dict) or not isinstance(obs.get("complete"), bool):
            raise ValueError("observation requires complete boolean")
        if timestamp(obs["end"]) < timestamp(obs["start"]):
            raise ValueError("observation end precedes start")
    scopes = data.get("scopes", [])
    if not isinstance(scopes, list):
        raise ValueError("scopes must be a list")
    scope_ids = set()
    for scope in scopes:
        if not isinstance(scope, dict) or not isinstance(scope.get("id"), str) or not scope["id"]:
            raise ValueError("scope requires id")
        if scope["id"] in scope_ids:
            raise ValueError("duplicate scope id")
        scope_ids.add(scope["id"])
        if not isinstance(scope.get("revision"), str) or not scope["revision"]:
            raise ValueError("scope requires revision")
        if scope.get("defined") is not True:
            raise ValueError("scope must be explicitly defined")
        leaves = scope.get("leaves")
        if not isinstance(leaves, list) or not leaves:
            raise ValueError("scope requires nonempty leaves")
        ids = set()
        for leaf in leaves:
            if not isinstance(leaf, dict) or not isinstance(leaf.get("id"), str) or not leaf["id"]:
                raise ValueError("leaf requires id")
            if leaf["id"] in ids:
                raise ValueError("duplicate leaf: count each deliverable once")
            ids.add(leaf["id"])
            number(leaf.get("weight"), minimum=0.000001)
            if not isinstance(leaf.get("accepted"), bool):
                raise ValueError("accepted must be boolean")
            if "remaining_hours" in leaf:
                number(leaf["remaining_hours"])
        if "blocked" in scope and not isinstance(scope["blocked"], bool):
            raise ValueError("blocked must be boolean")
        if "history_start" in scope:
            start = timestamp(scope["history_start"])
            seen = set()
            events = scope.get("events", [])
            if not isinstance(events, list):
                raise ValueError("events must be a list")
            for event in events:
                if not isinstance(event, dict) or event.get("leaf_id") not in ids:
                    raise ValueError("event must reference a scope leaf")
                if not isinstance(event.get("id"), str) or event["id"] in seen:
                    raise ValueError("event requires unique id")
                seen.add(event["id"])
                if event.get("kind") not in {"accept", "reopen"} or timestamp(event["at"]) < start:
                    raise ValueError("invalid delivery event")
        if "planned_weight_per_week" in scope:
            number(scope["planned_weight_per_week"], minimum=0.000001)
    for key in ("project_scope_id", "next_scope_id"):
        if key in data and data[key] not in scope_ids:
            raise ValueError(f"{key} must identify a defined scope")
    return data


def validate_manual_config(config):
    if config is None:
        return
    if not isinstance(config, dict):
        raise ValueError("manual configuration must be an object")
    for key, allowed in (("enabled_groups", set(GROUPS)), ("enabled_metrics", METRICS)):
        if key in config:
            values = config[key]
            if not isinstance(values, list) or any(not isinstance(v, str) or v not in allowed for v in values) or len(set(values)) != len(values):
                raise ValueError(f"invalid {key}")
    weights = config.get("group_weights", {})
    if not isinstance(weights, dict) or set(weights)-set(GROUPS):
        raise ValueError("invalid group_weights")
    for value in weights.values():
        number(value)
