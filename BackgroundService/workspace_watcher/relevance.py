"""Inspectable, deterministic contextual relevance downstream of the watcher.

It consumes only ``WorkspaceWatcherClient.project_activity``-equivalent store
facts and cached/local source metadata.  It deliberately has no watcher,
Notion, or model dependency; a future semantic provider can augment scores.
"""

from __future__ import annotations

import hashlib
import json
import re
import time
import uuid
from dataclasses import dataclass
from typing import Any

from .client import ProjectActivityContext
from .config import RelevanceSettings
from .store import WorkspaceStore

_STOP = frozenset({"the", "and", "for", "with", "from", "this", "that", "project", "projects", "workspace", "ideas", "resources", "collections"})


def _tokens(value: str) -> set[str]:
    return {part for part in re.findall(r"[a-z0-9]{3,}", value.lower()) if part not in _STOP}


@dataclass(frozen=True)
class RelevanceResult:
    run_id: str
    project_id: str
    project_name: str
    candidates: list[dict[str, Any]]


class RelevanceEngine:
    def __init__(self, store: WorkspaceStore, settings: RelevanceSettings) -> None:
        self.store, self.settings = store, settings

    def refresh_sources(self) -> int:
        """Index only data already locally available to this repository."""
        records: list[dict[str, Any]] = []
        for row in self.store.cached_notion_projects():
            metadata = json.loads(row["metadata_json"] or "{}")
            parts = [row["name"], row["status"] or ""]
            for key in ("current_work_json", "recent_work_json", "next_work_json"):
                parts.extend(json.loads(row[key] or "[]"))
            text = " ".join(str(part) for part in parts)
            records.append(self._document("notion_project", str(row["notion_project_id"]), str(row["name"]), text,
                metadata.get("tags", []), [row["local_project_id"]] if row["local_project_id"] else [], row["refreshed_at"], metadata))
        # File names are useful local context without opening/copying user
        # content. More capable text adapters can be added independently.
        for kind in ("ideas", "resources", "collections"):
            for row in self.store.fs_entries(kind):
                title = str(row["path"]).rsplit("/", 1)[-1]
                records.append(self._document(f"filesystem_{kind}", str(row["path"]), title, str(row["path"]), [], [], row["last_event_at"], {"path": row["path"], "area_kind": kind}))
        for item in self.store.all_items(only_existing=True):
            tags = [str(t["display"]) for t in self.store.tags_for_item(item["item_id"])]
            metadata = json.loads(item["metadata_json"] or "{}")
            text_parts = [str(item["description"] or ""), str(item["source"] or "")]
            project_ids = [pid for pid in ([item["source_project"]] + list(metadata.get("used_by_projects") or [])) if pid]
            records.append(self._document(
                f"intent:{item['intent_folder']}", str(item["path"]), str(item["title"] or item["name"]),
                " ".join(text_parts), tags, project_ids, item["last_seen_at"],
                {"path": item["path"], "item_id": item["item_id"], "intent_folder": item["intent_folder"],
                 "archive_state": item["archive_state"], "excluded_projects": metadata.get("excluded_projects") or []},
            ))
        self.store.upsert_relevance_documents(records)
        return len(records)

    def run(self, context: ProjectActivityContext, *, now: float | None = None, dry_run: bool = False) -> RelevanceResult:
        current = time.time() if now is None else now
        self.refresh_sources()
        context_tokens = _tokens(context.project.name + " " + " ".join(context.files_touched))
        run_id = f"relevance-{uuid.uuid4()}"
        ranked: list[dict[str, Any]] = []
        source_seen: set[str] = set()
        for row in self.store.relevance_documents(self.settings.source_limit):
            candidate = self._rank_row(row, context.project.project_id, context_tokens, current)
            # Source diversity applies only to surfaced results; all reasons
            # remain auditable in the candidate decision list.
            if candidate["decision"] == "surface" and candidate["source"] in source_seen:
                candidate["decision"], candidate["suppression_reason"] = "suppressed", "source_diversity"
            elif candidate["decision"] == "surface":
                source_seen.add(candidate["source"])
            ranked.append(candidate)
        surfaces = [item for item in ranked if item["decision"] == "surface"]
        for item in surfaces[self.settings.max_results:]:
            item["decision"], item["suppression_reason"] = "suppressed", "result_cap"
        for item in ranked:
            self._remember(item, context.project.project_id, current)
        ranked.sort(key=lambda item: (-item["score"], item["title"].lower()))
        if not dry_run:
            self.store.create_relevance_run({
                "run_id": run_id, "project_id": context.project.project_id, "project_name": context.project.name,
                "started_at": current, "completed_at": current, "status": "completed",
                "context": {"files_touched": context.files_touched[:50], "event_counts": context.event_counts_by_type},
            }, ranked)
        return RelevanceResult(run_id, context.project.project_id, context.project.name, ranked)

    def _document(self, source: str, source_id: str, title: str, text: str, tags: list[Any], project_ids: list[Any], updated_at: Any, metadata: dict[str, Any]) -> dict[str, Any]:
        candidate_id = f"{source}:{source_id}"
        normalized = "\n".join((title, text, json.dumps(tags, sort_keys=True)))
        return {"candidate_id": candidate_id, "source": source, "source_id": source_id, "title": title,
                "text": text, "tags": [str(x) for x in tags], "project_ids": [str(x) for x in project_ids],
                "updated_at": updated_at, "content_hash": hashlib.sha256(normalized.encode()).hexdigest(), "metadata": metadata}

    def _rank_row(self, row: Any, project_id: str, context_tokens: set[str], now: float) -> dict[str, Any]:
        title, text = str(row["title"]), str(row["text_content"])
        item_tokens = _tokens(title + " " + text)
        overlap = sorted(context_tokens & item_tokens)
        lexical = len(overlap) / max(1, len(context_tokens))
        tags = set(json.loads(row["tags_json"] or "[]"))
        tag_overlap = len(context_tokens & _tokens(" ".join(tags))) / max(1, len(context_tokens))
        projects = set(json.loads(row["project_ids_json"] or "[]"))
        explicit = 1.0 if project_id in projects else 0.0
        score = round(min(1.0, lexical * 0.7 + tag_overlap * 0.15 + explicit * 0.35), 4)
        explanation = {"lexical_match": round(lexical, 4), "tag_overlap": round(tag_overlap, 4),
                       "concept_overlap": overlap, "explicit_relation": explicit, "semantic_similarity": None,
                       "novelty": 1.0, "feedback_adjustment": 0.0, "final_score": score}
        decision, reason = "surface", None
        memory = self.store.get_relevance_memory(str(row["candidate_id"]), str(row["source"]), project_id)
        status = memory["status"] if memory else None
        defer_set_at = memory["defer_next_session_set_at"] if memory else None
        excluded_projects = set(json.loads(row["metadata_json"] or "{}").get("excluded_projects") or [])
        if project_id in excluded_projects:
            decision, reason = "suppressed", "excluded_by_metadata"
        elif score < self.settings.minimum_score:
            decision, reason = "suppressed", "below_threshold"
        elif status == "not_related":
            decision, reason = "suppressed", "not_related"
        elif status == "useful":
            decision, reason = "suppressed", "already_useful"
        elif defer_set_at and not self.store.has_activity_session_started_since(project_id, float(defer_set_at)):
            decision, reason = "suppressed", "deferred_until_next_session"
        elif memory and memory["snoozed_until"] and float(memory["snoozed_until"]) > now:
            decision, reason = "suppressed", "snoozed"
        elif memory and memory["last_dismissed_at"]:
            decision, reason = "suppressed", "dismissed"
        elif memory and memory["last_surfaced_at"] and now - float(memory["last_surfaced_at"]) < self.settings.cooldown_hours * 3600:
            decision, reason = "suppressed", "cooldown"
        return {"candidate_id": row["candidate_id"], "source": row["source"], "title": title, "score": score,
                "decision": decision, "suppression_reason": reason, "explanation": explanation}

    def _remember(self, candidate: dict[str, Any], project_id: str, now: float) -> None:
        previous = self.store.get_relevance_memory(candidate["candidate_id"], candidate["source"], project_id)
        surfaced = candidate["decision"] == "surface"
        self.store.upsert_relevance_memory({
            "candidate_id": candidate["candidate_id"], "source": candidate["source"], "project_id": project_id,
            "first_seen_at": previous["first_seen_at"] if previous else now, "last_considered_at": now,
            "last_surfaced_at": now if surfaced else (previous["last_surfaced_at"] if previous else None),
            "surfaced_count": (int(previous["surfaced_count"]) if previous else 0) + int(surfaced),
            "last_dismissed_at": previous["last_dismissed_at"] if previous else None,
            "dismissal_count": previous["dismissal_count"] if previous else 0,
            "snoozed_until": previous["snoozed_until"] if previous else None,
            "accepted_at": previous["accepted_at"] if previous else None, "most_recent_score": candidate["score"],
            "evidence": candidate["explanation"],
            # A routine ranking pass must never clear a relationship decision
            # (Useful / Not Related / Deferred) -- only `set_item_relationship`
            # changes these, so they are always carried forward unchanged here.
            "status": previous["status"] if previous else None,
            "reason": json.loads(previous["reason_json"] or "{}") if previous else {},
            "defer_next_session_set_at": previous["defer_next_session_set_at"] if previous else None,
        })
