"""Explainable, small folder-status policy and Finder presentation bridge."""

from __future__ import annotations

import json
import logging
import time
from pathlib import Path
from typing import Any

from .config import Config
from .finder_tags import apply_status_tag
from .reminders import ReminderEngine
from .store import WorkspaceStore


class StatusEngine:
    """Derives status from persisted evidence, not opaque classification."""

    def __init__(self, store: WorkspaceStore, config: Config, logger: logging.Logger) -> None:
        self.store, self.config, self.logger = store, config, logger

    def tick(self, now: float | None = None) -> list[dict[str, Any]]:
        if not self.config.status.enabled:
            return []
        current = time.time() if now is None else now
        changes: list[dict[str, Any]] = []
        live_paths: set[str] = set()
        for project in self.store.all_projects(status="active"):
            path = str(project["path"])
            if not (self.config.workspace_root / path).is_dir():
                # A move outside the watched root may not carry a usable
                # destination event. The bounded status pass is the safe
                # recovery point for this derived registry row.
                self.store.mark_project_status(project["project_id"], "deleted")
                self.store.delete_folder_status(path)
                continue
            live_paths.add(path)
            candidates, reasons = self._project_evidence(project, current)
            status = self._choose(candidates)
            changed = self.store.upsert_folder_status(path, project["project_id"], status, reasons, current)
            if changed:
                changes.append({"path": path, "project_id": project["project_id"], "status": status, "reasons": reasons})
                self._present(path, status)
        for row in self.store.folder_statuses():
            if row["project_id"] and row["path"] not in live_paths:
                self.store.delete_folder_status(row["path"])
        changes.extend(self._root_statuses(current))
        return changes

    def _project_evidence(self, project: Any, now: float) -> tuple[list[str], list[dict[str, Any]]]:
        candidates, reasons = [], []
        signals = self.store.project_signals(project["project_id"])
        failures = [s for s in signals if s["kind"] == "failure"]
        if len(failures) >= self.config.status.error_failure_threshold:
            candidates.append("error")
            reasons.append({"kind": "repeated_failures", "count": len(failures), "message": f"{len(failures)} unresolved failure signals."})
        elif signals:
            candidates.append("attention")
            reasons.append({"kind": "open_signal", "count": len(signals), "message": signals[0]["summary"]})
        indexed = self.store.local_project_index_record_for_watcher(project["project_id"])
        if indexed is not None and not bool(indexed["managed"]):
            candidates.append("unknown")
            reasons.append({"kind": "unmanaged_folder", "message": "Folder is not associated with canonical .project metadata."})
        if indexed is not None and bool(indexed["managed"]):
            metadata = json.loads(indexed["metadata_json"] or "{}")
            state = str(metadata.get("status", "")).lower()
            if state in {"blocked", "waiting", "on hold", "on_hold"}:
                candidates.append("blocked")
                reasons.append({"kind": "metadata_status", "message": f"Project metadata is {state}."})
            elif state in {"completed", "archived", "cancelled"}:
                candidates.append("completed")
                reasons.append({"kind": "metadata_status", "message": f"Project metadata is {state}."})
        active = self.store.get_state("active_project") or {}
        last = project["last_activity_at"]
        if active.get("project_id") == project["project_id"] and last and now - float(last) <= self.config.status.active_minutes * 60:
            candidates.append("active")
            reasons.append({"kind": "activity", "message": f"Meaningful activity within the last {self.config.status.active_minutes:g} minutes."})
        elif last and now - float(last) <= self.config.status.recent_days * 86400:
            candidates.append("recent")
            reasons.append({"kind": "recent_activity", "message": "Meaningful activity within the recent window."})
        elif last and now - float(last) >= self.config.status.stale_days * 86400:
            candidates.append("stale")
            reasons.append({"kind": "inactivity", "message": f"No meaningful activity for at least {self.config.status.stale_days:g} days."})
        else:
            candidates.append("normal")
            reasons.append({"kind": "default", "message": "No higher-priority status evidence."})
        return candidates, reasons

    def _root_statuses(self, now: float) -> list[dict[str, Any]]:
        # Roots deliberately have different semantics: TEMP's item queue and
        # Projects' reconciliation health matter, while Inspiration is a
        # reference area and Logs simply inherits normal state.
        roots: list[tuple[str, str, list[dict[str, Any]]]] = []
        issues = self.store.reconciliation_issues("open")
        project_states = [row for row in self.store.folder_statuses() if row["project_id"]]
        has_errors = any(row["status"] == "error" for row in project_states)
        projects_status = "error" if has_errors else ("attention" if issues else "normal")
        roots.append(("Projects", projects_status, [{"kind": "project_rollup", "message": f"{len(issues)} open reconciliation issue(s)." if issues else "No open reconciliation issues."}]))
        due = sum(len(items) for items in ReminderEngine(self.store, self.config).due_items(now).values())
        roots.append(("TEMP", "attention" if due else "normal", [{"kind": "due_items", "count": due, "message": f"{due} TEMP item(s) due for review."}]))
        for path, status in self.config.status.root_semantics.items():
            roots.append((path, status, [{"kind": "root_semantic", "message": f"Configured {status} top-level area."}]))
        changes = []
        for path, status, reasons in roots:
            if not (self.config.workspace_root / path).exists():
                continue
            if self.store.upsert_folder_status(path, None, status, reasons, now):
                changes.append({"path": path, "project_id": None, "status": status, "reasons": reasons})
                self._present(path, status)
        return changes

    def _choose(self, candidates: list[str]) -> str:
        for status in self.config.status.precedence:
            if status in candidates:
                return status
        return "normal"

    def _present(self, relative_path: str, status: str) -> None:
        if not self.config.status.apply_finder_tags:
            return
        path = self.config.workspace_root / relative_path
        if path.exists() and not apply_status_tag(path, status):
            self.logger.debug("Finder tag not applied to %s (unsupported or unavailable)", path)
