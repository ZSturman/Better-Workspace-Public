"""v2's Notion Projects cache: the project-identity link between a v2 local
project and the existing Notion Projects database.

Purely so a Work Log draft can carry the right Notion "project" relation --
matches this repo's own `projects` table (see `projects_v2.py`) to pages in
the existing Notion Projects database. Reuses `notion_client_v2.py`'s
`ExistingProjectsAdapter`/`credential_token` (the one bridge to the
`notion_api` client) rather than a second Notion HTTP implementation.

Deliberately simple matching, because it doesn't need to be anything else:
every v2 project comes from exactly one canonical `Projects/<name>` tree, so
an exact local-directory path match, then an unambiguous project-name
match, covers a project observed today. This cache is not a historical
reconciliation tool -- a Notion project with no current local match just
stays unmapped until (if ever) a matching local directory shows up; nothing
here tries to resolve old aliases or past naming.
"""

from __future__ import annotations

from datetime import datetime
from pathlib import Path
from typing import Any

from .core_config import NotionSettings
from .core_store import CoreStore
from .notion_client_v2 import ExistingProjectsAdapter, NotionCacheError, _lookup, _normalized_path

STATE_LAST_ATTEMPT = "notion_projects.last_attempt"
STATE_LAST_SUCCESS = "notion_projects.last_success"
STATE_LAST_ERROR = "notion_projects.last_error"


class NotionProjectCache:
    def __init__(self, store: CoreStore, workspace_root: Path, settings: NotionSettings, *, adapter: Any | None = None) -> None:
        self.store = store
        self.workspace_root = workspace_root
        self.settings = settings
        self.adapter = adapter or ExistingProjectsAdapter(workspace_root, settings)

    def is_due(self, now: str) -> bool:
        if not self.settings.enabled:
            return False
        last = self.store.get_state(STATE_LAST_ATTEMPT)
        if not last or "at" not in last:
            return True
        elapsed = (datetime.fromisoformat(now) - datetime.fromisoformat(last["at"])).total_seconds()
        return elapsed >= self.settings.refresh_minutes * 60

    def refresh_if_due(self, now: str) -> dict[str, Any] | None:
        return self.refresh(now) if self.is_due(now) else None

    def refresh(self, now: str) -> dict[str, Any]:
        self.store.set_state(STATE_LAST_ATTEMPT, {"at": now}, now)
        if not self.settings.enabled:
            return {"ok": False, "skipped": True, "reason": "notion_disabled"}
        try:
            pages = self.adapter.fetch_projects()
            records = self._records_with_local_mapping(pages)
            self.store.replace_notion_project_cache(records, now)
            self._apply_organization(records, now)
            self.store.set_state(STATE_LAST_SUCCESS, {"at": now}, now)
            self.store.set_state(STATE_LAST_ERROR, {"error": None}, now)
            return {"ok": True, "projects": len(records)}
        except NotionCacheError as exc:
            self.store.set_state(STATE_LAST_ERROR, {"error": str(exc)}, now)
            return {"ok": False, "projects": len(self.store.cached_notion_projects()), "error": str(exc)}

    def status(self) -> dict[str, Any]:
        return {
            "enabled": self.settings.enabled,
            "cached_projects": len(self.store.cached_notion_projects()),
            "last_attempt": self.store.get_state(STATE_LAST_ATTEMPT),
            "last_success": self.store.get_state(STATE_LAST_SUCCESS),
            "last_error": self.store.get_state(STATE_LAST_ERROR),
        }

    def create_project(self, *, name: str, local_directory: Path, now: str) -> str:
        """Create an explicitly requested page, then refresh the authoritative cache.

        This is intentionally separate from ordinary discovery. Discovering a
        folder must never write to Notion; only the user-facing creation
        action is allowed to make this remote mutation.
        """
        if not self.settings.enabled:
            raise NotionCacheError("Notion project creation is unavailable because [workspace_watcher.notion].enabled is false.")
        page = self.adapter.create_project(name=name, local_directory=str(local_directory.resolve()))
        page_id = str(page.get("id") or "")
        if not page_id:
            raise NotionCacheError("Notion created a project response without a page ID.")
        refreshed = self.refresh(now)
        if not refreshed.get("ok"):
            raise NotionCacheError(str(refreshed.get("error") or "The new Notion project could not be refreshed."))
        return page_id

    def _records_with_local_mapping(self, pages: Any) -> list[dict[str, Any]]:
        local_projects = list(self.store.projects(status=None))
        records: list[dict[str, Any]] = []
        for page in pages:
            properties = page.get("properties") if isinstance(page.get("properties"), dict) else {}
            name = str(_lookup(properties, "Name", "title") or "").strip()
            page_id = str(page.get("id") or "")
            if not page_id or not name:
                continue
            local_directory = str(_lookup(properties, "Local Directory") or "").strip()
            local, reason = self._match_local_project(name, local_directory, local_projects)
            records.append({
                "notion_project_id": page_id,
                "project_id": local["id"] if local else None,
                "name": name,
                "local_directory": local_directory,
                "metadata": {"mapping_reason": reason},
                "domain": _lookup(properties, "Domain"),
                "tags": _lookup(properties, "Tags") or [],
                # The human "am I actively pursuing this?" answer, which is
                # unrelated to `projects.status` (a filesystem
                # active/deleted fact -- see docs/project-scoring.md).
                "status_label": _lookup(properties, "Status"),
                "mediums": _lookup(properties, "Mediums", "Medium") or [],
            })
        return records

    def _apply_organization(self, records: list[dict[str, Any]], now: str) -> None:
        """Mirror Domain/Status/Mediums/Tags into this app's own tables.

        Notion is today's only real source for these fields -- confirmed
        against production data, where 281 of 283 pages carry a Domain while
        382 of 383 local `Project.betterproject` documents are bare
        manifests. Mirroring them locally is what makes `By Domain`/`By
        Medium`/`By Status` browsing work, and work offline afterwards.

        Mirrored values are written to the mirror columns only. A local edit
        lives in the separate `*_local` columns and always wins (see
        `CoreStore.set_project_field`), so a refresh can run as often as it
        likes without ever undoing a deliberate local change -- the reason
        the previous version of this method, which wrote straight over
        `projects.domain`, could not be allowed to also own Status.
        """
        for record in records:
            project_id = record.get("project_id")
            if not project_id:
                continue
            for field, key in (("domain", "domain"), ("status_label", "status_label")):
                value = record.get(key)
                self.store.set_project_mirrored_field(project_id, field, value.strip() if isinstance(value, str) else None, now)
            self._mirror_tags(project_id, record.get("tags") or [], now, category=None)
            self._mirror_tags(project_id, record.get("mediums") or [], now, category="medium")

    def _mirror_tags(self, project_id: str, names: Any, now: str, *, category: str | None) -> None:
        tag_ids: list[str] = []
        for name in names if isinstance(names, list) else []:
            cleaned = str(name).strip()
            if not cleaned:
                continue
            try:
                tag = self.store.create_tag(cleaned, provenance="notion", category=category)
            except ValueError:
                continue  # a label with no letters or numbers is not a tag
            tag_ids.append(tag["id"])
        if category is None:
            # Freeform tags also come from the filesystem and from the person
            # directly, so this mirror only ever adds: reconciling them would
            # delete pairings Notion never knew about.
            for tag_id in tag_ids:
                self.store.assign_project_tag(project_id, tag_id, now, source="notion")
            return
        self.store.replace_mirrored_project_tags(project_id, tag_ids, now, category=category)

    def _match_local_project(self, name: str, local_directory: str, local_projects: list[Any]) -> tuple[Any | None, str | None]:
        if local_directory:
            candidate_paths = [_normalized_path(local_directory)]
            if not Path(local_directory).expanduser().is_absolute():
                candidate_paths.append(_normalized_path(str(self.workspace_root / local_directory)))
            for project in local_projects:
                project_path = _normalized_path(str(self.workspace_root / project["path"]))
                if project_path in candidate_paths:
                    return project, "notion_local_directory"
        if local_directory:
            # A Local Directory property was set but pointed nowhere local
            # exists -- worth distinguishing from "no directory recorded at
            # all" (both real cases seen against production data: an
            # archived/deleted local folder Notion still remembers).
            reason_if_unmatched = "stale_local_directory"
        else:
            reason_if_unmatched = None
        normalized_name = name.casefold().strip()
        matching = [project for project in local_projects if str(project["name"]).casefold().strip() == normalized_name]
        if len(matching) == 1:
            return matching[0], "project_name"
        if len(matching) > 1:
            # Ambiguous, not absent -- a human should see this distinctly
            # from "no local project has this name at all" (currently zero
            # cases in production, but the diagnostic must not silently
            # collapse this into "unmatched" if it ever happens).
            return None, "ambiguous_name"
        return None, reason_if_unmatched
