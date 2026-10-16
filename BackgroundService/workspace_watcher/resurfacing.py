"""Deterministic item resurfacing, independent of filesystem callbacks."""

from __future__ import annotations

import json
from datetime import datetime, timezone
from typing import Any

from .actions_v2 import ActionDispatcher
from .core_events import EventTypes, WorkspaceEvent
from .core_store import CoreStore
from .project_model_v2 import effective_field


ELIGIBLE_INTENTS = frozenset({"ideas", "inspiration", "to review", "to finish"})


MINIMUM_ELIGIBLE_SCORE = 0.35
"""A floor below "every idea gets suggested eventually" -- resurfacing must
earn its way past base relevance plus at least one real signal (an
explicit/potential project match, meaningful tag/domain overlap, or a long
review gap), or it stays in the library instead of interrupting anyone."""


class ResurfacingService:
    def __init__(self, store: CoreStore, dispatcher: ActionDispatcher, *, minimum_days: int = 7, max_results: int = 3) -> None:
        self.store, self.dispatcher, self.minimum_days, self.max_results = store, dispatcher, minimum_days, max_results

    def run(self, now: str | None = None, *, active_project: str | None = None) -> list[dict[str, Any]]:
        current = now or datetime.now(timezone.utc).isoformat()
        active_project = active_project or (self.store.get_state("project.current") or {}).get("project_id")
        candidates: list[dict[str, Any]] = []
        folders = {row["id"]: row["name"] for row in self.store.folders()}
        project_tag_names = {row["display"].casefold() for row in self.store.project_tags_for(active_project)} if active_project else set()
        active_project_row = self.store.project_by_id(active_project) if active_project else None
        # The effective domain, so a locally overridden one still drives this
        # signal -- reading the mirror column alone would silently ignore
        # every domain the person set in the app rather than in Notion.
        active_domain = effective_field(active_project_row, "domain") if active_project_row is not None else None
        for item in self.store.items():
            metadata = json.loads(item["metadata_json"] or "{}")
            intent = folders.get(item["intent_folder_id"], "")
            evaluation = self._evaluate(item, intent, metadata, current, active_project, project_tag_names, active_domain)
            candidates.append(evaluation)
        candidates.sort(key=lambda candidate: (-candidate["score"], candidate["title"].casefold()))
        # Keep candidate evaluation visible for every item but cap actual
        # delivery, which is the policy stage rather than ranking itself.
        surfaced_ids = {candidate["item_id"] for candidate in [item for item in candidates if item["eligible"]][:self.max_results]}
        for evaluation in candidates:
            surfaced = evaluation["item_id"] in surfaced_ids
            self.store.remember_resurfacing(evaluation["item_id"], now=current, surfaced=surfaced, score=evaluation["score"], reasons=evaluation)
            if surfaced:
                event = WorkspaceEvent(type=EventTypes.RESURFACING_DUE, entity_id=evaluation["item_id"], payload=evaluation, source="scheduler")
                self.store.record_event(event)
                self.dispatcher.dispatch({"type": "notification", "notification_type": "suggestion", "title": evaluation["title"], "body": f"Resurfaced from [[{evaluation['intent']}]] -- {', '.join(evaluation['signals']) or 'worth another look'}.", "priority": "normal", "dedupe_key": f"resurface:{evaluation['item_id']}:{current[:10]}"}, event)
        return candidates

    def _evaluate(self, item: Any, intent: str, metadata: dict[str, Any], now: str, active_project: str | None,
                  project_tag_names: set[str], active_domain: str | None) -> dict[str, Any]:
        reasons: list[str] = []
        signals: list[str] = []
        if intent.casefold() not in ELIGIBLE_INTENTS: reasons.append("intent is not a resurfacing source")
        if item["status"] in {"archived", "suppressed"}: reasons.append("item status suppresses resurfacing")
        if not metadata.get("keep_suggesting", True): reasons.append("keep_suggesting is disabled")
        defer_until = metadata.get("defer_until")
        if defer_until and defer_until > now: reasons.append("item is deferred")
        state = self.store.resurfacing_state(item["id"])
        if state and state["last_surfaced_at"]:
            then = datetime.fromisoformat(state["last_surfaced_at"])
            if (datetime.fromisoformat(now) - then).days < self.minimum_days: reasons.append("cooldown")

        relationships = self.store.relationships_for(item["id"])
        related_project_ids = {row["to_id"] for row in relationships if row["type"] == "related_to_project"}
        potential_project_ids = {row["to_id"] for row in relationships if row["type"] == "potentially_related_to_project"}
        excluded_project_ids = {row["to_id"] for row in relationships if row["type"] == "excluded_from_project"}
        active_key = f"project:{active_project}" if active_project else None

        score = 0.2
        if active_key and active_key in related_project_ids:
            score += 0.5; signals.append("associated with the active project")
        elif active_key and active_key in potential_project_ids:
            score += 0.3; signals.append("a potential fit for the active project")
        if active_key and active_key in excluded_project_ids:
            reasons.append("excluded from active project")

        own_tags = {row["display"].casefold() for row in self.store.tags_for_item(item["id"])}
        tag_overlap = own_tags & project_tag_names
        if tag_overlap:
            score += min(0.2, 0.1 * len(tag_overlap)); signals.append(f"shares tags with the active project ({', '.join(sorted(tag_overlap))})")
        else:
            score += min(0.1, len(metadata.get("tags", [])) * 0.02)

        domains = {str(d).casefold() for d in metadata.get("domains", [])} | {str(d).casefold() for d in metadata.get("mediums", [])}
        if active_domain and active_domain.casefold() in domains:
            score += 0.15; signals.append(f"matches the active project's domain ({active_domain})")

        if state is not None and state["last_considered_at"]:
            age_days = (datetime.fromisoformat(now) - datetime.fromisoformat(state["last_considered_at"])).days
        else:
            age_days = (datetime.fromisoformat(now) - datetime.fromisoformat(item["created_at"])).days if item["created_at"] else 0
        if age_days >= 30:
            score += min(0.15, 0.01 * (age_days - 30) + 0.05); signals.append(f"not reviewed in {age_days} days")

        score = round(score, 3)
        eligible = not reasons and score >= MINIMUM_ELIGIBLE_SCORE
        if not reasons and score < MINIMUM_ELIGIBLE_SCORE:
            reasons.append("no strong enough signal")
        return {"item_id": item["id"], "title": item["title"], "intent": intent, "score": score, "eligible": eligible, "reasons": reasons, "signals": signals, "active_project": active_project}
