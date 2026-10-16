"""The Work Log pipeline: draft preparation from completed sessions, plus
optional Notion sync. This is the one authoritative Work Log implementation
in this codebase -- see ``docs/v2-work-log-system.md``.

Local-first: a Work Log draft is prepared from every completed session
regardless of whether Notion sync is enabled, so the local record is never
lost to a missing token or an outage. Notion sync
(``[workspace_watcher.work_logs].notion_sync``) is a strictly additive,
off-by-default upgrade, reusing the service's Notion client
(``notion_api``) via ``ExistingProjectsAdapter``
(``notion_client_v2.py``) -- there is exactly one Notion HTTP implementation
in this whole repo, not a second competing one.

Idempotency: a draft's id is a deterministic hash of (project_id, date_key)
-- see ``_draft_id`` -- so preparing the same project's same day twice
always upserts the same row, appending only genuinely new sessions, never
creating a duplicate draft. Notion sync itself is idempotent the same way
v1's is: a draft records its own ``notion_page_id`` once created, and every
later sync updates that same page instead of creating another one.
"""

from __future__ import annotations

import hashlib
import json
from datetime import datetime
from pathlib import Path
from typing import Any, Callable

from .core_config import LMStudioSettings, NotionSettings, WorkLogsSettings
from .core_engine import utc_now
from .core_store import CoreStore
from .lm_enrichment_v2 import LMEnrichmentService
from .notion_client_v2 import ExistingProjectsAdapter, NotionCacheError
from .sessions_v2 import Session


def _draft_id(project_id: str, date_key: str) -> str:
    return "worklog-" + hashlib.sha256(f"{project_id}\0{date_key}".encode()).hexdigest()[:24]


def _looks_like_page_gone(error: Exception) -> bool:
    """`notion_api.NotionClient` raises one flat `NotionError`
    for everything, with the HTTP status folded into the message text
    (``f"Notion HTTP {code}: {detail}"`` -- there's no structured status
    code to check). A 404 here means the specific page id we knew about no
    longer resolves -- deleted, or its parent database/permissions changed
    -- not a transient failure, so retrying the same update forever would
    never succeed."""
    message = str(error).lower()
    return "404" in message or "not_found" in message or "could not find" in message


def _iso_time(value: Any) -> str | None:
    if value in (None, ""):
        return None
    if isinstance(value, (int, float)):
        return datetime.fromtimestamp(value).astimezone().isoformat()
    return str(value)


class NotionWorkLogSync:
    """Writes only known, schema-discovered fields in the existing Work Log
    database. ``adapter`` defaults to a real ``ExistingProjectsAdapter``
    (the same client/token bridge the Notion project cache uses); tests
    inject a fake one so nothing here ever needs real Notion credentials or
    network access to be exercised."""

    def __init__(self, store: CoreStore, workspace_root: Path, settings: NotionSettings, *, adapter: Any | None = None) -> None:
        self.store = store
        self.workspace_root = workspace_root
        self.settings = settings
        self.adapter = adapter or ExistingProjectsAdapter(workspace_root, settings)

    def _properties(self, draft: dict[str, Any]) -> tuple[Any, str, dict[str, Any], Any]:
        client = self.adapter._client()  # intentionally the same client/token path as the Notion project cache and Task Management
        source_id = client.data_source_id(self.settings.work_log_database_id)
        source = client.data_source(source_id)
        try:
            from .notion_api import property_value
            from .notion_api import SchemaMap
        except Exception as exc:  # pragma: no cover - covered through adapter failure in normal use
            raise NotionCacheError(f"Existing Work Log schema helpers unavailable: {exc}") from exc
        schema = SchemaMap(source)
        payload = json.loads(draft["payload_json"] or "{}")
        properties: dict[str, Any] = {}
        title = schema.title()
        if title:
            properties[title.name] = property_value(title.kind, f"{draft['project_name']} — Workspace session")
        values = {
            "session start": _iso_time(payload.get("start")), "session end": _iso_time(payload.get("end")),
            "date": payload.get("date"), "what happened": payload.get("summary"),
            "progress summary": payload.get("summary"), "event_hash": draft["id"],
            "active seconds": round(float(payload.get("active_minutes") or 0) * 60),
            "sessions_count": payload.get("session_count"),
        }
        for field_name, value in values.items():
            ref = schema.find((field_name, field_name.replace("_", " ")), ("date", "rich_text", "number"))
            if ref and value is not None:
                properties[ref.name] = property_value(ref.kind, value)
        project_ref = schema.find(("project", "projects"), ("relation",))
        notion_id = self._notion_project_id(draft["project_id"])
        if project_ref and notion_id:
            properties[project_ref.name] = property_value(project_ref.kind, [notion_id])
        if not properties:
            raise NotionCacheError("Existing Work Log schema has no writable compatible fields")
        return client, source_id, properties, schema

    def _notion_project_id(self, project_id: str) -> str | None:
        row = self.store.notion_project_for(project_id)
        return str(row["notion_project_id"]) if row else None

    def _find_existing_page_by_hash(self, client: Any, source_id: str, schema: Any, draft_id: str) -> str | None:
        """Self-heals the crash window between a page being created and its
        id being saved locally: if the process died right after
        `create_page` succeeded but before the draft's `notion_page_id`
        committed, a naive retry would create a second page. Every page
        already carries its draft id in an `event_hash`-ish rich_text
        field (see `_properties`), so re-query for it before ever
        assuming "no existing page" -- the same safety net
        workspace_telemetry's own Notion writer already relies on
        (`_write_work_log` queries by its own event hash before writing).
        Best-effort: any failure here just falls through to a normal
        create rather than blocking sync over an extra safety check."""
        event_hash_ref = schema.find(("event_hash", "event hash"), ("rich_text",))
        if event_hash_ref is None:
            return None
        try:
            results = client.query(source_id, filter_payload={"property": event_hash_ref.name, "rich_text": {"equals": draft_id}}, limit=1)
        except Exception:
            return None
        if not results:
            return None
        return str(results[0].get("id") or "") or None

    def sync(self, draft: dict[str, Any]) -> str:
        client, source_id, properties, schema = self._properties(draft)
        existing_page_id = str(draft.get("notion_page_id") or "")
        if not existing_page_id:
            existing_page_id = self._find_existing_page_by_hash(client, source_id, schema, draft["id"]) or ""
        if existing_page_id:
            try:
                client.update_page(existing_page_id, properties)
                return existing_page_id
            except Exception as error:
                if not _looks_like_page_gone(error):
                    raise
                # The page we knew about was deleted/archived in Notion --
                # fall through to a fresh create rather than permanently
                # failing every future sync attempt for this draft (a
                # renamed/moved *project* is a separate, harmless case:
                # NotionProjectCache.refresh just stops mapping it, this
                # sync doesn't need to know or care).
        page = client.create_page(source_id, properties)
        return str(page.get("id") or "")

    def preview(self, draft: dict[str, Any]) -> dict[str, Any]:
        """Exactly what `sync()` would send -- same schema lookup, same
        property mapping -- but never calls `create_page`/`update_page`
        (including the pre-create existence check, which only ever reads)."""
        client, source_id, properties, schema = self._properties(draft)
        existing_page_id = str(draft.get("notion_page_id") or "")
        if not existing_page_id:
            existing_page_id = self._find_existing_page_by_hash(client, source_id, schema, draft["id"]) or ""
        return {
            "action": "update" if existing_page_id else "create",
            "notion_page_id": existing_page_id or None,
            "database_id": self.settings.work_log_database_id,
            "properties": properties,
        }


class WorkLogGenerator:
    def __init__(
        self,
        store: CoreStore,
        settings: WorkLogsSettings,
        notion_settings: NotionSettings,
        workspace_root: Path,
        *,
        sync: NotionWorkLogSync | None = None,
        lm_settings: LMStudioSettings | None = None,
        lm_service: LMEnrichmentService | None = None,
    ) -> None:
        self.store = store
        self.settings = settings
        self.notion_settings = notion_settings
        self.workspace_root = workspace_root
        self.sync = sync or NotionWorkLogSync(store, workspace_root, notion_settings)
        self.lm_service = lm_service or LMEnrichmentService(lm_settings or LMStudioSettings())

    def prepare(self, session: Session, *, status_if_new: str = "prepared", keep_existing_status: bool = False) -> dict[str, Any] | None:
        """Fold one completed session into its project-day draft.

        The live path always marks the draft ``prepared`` so a changed draft is synced
        again. The backfill passes ``status_if_new="backfilled"`` (a status Notion sync
        never selects) and ``keep_existing_status=True``, so reconstructed history never
        queues a Notion write of its own and never changes what a live draft was doing.
        """
        if not self.settings.enabled or session.status != "completed":
            return None
        if session.confidence < self.settings.minimum_session_confidence:
            return None
        date = datetime.fromisoformat(session.started_at).astimezone().date().isoformat()
        # Default policy merges a project's day into one useful Work Log. A
        # caller that disables it receives a deterministic record per
        # session instead, without changing the visible date in the draft.
        date_key = date if self.settings.merge_by_project_day else f"{date}:{session.id}"
        draft_id = _draft_id(session.project_id, date_key)
        existing = self.store.get_work_log_draft(draft_id)
        payload = json.loads(existing["payload_json"] or "{}") if existing else {}
        session_ids = list(json.loads(existing["session_ids_json"] or "[]")) if existing else []
        if session.id not in session_ids:
            session_ids.append(session.id)
        # A resumed session keeps the same `id` across each of its closes
        # (see sessions_v2.py's merge-nearby-into-the-same-id behavior), so a
        # later close of a session already represented here must *replace*
        # its stale fact, not skip re-adding it -- otherwise the draft keeps
        # reporting whatever files/event-count/confidence were true at the
        # session's *first* close forever, even once it's resumed further
        # and its final numbers have moved on.
        components = [item for item in (payload.get("sessions") or []) if item.get("session_id") != session.id]
        components.append(self._session_fact(session))
        combined = self.combined_payload(session.project_id, session.project_name, date, components)
        # Deterministic regeneration must never discard a prior LLM
        # enrichment -- carry it forward untouched. `enrich_pending()`'s own
        # evidence-hash check is what decides whether it's now stale and
        # needs regenerating; `prepare()` itself never touches this key.
        if "llm" in payload:
            combined["llm"] = payload["llm"]
        record = {
            "id": draft_id, "project_id": session.project_id, "project_name": session.project_name, "date_key": date_key,
            "session_ids": session_ids, "payload": combined,
            "status": (existing["status"] if keep_existing_status else "prepared") if existing else status_if_new,
            "notion_page_id": existing["notion_page_id"] if existing else None, "sync_error": None,
            "created_at": existing["created_at"] if existing else session.updated_at, "updated_at": session.updated_at,
        }
        self.store.upsert_work_log_draft(record)
        return record

    def enrich_pending(self, limit: int = 2, *, force: bool = False) -> list[dict[str, Any]]:
        """Runs the optional LM Studio enrichment pass over drafts whose
        evidence has changed (or, with `force=True`, all of them) since
        their last enrichment. Deliberately independent of Notion
        sync/status -- a purely local user with sync off still gets
        enrichment if they've enabled it. Called from the tick loop, never
        from the session.closed hook, so a slow/unreachable LM Studio can
        never delay saving the deterministic draft itself."""
        if not self.lm_service.settings.enabled:
            return []
        results: list[dict[str, Any]] = []
        for row in self.store.work_log_drafts(limit=limit * 6):
            if len(results) >= limit:
                break
            outcome = self._enrich_one(dict(row), force=force)
            if outcome is not None:
                results.append(outcome)
        return results

    def enrich_draft(self, draft_id: str, *, force: bool = True) -> dict[str, Any] | None:
        """Manual regeneration for one specific draft -- CLI/API entry
        point. Defaults to `force=True` since a human explicitly asking for
        this expects it to actually run, not be skipped by the
        unchanged-evidence check."""
        row = self.store.get_work_log_draft(draft_id)
        if row is None:
            return None
        return self._enrich_one(dict(row), force=force)

    def _enrich_one(self, row: dict[str, Any], *, force: bool) -> dict[str, Any] | None:
        llm_result = self.lm_service.enrich(row, force=force)
        if llm_result is None:
            return None
        payload = json.loads(row["payload_json"] or "{}")
        payload["llm"] = llm_result
        self.store.upsert_work_log_draft({
            "id": row["id"], "project_id": row["project_id"], "project_name": row["project_name"], "date_key": row["date_key"],
            "session_ids": json.loads(row["session_ids_json"] or "[]"), "payload": payload, "status": row["status"],
            "notion_page_id": row["notion_page_id"], "sync_error": row["sync_error"],
            "created_at": row["created_at"], "updated_at": row["updated_at"],
        })
        return {"draft_id": row["id"], "errors": llm_result.get("errors", {})}

    def sync_pending(self, limit: int = 3, *, now: str | None = None) -> list[dict[str, Any]]:
        """Best-effort Notion sync -- called from the tick loop, never from
        a live session-close event, so a slow/unreachable Notion can never
        delay filesystem sensing or session inference."""
        if not (self.settings.enabled and self.settings.notion_sync and self.notion_settings.enabled):
            return []
        if self.settings.authoritative_writer != "v2":
            # Third independent gate (see `WorkLogsSettings.authoritative_writer`):
            # even with `notion_sync=true`, refuse to write unless a human
            # has also explicitly declared v2 the writer of record. Prevents
            # an accidental flip of `notion_sync` alone from turning on a
            # fourth uncoordinated Notion writer next to the two legacy
            # systems still presumed active.
            return []
        current = now or utc_now()
        pending = self._pending(limit)
        results: list[dict[str, Any]] = []
        for row in pending:
            try:
                page_id = self.sync.sync(dict(row))
                self.store.mark_work_log_draft_sync(row["id"], "synced", notion_page_id=page_id, timestamp=current)
                results.append({"draft_id": row["id"], "status": "synced", "page_id": page_id})
            except Exception as exc:  # noqa: BLE001 - sync cannot affect later bookkeeping
                error = str(exc)[:300]
                self.store.mark_work_log_draft_sync(row["id"], "sync_failed", error=error, timestamp=current)
                results.append({"draft_id": row["id"], "status": "sync_failed", "error": error})
        return results

    def preview_pending(self, limit: int = 20) -> list[dict[str, Any]]:
        """Dry run: exactly what `sync_pending()` would send, with zero
        writes to Notion or to this draft's own status -- safe to call
        regardless of the `notion_sync` master switch, so a preview works
        even while real sync stays off."""
        if not self.notion_settings.enabled:
            return [{"draft_id": None, "error": "Notion is disabled ([workspace_watcher.notion].enabled = false)"}]
        previews: list[dict[str, Any]] = []
        for row in self._pending(limit):
            try:
                previews.append({"draft_id": row["id"], **self.sync.preview(dict(row))})
            except Exception as exc:  # noqa: BLE001 - a preview failure is just reported, never raised
                previews.append({"draft_id": row["id"], "error": str(exc)[:300]})
        return previews

    def _pending(self, limit: int) -> list[Any]:
        prepared = self.store.work_log_drafts(status="prepared", limit=limit)
        failed = self.store.work_log_drafts(status="sync_failed", limit=limit)
        return sorted([*prepared, *failed], key=lambda row: row["updated_at"])[:limit]

    def _session_fact(self, session: Session) -> dict[str, Any]:
        return {
            "session_id": session.id, "start": session.started_at, "end": session.ended_at,
            "active_seconds": round(session.active_seconds), "meaningful_event_count": session.meaningful_event_count,
            "files": session.files, "burst_count": session.burst_count, "confidence": session.confidence,
            "git": session.git, "open_reason": session.open_reason, "close_reason": session.close_reason,
            "longest_gap_seconds": round(session.longest_gap_seconds), "longest_burst_seconds": round(session.longest_burst_seconds),
            "evidence": session.evidence, "commits": session.commits,
        }

    @staticmethod
    def combined_payload(project_id: str, project_name: str, date_key: str, sessions: list[dict[str, Any]]) -> dict[str, Any]:
        files = list(dict.fromkeys(path for item in sessions for path in item.get("files") or []))[:100]
        active_seconds = sum(float(item.get("active_seconds") or 0) for item in sessions)
        elapsed_seconds = sum((datetime.fromisoformat(item["end"]) - datetime.fromisoformat(item["start"])).total_seconds() for item in sessions)
        event_count = sum(int(item.get("meaningful_event_count") or 0) for item in sessions)
        total_bursts = sum(int(item.get("burst_count") or 1) for item in sessions)
        interruptions = total_bursts - len(sessions)  # each session's own burst_count - 1, summed
        longest_burst = max((float(item.get("longest_burst_seconds") or 0) for item in sessions), default=0.0)
        resumed_count = sum(1 for item in sessions if item.get("open_reason") == "resumed")
        git = [item.get("git") for item in sessions if item.get("git")]
        # Sessions rebuilt from surviving journals (worklog_backfill.py) rather than
        # observed live. Said in the summary so a reader never mistakes one for the other.
        backfilled = sum(1 for item in sessions if ((item.get("evidence") or {}).get("provenance") or {}).get("source") == "backfill")
        commits = [commit for item in sessions for commit in item.get("commits") or []]
        terminal_commands = sum(int((item.get("evidence") or {}).get("terminal_commands") or 0) for item in sessions)
        deterministic = (
            f"{event_count} meaningful changes across {len(files)} file(s), with an estimated "
            f"{round(active_seconds / 60)} active minute(s) over {len(sessions)} session(s)"
            + (f" ({interruptions} interruption(s))" if interruptions else "")
            + (f", {len(commits)} commit(s)" if commits else "")
            + "."
            + ((" Reconstructed from the filesystem journal." if backfilled == len(sessions)
                else f" {backfilled} of {len(sessions)} session(s) reconstructed from the filesystem journal.") if backfilled else "")
        )
        return {
            "project_id": project_id, "project": project_name, "date": date_key,
            "start": min(item["start"] for item in sessions), "end": max(item["end"] for item in sessions),
            "active_minutes": round(active_seconds / 60, 1), "elapsed_minutes": round(elapsed_seconds / 60, 1),
            "meaningful_event_count": event_count, "files": files, "session_count": len(sessions),
            "resumed_session_count": resumed_count, "interruption_count": interruptions,
            "longest_uninterrupted_minutes": round(longest_burst / 60, 1),
            "git": git, "commits": commits[:20], "terminal_commands": terminal_commands,
            "backfilled_session_count": backfilled, "summary": deterministic,
            # Raw per-session evidence, deliberately kept alongside rather
            # than folded into the aggregate/summary above -- a reviewer (or
            # a later LLM enrichment pass) can always get back to exactly
            # which session contributed what, and why each was scored the
            # way it was (session["evidence"]["confidence_breakdown"]).
            "sessions": sessions,
        }
