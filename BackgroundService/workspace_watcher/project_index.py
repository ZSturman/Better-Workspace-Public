"""Local, rebuildable project read model for native clients.

The index deliberately reads only immediate children of ``Workspace/Projects``.
It is rebuilt at startup/recovery and incrementally refreshed after a settled
project-root event; normal source-file activity never triggers a workspace
scan.  Project JSON remains the only writable project authority.
"""

from __future__ import annotations

import json
import logging
import time
from pathlib import Path
from typing import Any, Callable

from .projects import ProjectRegistry
from .store import WorkspaceStore


ENTITY_DIRS = {
    "task": "tasks", "milestone": "milestones", "feature": "features",
    "idea": "ideas", "session": "sessions", "work_log": "work-logs",
    "collection": "collections", "resource": "resources", "version": "versions",
    "asset": "assets", "note": "notes",
}


class ProjectIndex:
    """Maintains SQLite presentation data and durable reconciliation issues."""

    def __init__(
        self, store: WorkspaceStore, registry: ProjectRegistry, workspace_root: Path,
        projects_relpath: str, logger: logging.Logger,
        notify: Callable[[str, str], None] | None = None,
    ) -> None:
        self.store = store
        self.registry = registry
        self.workspace_root = workspace_root
        self.projects_relpath = projects_relpath.strip("/")
        self.logger = logger
        self.notify = notify

    def rebuild(self, *, reason: str) -> dict[str, int]:
        """Rebuild from local folders and canonical metadata only."""
        now = time.time()
        root = self.workspace_root / self.projects_relpath
        records: list[dict[str, Any]] = []
        current_issue_ids: set[str] = set()
        unknown = 0
        if root.is_dir():
            for folder in sorted(root.iterdir(), key=lambda item: item.name.casefold()):
                if not folder.is_dir() or folder.name.startswith("."):
                    continue
                relative = f"{self.projects_relpath}/{folder.name}"
                ref = self.registry.ensure_project(relative, folder, now)
                metadata = self._read_json(folder / ".project" / "project.json")
                managed = self._is_project_metadata(metadata)
                project_id = str(metadata["id"]) if managed else ref.project_id
                record = {
                    "project_id": project_id,
                    "watcher_project_id": ref.project_id,
                    "path": str(folder.resolve()),
                    "name": str(metadata.get("name") or folder.name) if managed else folder.name,
                    "managed": managed,
                    "metadata": metadata if managed else {},
                    "entities": self._entities(folder, project_id) if managed else [],
                }
                records.append(record)
                issue_id = f"unknown-local-folder:{ref.project_id}"
                current_issue_ids.add(issue_id)
                if managed:
                    # A local creation/link has made the old finding obsolete.
                    self.store.set_reconciliation_issue_state(issue_id, "resolved", now)
                else:
                    unknown += 1
                    created = self.store.upsert_reconciliation_issue(
                        issue_id, "unknown_local_folder", project_id, str(folder.resolve()), "warning",
                        {"folder_name": folder.name, "path": str(folder.resolve()), "detected_via": reason}, now,
                    )
        # A folder moved away or deleted since the previous scan is no longer
        # actionable reconciliation work.
        for issue in self.store.reconciliation_issues("open"):
            if issue["kind"] == "unknown_local_folder" and issue["issue_id"] not in current_issue_ids:
                self.store.set_reconciliation_issue_state(issue["issue_id"], "resolved", now)
        self.store.replace_local_project_index(records, now)
        generation = int(self.store.get_state("project_index.generation") or 0) + 1
        self.store.set_state("project_index.generation", generation)
        self.store.set_state("project_index.last_rebuild", {"at": now, "reason": reason, "projects": len(records)})
        return {"projects": len(records), "unknown": unknown, "generation": generation}

    def notify_if_actively_used(self, watcher_project_id: str, now: float | None = None) -> bool:
        """Notify once only after an unmanaged folder becomes the active project.

        Discovery is intentionally quiet: a folder merely existing under
        Projects is not evidence that it is a project someone is working in.
        """
        record = self.store.local_project_index_record_for_watcher(watcher_project_id)
        if record is None or bool(record["managed"]):
            return False
        issue_id = f"unknown-local-folder:{watcher_project_id}"
        issue = next((row for row in self.store.reconciliation_issues("open") if row["issue_id"] == issue_id), None)
        if issue is None or issue["notification_state"] == "notified":
            return False
        self._notify_once(issue_id, record["name"], time.time() if now is None else now)
        return True

    def _notify_once(self, issue_id: str, name: str, now: float) -> None:
        if not self.notify:
            return
        try:
            self.notify("New Project Folder Found", f'“{name}” isn’t connected to a project. Review it in Project Finder.')
            self.store.mark_reconciliation_issue_notified(issue_id, now)
        except Exception:  # Notification delivery must never affect indexing.
            self.logger.exception("Project discovery notification failed for %s", name)

    @staticmethod
    def _read_json(path: Path) -> dict[str, Any]:
        try:
            value = json.loads(path.read_text(encoding="utf-8"))
            return value if isinstance(value, dict) else {}
        except (OSError, json.JSONDecodeError):
            return {}

    @staticmethod
    def _is_project_metadata(value: dict[str, Any]) -> bool:
        return isinstance(value.get("id"), str) and bool(value["id"]) and isinstance(value.get("name"), str)

    def _entities(self, folder: Path, project_id: str) -> list[dict[str, Any]]:
        entities: list[dict[str, Any]] = []
        for kind, dirname in ENTITY_DIRS.items():
            directory = folder / ".project" / dirname
            if not directory.is_dir():
                continue
            for path in sorted(directory.glob("*.json")):
                data = self._read_json(path)
                if isinstance(data.get("id"), str) and data.get("project_id") == project_id:
                    entities.append({**data, "kind": kind})
        return entities
