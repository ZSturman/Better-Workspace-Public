"""Small declarative rule evaluator with structured, persisted explanations."""

from __future__ import annotations

import uuid
import tomllib
from pathlib import Path
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from typing import Any

from .core_events import WorkspaceEvent
from .core_store import CoreStore


@dataclass(frozen=True)
class Rule:
    id: str
    when_event: str
    conditions: dict[str, Any] = field(default_factory=dict)
    actions: tuple[dict[str, Any], ...] = ()
    enabled: bool = True
    priority: int = 0
    cooldown_seconds: float = 0.0


def load_rules(path: str | Path) -> tuple[Rule, ...]:
    """Load a deliberately constrained TOML rule list in evaluation order."""
    from .actions_v2 import ALLOWED_ACTIONS

    source = Path(path)
    try:
        with source.open("rb") as stream:
            raw = tomllib.load(stream)
    except FileNotFoundError:
        return ()
    except tomllib.TOMLDecodeError as error:
        raise ValueError(f"invalid rules TOML in {source}: {error}") from error
    entries = raw.get("rules", [])
    if not isinstance(entries, list):
        raise ValueError("rules must be an array of [[rules]] tables")
    loaded: list[Rule] = []
    ids: set[str] = set()
    for index, entry in enumerate(entries, 1):
        if not isinstance(entry, dict):
            raise ValueError(f"rules[{index}] must be a table")
        rule_id = entry.get("id")
        when = entry.get("when", {})
        conditions, actions = entry.get("conditions", {}), entry.get("actions", [])
        if not isinstance(rule_id, str) or not rule_id.strip() or rule_id in ids:
            raise ValueError(f"rules[{index}].id must be a unique non-empty string")
        if not isinstance(when, dict) or not isinstance(when.get("event"), str):
            raise ValueError(f"rules[{index}].when.event must be a string")
        if not isinstance(conditions, dict) or not isinstance(actions, list):
            raise ValueError(f"rules[{index}] conditions/actions have invalid shape")
        for action in actions:
            if not isinstance(action, dict) or action.get("type") not in ALLOWED_ACTIONS:
                raise ValueError(f"rules[{index}] has an unsupported typed action")
        priority = entry.get("priority", 0)
        cooldown = entry.get("cooldown_seconds", 0)
        if not isinstance(priority, int) or not isinstance(cooldown, (int, float)) or cooldown < 0:
            raise ValueError(f"rules[{index}] priority/cooldown_seconds is invalid")
        ids.add(rule_id)
        loaded.append(Rule(rule_id, when["event"], conditions, tuple(actions), bool(entry.get("enabled", True)), priority, float(cooldown)))
    return tuple(sorted(loaded, key=lambda rule: (-rule.priority, rule.id)))


@dataclass(frozen=True)
class RuleExplanation:
    rule_id: str
    event_id: str
    passed: bool
    checks: tuple[dict[str, Any], ...]

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


class RuleEvaluator:
    """Matches event/intent/status/tags deterministically; no embedded code."""

    def evaluate(self, rule: Rule, event: WorkspaceEvent, context: dict[str, Any]) -> RuleExplanation:
        checks: list[dict[str, Any]] = []
        checks.append(_check("event", rule.when_event, event.type == rule.when_event, event.type))
        for key, expected in rule.conditions.items():
            actual = context.get(key)
            if key == "tags":
                passed = set(expected).issubset(set(actual or []))
            else:
                passed = actual == expected
            checks.append(_check(key, expected, passed, actual))
        return RuleExplanation(rule.id, event.id, all(check["passed"] for check in checks), tuple(checks))

    def evaluate_and_record(self, store: CoreStore, rule: Rule, event: WorkspaceEvent, context: dict[str, Any]) -> RuleExplanation:
        explanation = self.evaluate(rule, event, context)
        store.add_rule_evaluation(event.id, rule.id, "matched" if explanation.passed else "suppressed", explanation.to_dict(), datetime.now(timezone.utc).isoformat())
        return explanation


def _check(field: str, expected: Any, passed: bool, actual: Any) -> dict[str, Any]:
    return {"field": field, "expected": expected, "actual": actual, "passed": passed, "result": "PASS" if passed else "FAIL"}
