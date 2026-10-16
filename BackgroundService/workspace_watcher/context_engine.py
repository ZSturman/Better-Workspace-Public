"""Owns everything downstream of intent-folder filesystem facts: one failure
boundary, safe to fully disable, for intent-folder item indexing, tag-based
contextual resurfacing, the reminder/condition engine, and the aggregated
native notifications those two produce. None of it can affect filesystem
sensing, and every optional piece (LM Studio tagging, notifications)
degrades to "skipped" rather than raising.
"""

from __future__ import annotations

import logging
import time
import uuid
from typing import Any

from .client import ProjectActivityContext
from .config import Config
from .events import EventType, NormalizedEvent
from .intent import IntentFolderIndex, IntentItemIndex, classify_intent
from .lm_tagging import LMStudioItemAnalyzer, process_item
from .nudges import NudgeCandidate, NudgeEngine
from .reminders import ReminderEngine
from .relevance import RelevanceEngine
from .store import WorkspaceStore


class ContextEngine:
    def __init__(self, store: WorkspaceStore, config: Config, logger: logging.Logger) -> None:
        self.store = store
        self.config = config
        self.logger = logger
        self.intent_index = IntentFolderIndex.from_config(config)
        self.items = IntentItemIndex(store, config.workspace_root)
        self.relevance = RelevanceEngine(store, config.relevance)
        self.reminders = ReminderEngine(store, config)
        self.nudges = NudgeEngine(store, config.nudges)

    def start(self, now: float | None = None) -> None:
        if not self.config.intent.enabled:
            return
        try:
            summary = self.items.rebuild(self.config, reason="startup")
            self.logger.info("Intent item index: %d folder(s), %d item(s)", summary["folders"], summary["items"])
        except Exception:
            self.logger.exception("Intent item index startup rebuild failed")

    def process_event(self, event: NormalizedEvent) -> None:
        if not self.config.intent.enabled:
            return
        try:
            if event.type == EventType.PROJECT_ACTIVE_CHANGED and event.project_id:
                self._on_project_active(event)
                return
            match = classify_intent(event.path, self.config, self.intent_index)
            if match is None:
                return
            if match.is_folder_root:
                if event.type in (EventType.CREATED, EventType.DELETED, EventType.RENAMED, EventType.MOVED):
                    self.items.rebuild(self.config, reason=f"folder_root_{event.type}")
                return
            self.items.refresh_item(match, now=event.ts)
        except Exception:
            self.logger.exception("Context engine failed while processing event %s", event.event_id)

    def tick(self, now: float | None = None) -> None:
        if not self.config.intent.enabled:
            return
        current = time.time() if now is None else now
        try:
            self._consider_due_reminders(current)
        except Exception:
            self.logger.exception("Reminder evaluation failed")
        try:
            self._process_lm_tagging_batch()
        except Exception:
            self.logger.exception("LM Studio item tagging batch failed")

    # -- automatic contextual resurfacing -------------------------------------

    def _on_project_active(self, event: NormalizedEvent) -> None:
        """The recommended external trigger for relevance (see docs/relevance.md):
        run once when a project becomes active, never per filesystem event."""
        if not self.config.relevance.enabled:
            return
        context = self._project_activity_context(event.project_id, event.project_name)
        if context is None:
            return
        result = self.relevance.run(context, now=event.ts)
        self._notify_contextual_matches(context.project.name, event.project_id, result.candidates, event.ts)

    def _project_activity_context(self, project_id: str, project_name: str | None) -> ProjectActivityContext | None:
        from .client import ProjectSummary

        row = self.store.get_project(project_id)
        if row is None:
            return None
        since_ts = time.time() - 24 * 3600
        events = self.store.recent_events(limit=200, project_id=project_id, meaningful_only=True, since_ts=since_ts)
        files, seen, counts = [], set(), {}
        for e in events:
            counts[e["type"]] = counts.get(e["type"], 0) + 1
            if not e["is_directory"] and e["path"] not in seen:
                seen.add(e["path"])
                files.append(e["path"])
        timestamps = [e["ts"] for e in events]
        return ProjectActivityContext(
            project=ProjectSummary(row["project_id"], row["name"], row["path"], row["first_seen_at"], row["last_activity_at"], row["meaningful_event_count"], row["status"]),
            window_hours=24.0, recent_events=[dict(e) for e in events], files_touched=files,
            event_counts_by_type=counts, first_activity_in_window=min(timestamps) if timestamps else None,
            last_activity_in_window=max(timestamps) if timestamps else None,
        )

    def _notify_contextual_matches(self, project_name: str, project_id: str, candidates: list[dict[str, Any]], now: float) -> None:
        by_folder: dict[str, list[dict[str, Any]]] = {}
        for candidate in candidates:
            if candidate["decision"] != "surface" or not str(candidate["source"]).startswith("intent:"):
                continue
            folder_name = str(candidate["source"]).split(":", 1)[1]
            folder_cfg = next((f for f in self.config.intent_folders if f.name == folder_name), None)
            if folder_cfg is None or not folder_cfg.notifications.contextual_matches:
                continue
            by_folder.setdefault(folder_name, []).append(candidate)
        for folder_name, items in by_folder.items():
            folder_cfg = next((f for f in self.config.intent_folders if f.name == folder_name), None)
            noun = (folder_cfg.semantic_type if folder_cfg and folder_cfg.semantic_type else folder_name).replace("_", " ")
            message = (
                f"There is a potentially useful {noun} item for {project_name}."
                if len(items) == 1 else
                f"{len(items)} potentially useful {noun} items were found for {project_name}."
            )
            self.nudges.consider(NudgeCandidate(
                rule="intent_contextual_match", message=message, confidence=0.6,
                evidence={"folder": folder_name, "items": [{"title": i["title"], "score": i["score"]} for i in items]},
                project_id=project_id, project_name=project_name, bypass_master_switch=True,
            ), now)

    # -- reminders / due actionable items --------------------------------------

    def _consider_due_reminders(self, now: float) -> None:
        due_by_folder = self.reminders.due_items(now)
        for folder_name, items in due_by_folder.items():
            folder_cfg = next((f for f in self.config.intent_folders if f.name == folder_name), None)
            if folder_cfg is None or not folder_cfg.notifications.due:
                continue
            message = (
                f"1 item in \"{folder_name}\" is due for review."
                if len(items) == 1 else
                f"{len(items)} items in \"{folder_name}\" are due for review."
            )
            self.nudges.consider(NudgeCandidate(
                rule="intent_due", message=message, confidence=0.6,
                evidence={"folder": folder_name, "items": [item["path"] for item in items]},
                bypass_master_switch=True,
            ), now)

    # -- LM Studio tag/summary inference (bounded, opportunistic) -------------

    def _process_lm_tagging_batch(self) -> None:
        wanted_folders = {f.name: f for f in self.config.intent_folders if f.lm_studio.classify or f.lm_studio.summarize}
        if not wanted_folders:
            return
        analyzer = LMStudioItemAnalyzer(
            self.config.work_logs.llm_endpoint, self.config.work_logs.llm_model, self.config.work_logs.llm_timeout_seconds,
        )
        processed = 0
        for item in self.store.all_items(only_existing=True):
            if processed >= self.config.intent.lm_batch_size:
                break
            folder_cfg = wanted_folders.get(item["intent_folder"])
            if folder_cfg is None:
                continue
            result = process_item(self.store, item, analyzer, classify=folder_cfg.lm_studio.classify, summarize=folder_cfg.lm_studio.summarize)
            if result["status"] != "unchanged":
                processed += 1
                if result["status"] == "failed":
                    self.logger.debug("LM Studio item tagging failed for %s: %s", item["path"], result.get("error"))

    # -- relationship decisions (CLI-driven) -----------------------------------

    def record_relationship(
        self, item_id: str, project_id: str, status: str, *, reason: dict[str, Any] | None = None,
        defer_until: float | None = None, defer_next_session: bool = False, log_work_log: bool = True,
        now: float | None = None,
    ) -> None:
        item = self.store.get_item(item_id)
        if item is None:
            raise ValueError(f"Unknown item: {item_id}")
        candidate_id = f"intent:{item['intent_folder']}:{item['path']}"
        source = f"intent:{item['intent_folder']}"
        now = time.time() if now is None else now
        self.store.set_item_relationship(candidate_id, source, project_id, status, now, reason=reason, defer_until=defer_until, defer_next_session=defer_next_session)
        if log_work_log and status in {"useful", "deferred", "archived"}:
            project = self.store.get_project(project_id)
            project_name = project["name"] if project else project_id
            summary = {
                "useful": f'Marked "{item["title"] or item["name"]}" useful for {project_name}.',
                "deferred": f'Deferred "{item["title"] or item["name"]}" ' + ("until next session on " if defer_next_session else "until later for ") + f"{project_name}.",
                "archived": f'Archived "{item["title"] or item["name"]}" after review for {project_name}.',
            }[status]
            self.store.add_work_log_manual_entry({
                "entry_id": str(uuid.uuid4()), "project_id": project_id, "project_name": project_name, "ts": now,
                "kind": f"item_{status}", "summary": summary,
                "metadata": {"item_id": item_id, "item_path": item["path"], "intent_folder": item["intent_folder"], "reason": reason or {}},
            })
