"""Versioned localhost HTTP contract for the native client and future iOS app."""

from __future__ import annotations

import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from urllib.parse import parse_qs, urlsplit


def _query_params(path: str) -> dict[str, list[str]]:
    return parse_qs(urlsplit(path).query)

from .core_config import CoreConfig
from .core_engine import IntentIndexer, utc_now
from .core_store import CoreStore
from .ideas_v2 import create_idea, idea_detail, ideas_notion_sync_enabled, list_ideas, resurfacing_view, set_ideas_notion_sync_enabled, update_idea, register_idea, relocate_idea
from .intents import IntentFolderDetector
from .project_files import ProjectFilesError, list_directory
from .project_model_v2 import build_project_views, project_detail
from .project_query_v2 import ensure_builtin_saved_views, filter_projects, group_projects, sort_projects
from .rules_v2 import load_rules
from .session_telemetry_v2 import live_session_view
from .work_logs_v2 import WorkLogGenerator
from .notion_client_v2 import NotionCacheError, credential_token
from .widget_snapshot import build_widget_snapshot, default_snapshot_path, read_widget_snapshot


def _diagnostics(store: CoreStore, config: CoreConfig) -> dict[str, Any]:
    """One consolidated "why/what state is this in" view -- everything a
    person would otherwise have to piece together from `./run.sh status`
    plus several separate endpoints, in one place for the native app and
    for debugging. Every sub-object here is read-only and already computed
    elsewhere; this just gathers it."""
    current_project = store.get_state("project.current")
    open_session = store.open_session()
    recent_sessions = store.recent_sessions(limit=20)
    drafts = store.work_log_drafts(limit=500)
    draft_counts: dict[str, int] = {}
    for row in drafts:
        draft_counts[row["status"]] = draft_counts.get(row["status"], 0) + 1
    return {
        "watcher_health": store.get_state("watcher.health"),
        # "The sensor is running" and "events are actually reaching the
        # application" are different claims: a downstream consumer can fail
        # while the watcher still reports running (see `Coalescer._run`).
        # Absent means no event has ever been dropped.
        "sensing_health": store.get_state("sensing.health") or {"state": "ok"},
        # What the ignore rules suppressed, so an over-broad pattern is
        # visible rather than silently hiding real work.
        "noise": store.get_state("noise.ignored_counts") or {"total": 0, "by_rule": {}},
        "rules_health": store.get_state("rules.health"),
        "hammerspoon_inbox_health": store.get_state("hammerspoon_inbox.health"),
        "notion_projects_health": store.get_state("notion_projects.health"),
        "project_graph_writer": store.get_state("project_graph.writer"),
        "work_logs_health": store.get_state("work_logs.health"),
        "last_reconcile": store.get_state("watcher.last_reconcile"),
        "current_project": current_project,
        "current_session": dict(open_session) if open_session else None,
        "recent_sessions": [
            {"id": row["id"], "project_name": row["project_name"], "status": row["status"],
             "close_reason": row["close_reason"], "open_reason": row["open_reason"],
             "started_at": row["started_at"], "ended_at": row["ended_at"], "confidence": row["confidence"]}
            for row in recent_sessions
        ],
        "work_log_draft_counts": draft_counts,
        "notion": {
            "enabled": config.notion.enabled,
            "cached_projects": len(store.cached_notion_projects()),
            "unmatched_cached_projects": sum(1 for row in store.cached_notion_projects() if row["project_id"] is None),
        },
        "work_logs_config": {
            "enabled": config.work_logs.enabled, "notion_sync": config.work_logs.notion_sync,
            "authoritative_writer": config.work_logs.authoritative_writer,
            # True only when both independent safety switches say "v2 may
            # actually write" -- the single fact the app/CLI should show a
            # person to answer "could v2 write to Notion right now?"
            "v2_writes_active": bool(config.work_logs.notion_sync and config.work_logs.authoritative_writer == "v2" and config.notion.enabled and (store.get_state("project_graph.writer") or {}).get("owner") != "better-workspace"),
        },
        "lm_studio": {"enabled": config.lm_studio.enabled, "endpoint": config.lm_studio.endpoint, "model": config.lm_studio.model or None,
                      "health": store.get_state("lm_studio.health")},
        "ideas": {"enabled": config.ideas.enabled, "notion_sync": ideas_notion_sync_enabled(store, config.ideas.notion_sync), "health": store.get_state("ideas_notion.health")},
    }


def serve(config: CoreConfig, host: str = "127.0.0.1", port: int = 8765, *, runtime: Any | None = None) -> ThreadingHTTPServer:
    detector = IntentFolderDetector(config.intent_settings)

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_: Any) -> None:
            return

        def _reply(self, payload: Any, status: int = 200) -> None:
            encoded = json.dumps({"schema_version": 1, "data": payload}, default=str).encode()
            self.send_response(status); self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(encoded))); self.end_headers(); self.wfile.write(encoded)

        def _body(self) -> dict[str, Any]:
            length = int(self.headers.get("Content-Length", "0"))
            try:
                value = json.loads(self.rfile.read(length) or b"{}")
            except json.JSONDecodeError as error:
                raise ValueError("request body must be JSON") from error
            if not isinstance(value, dict):
                raise ValueError("request body must be an object")
            return value

        def do_GET(self) -> None:  # noqa: N802
            from .scoring.api import dispatch
            if dispatch(self, config):
                return
            with CoreStore(config.database_path) as store:
                if self.path == "/v1/health": self._reply(store.get_state("watcher.health") or {"state": "stopped"})
                elif self.path == "/v1/notion/project-graph-writer": self._reply(store.get_state("project_graph.writer") or {"owner": None})
                elif self.path == "/v1/intents": self._reply([dict(row) for row in store.folders()])
                elif self.path == "/v1/items": self._reply([dict(row) for row in store.items()])
                elif self.path.startswith("/v1/events"): self._reply([dict(row) for row in store.recent_events()])
                elif self.path == "/v1/notifications": self._reply([dict(row) for row in store.notifications()])
                elif self.path == "/v1/messages": self._reply([dict(row) for row in store.messages()])
                elif self.path == "/v1/projects": self._reply([dict(row) for row in store.projects()])
                elif self.path == "/v1/projects/current": self._reply(store.get_state("project.current"))
                elif self.path.startswith("/v1/projects/ranked"):
                    limit = int(_query_params(self.path).get("limit", ["50"])[0])
                    views = sort_projects(build_project_views(store), "score", "desc")
                    self._reply(views[:limit])
                elif self.path.startswith("/v1/projects/") and "/files" in self.path:
                    # Browsing the project's real folder, one level at a
                    # time. `path` is project-relative; the resolver refuses
                    # anything that escapes the project directory.
                    project_id = self.path.split("/")[3]
                    project = store.project_by_id(project_id)
                    if project is None:
                        self._reply({"error": "project not found"}, 404); return
                    relative = _query_params(self.path).get("path", [""])[0]
                    try:
                        listing = list_directory(
                            config.workspace_root / project["path"], relative,
                            ignore_patterns=config.ignore_patterns,
                        )
                    except ProjectFilesError as error:
                        self._reply({"error": str(error)}, 400); return
                    self._reply(listing)
                elif self.path.startswith("/v1/projects/") and self.path.count("/") == 3:
                    detail = project_detail(store, self.path.rsplit("/", 1)[1], workspace_root=config.workspace_root)
                    self._reply(detail) if detail is not None else self._reply({"error": "project not found"}, 404)
                elif self.path.startswith("/v1/projects/") and self.path.endswith("/goals"):
                    project_id = self.path.split("/")[3]
                    self._reply([dict(row) for row in store.project_goals(project_id)])
                elif self.path == "/v1/session/live": self._reply(live_session_view(store, max_duration_minutes=config.sessions.max_duration_minutes))
                elif self.path == "/v1/saved-views":
                    ensure_builtin_saved_views(store)
                    self._reply([dict(row) for row in store.saved_views()])
                elif self.path == "/v1/sessions/current": self._reply(dict(row) if (row := store.open_session()) else None)
                elif self.path.startswith("/v1/sessions"): self._reply([dict(row) for row in store.recent_sessions()])
                # Drafts made only of automated bulk activity are kept for recovery, not reported as work.
                elif self.path == "/v1/work-logs": self._reply([dict(row) for row in store.work_log_drafts(limit=1000) if row["status"] != "automated"])
                # What each day's Work Log rests on: recorded live, reconstructed from the
                # surviving journals, or no evidence at all (see worklog_backfill.py).
                elif self.path == "/v1/work-logs/coverage": self._reply(store.get_state("work_logs.backfill") or {"days": {}})
                elif self.path == "/v1/work-logs/preview":
                    # A dry run still needs live Notion schema access (to
                    # show real field names), so this can fail with a clear
                    # per-item error when Notion is unreachable -- it never
                    # writes anything regardless.
                    generator = runtime.work_logs if runtime is not None else WorkLogGenerator(store, config.work_logs, config.notion, config.workspace_root)
                    self._reply(generator.preview_pending())
                elif self.path == "/v1/notion/projects": self._reply([dict(row) for row in store.cached_notion_projects()])
                elif self.path == "/v1/ideas": self._reply(list_ideas(store))
                elif self.path == "/v1/ideas/resurfacing": self._reply(resurfacing_view(store))
                elif self.path.startswith("/v1/ideas/") and self.path.count("/") == 3:
                    detail = idea_detail(store, self.path.rsplit("/", 1)[1])
                    self._reply(detail) if detail is not None else self._reply({"error": "idea not found"}, 404)
                elif self.path == "/v1/tags": self._reply([dict(row) for row in store.tags()])
                elif self.path == "/v1/relationships": self._reply([dict(row) for row in store.relationships()])
                elif self.path == "/v1/rules": self._reply([{"id": rule.id, "enabled": rule.enabled, "priority": rule.priority, "event": rule.when_event, "conditions": rule.conditions, "actions": list(rule.actions)} for rule in load_rules(config.rules_path)])
                elif self.path == "/v1/overview": self._reply({"intents": len(store.folders()), "items": len(store.items()), "events": len(store.recent_events(1000))})
                elif self.path == "/v1/diagnostics": self._reply(_diagnostics(store, config))
                elif self.path == "/v1/widgets/snapshot":
                    # WidgetKit retrieves only this compact projection. The
                    # extension never opens SQLite or starts the runtime.
                    #
                    # Deliberately does not ask the runtime to republish
                    # first. Publishing needs the pipeline lock, which the
                    # tick loop holds for the whole of its work -- including
                    # a Notion sync over the network -- so this route took 58
                    # seconds against the real workspace and WidgetKit's own
                    # timeout had already given up long before. Every widget
                    # showed "Waiting for Workspace Watcher" as a result.
                    #
                    # The tick loop republishes every second anyway (the
                    # publisher hashes the projection, so an unchanged
                    # snapshot costs nothing), and this handler's own
                    # connection can rebuild the projection if the file is
                    # somehow absent.
                    cached = read_widget_snapshot(default_snapshot_path(config.database_path))
                    self._reply(cached or build_widget_snapshot(store, max_duration_minutes=config.sessions.max_duration_minutes))
                elif self.path == "/v1/configuration": self._reply({"workspace_root": str(config.workspace_root), "database": str(config.database_path), "configured_search_roots": [str(root) for root in config.intent_settings.search_roots], "normalized_watch_roots": [str(root) for root in detector.settings.search_roots], "rules_file": str(config.rules_path)})
                elif self.path == "/v1/settings":
                    self._reply({
                        "notion_enabled": config.notion.enabled,
                        "ideas_notion_sync_enabled": ideas_notion_sync_enabled(store, config.ideas.notion_sync),
                        "ideas_notion_sync_default": config.ideas.notion_sync,
                        # Everything the app shows about the optional Notion integration:
                        # which databases, whether a token is present (never the token),
                        # which syncs are on, and how each last went.
                        "notion": {
                            "token_present": bool(credential_token(config.notion)),
                            "databases": {
                                "projects": config.notion.projects_database_id,
                                "work_log": config.notion.work_log_database_id,
                                "ideas": config.notion.ideas_database_id,
                            },
                            "projects_cache_health": store.get_state("notion_projects.health"),
                            "ideas_sync_health": store.get_state("ideas_notion.health"),
                            "ideas_sync_paused_until": (store.get_state("ideas_notion.paused_until") or {}).get("until"),
                            "work_logs_enabled": config.work_logs.enabled,
                            "work_logs_notion_sync": config.work_logs.notion_sync,
                            "work_logs_authoritative_writer": getattr(config.work_logs, "authoritative_writer", None),
                        },
                    })
                else: self._reply({"error": "not found"}, 404)

        def do_POST(self) -> None:  # noqa: N802
            try:
                body = self._body()
                from .scoring.api import dispatch
                if dispatch(self, config, body=body):
                    return
                if self.path in {"/v1/commands/scan", "/v1/commands/reconcile"}:
                    if runtime is not None: self._reply(runtime.reconcile_now())
                    else:
                        with CoreStore(config.database_path) as store: self._reply(IntentIndexer(detector, store).rebuild(initialize_missing_metadata=True))
                    return
                if self.path == "/v1/commands/reload-rules":
                    if runtime is None: raise ValueError("rule reload requires the running backend")
                    runtime.reload_rules(); self._reply(runtime.store.get_state("rules.health") or {}); return
                if self.path == "/v1/ideas/register":
                    with CoreStore(config.database_path) as store:
                        self._reply(register_idea(store, config.workspace_root / "Ideas", Path(str(body.get("path", "")))))
                    return
                if self.path.startswith("/v1/ideas/") and self.path.endswith("/relocate"):
                    with CoreStore(config.database_path) as store:
                        self._reply(relocate_idea(store, config.workspace_root, self.path.split("/")[3], str(body.get("source", "")), str(body.get("destination", ""))))
                    return
                if self.path == "/v1/projects/create":
                    if runtime is None: raise ValueError("project creation requires the running Workspace Watcher service")
                    self._reply(runtime.create_project(str(body.get("name") or "")), 201); return
                if self.path == "/v1/notion/projects/refresh":
                    if runtime is None: raise ValueError("Notion refresh requires the running Workspace Watcher service")
                    self._reply(runtime.refresh_notion_projects()); return
                if self.path == "/v1/commands/ideas-sync":
                    if runtime is None: raise ValueError("Idea Notion sync requires the running Workspace Watcher service")
                    self._reply(runtime.sync_ideas_now()); return
                if self.path.startswith("/v1/ideas/") and self.path.endswith("/resolve-conflict"):
                    item_id = self.path.split("/")[3]
                    with CoreStore(config.database_path) as store:
                        item = store.item_by_id(item_id)
                        if item is None:
                            self._reply({"error": "idea not found"}, 404); return
                        from .notion_ideas_v2 import IdeasNotionSync
                        sync = runtime.ideas_notion if runtime is not None else IdeasNotionSync(store, config.workspace_root, config.notion)
                        sync.resolve_conflict(Path(item["path"]), str(body.get("resolution", "")), utc_now())
                        store.update_notification_action(f"idea-conflict:{item_id}", "dismiss", utc_now())
                        self._reply(idea_detail(store, item_id))
                    return
                if self.path == "/v1/notion/project-graph-link":
                    if runtime is None: raise ValueError("Link acknowledgement requires the running background service")
                    with runtime._lock:
                        if (runtime.store.get_state("project_graph.writer") or {}).get("owner") != "better-workspace":
                            raise ValueError("Hand off Notion writing before acknowledging links")
                        record_id, page_id, kind = body.get("record_id"), body.get("page_id"), body.get("kind")
                        if not isinstance(record_id, str) or not isinstance(page_id, str) or not page_id:
                            raise ValueError("Record and page IDs are required")
                        if kind == "ideas":
                            if runtime.store.item_by_id(record_id) is None: raise ValueError("Idea not found")
                            old = runtime.store.idea_notion_link(record_id)
                            if old and old["notion_page_id"] and old["notion_page_id"] != page_id: raise ValueError("Idea already linked to another page")
                            runtime.store.upsert_idea_notion_link(record_id, notion_page_id=page_id, synced_hash=None, notion_last_edited_time=None, sync_error=None, timestamp=utc_now())
                        elif kind == "workLogs":
                            old = runtime.store.get_work_log_draft(record_id)
                            if old is None: raise ValueError("Work log not found")
                            if old["notion_page_id"] and old["notion_page_id"] != page_id: raise ValueError("Work log already linked to another page")
                            runtime.store.mark_work_log_draft_sync(record_id, "synced", notion_page_id=page_id, timestamp=utc_now())
                        else: raise ValueError("Unsupported service record type")
                    self._reply({"acknowledged": True}); return
                if self.path == "/v1/notion/project-graph-writer":
                    if body.get("owner") != "better-workspace":
                        raise ValueError("Unsupported Notion writer")
                    if runtime is None: raise ValueError("Writer handoff requires the running background service")
                    with runtime._lock:
                        runtime.store.set_state("project_graph.writer", {"owner": "better-workspace"}, utc_now())
                    self._reply({"owner": "better-workspace"}); return
                if self.path == "/v1/ideas":
                    with CoreStore(config.database_path) as store:
                        folder = next((row for row in store.folders() if row["name"].casefold() == "ideas"), None)
                        folder_path = Path(folder["path"]) if folder else (config.workspace_root / "Temporary" / "[[Ideas]]")
                        created = create_idea(store, folder_path, str(body.get("title", "")))
                    # A freshly created idea must be immediately visible over
                    # the API (the GUI creates then opens it right away), the
                    # same way `/v1/commands/scan` falls back to an inline
                    # reconcile when there's no long-lived runtime to ask.
                    if runtime is not None:
                        runtime.reconcile_now()
                    else:
                        with CoreStore(config.database_path) as store:
                            IntentIndexer(detector, store).rebuild(initialize_missing_metadata=True)
                    self._reply(created, 201); return
                with CoreStore(config.database_path) as store:
                    if self.path == "/v1/settings/ideas-notion-sync":
                        set_ideas_notion_sync_enabled(store, bool(body.get("enabled", False)), utc_now())
                        # A deliberate change of mind clears any back-off from a missing database.
                        store.set_state("ideas_notion.paused_until", {"until": None}, utc_now())
                        self._reply({"ideas_notion_sync_enabled": ideas_notion_sync_enabled(store, config.ideas.notion_sync)}); return
                    if self.path == "/v1/tags":
                        row = store.create_tag(str(body.get("display", ""))); self._reply(dict(row), 201); return
                    if self.path == "/v1/tags/rename":
                        store.rename_tag(str(body["tag_id"]), str(body["display"])); self._reply({"ok": True}); return
                    if self.path == "/v1/tags/alias":
                        store.add_tag_alias(str(body["tag_id"]), str(body["alias"])); self._reply({"ok": True}); return
                    if self.path == "/v1/tags/assign":
                        store.assign_tag(str(body["item_id"]), str(body["tag_id"])); self._reply({"ok": True}); return
                    if self.path == "/v1/tags/merge":
                        store.merge_tags(str(body["source_id"]), str(body["target_id"])); self._reply({"ok": True}); return
                    if self.path == "/v1/relationships":
                        relationship_id = store.create_relationship(str(body["from_id"]), str(body["to_id"]), str(body["type"]), __import__("datetime").datetime.now(__import__("datetime").timezone.utc).isoformat()); self._reply({"id": relationship_id}, 201); return
                    if self.path.startswith("/v1/notifications/") and self.path.endswith("/actions"):
                        notification_id = self.path.split("/")[3]
                        action = str(body.get("action", ""))
                        if action not in {"open", "review", "dismiss", "defer", "archive", "not_related"}: raise ValueError("unsupported notification action")
                        row = store.update_notification_action(notification_id, action, __import__("datetime").datetime.now(__import__("datetime").timezone.utc).isoformat(), body.get("defer_until"))
                        if row is None: self._reply({"error": "notification not found"}, 404); return
                        item = store.item_by_id(row["entity_id"]) if row["entity_id"] else None
                        if item and action in {"archive", "defer"}:
                            from .ideas_v2 import update_idea
                            changes = {"status": "archived"} if action == "archive" else {"defer_until": body.get("defer_until")}
                            update_idea(store, item["id"], changes)
                        store.record_event(__import__("workspace_watcher.core_events", fromlist=["WorkspaceEvent"]).WorkspaceEvent(type=f"notification.{action}", entity_id=row["entity_id"], payload={"notification_id": notification_id}, source="api"))
                        self._reply(dict(row)); return
                    if self.path.startswith("/v1/messages/") and self.path.endswith("/retry"):
                        if not store.retry_message(self.path.split("/")[3], __import__("datetime").datetime.now(__import__("datetime").timezone.utc).isoformat()): self._reply({"error": "message is not failed"}, 409)
                        else: self._reply({"ok": True})
                        return

                    # -- Project browsing/query (Finder-style smart views; see project_query_v2.py) --
                    if self.path == "/v1/projects/query":
                        views = build_project_views(store)
                        matched = filter_projects(views, body.get("query"))
                        matched = sort_projects(matched, body.get("sort_field", "score"), body.get("sort_direction", "desc"))
                        if body.get("group_by"):
                            self._reply({"groups": {key: value for key, value in group_projects(matched, body["group_by"]).items()}, "count": len(matched)})
                        else:
                            self._reply({"projects": matched, "count": len(matched)})
                        return
                    if self.path == "/v1/saved-views":
                        ensure_builtin_saved_views(store)
                        now = utc_now()
                        row = store.create_saved_view({
                            "id": __import__("uuid").uuid4().hex, "name": str(body["name"]), "query_json": json.dumps(body.get("query", {})),
                            "sort_field": str(body.get("sort_field", "score")), "sort_direction": str(body.get("sort_direction", "desc")),
                            "group_by": body.get("group_by"), "built_in": 0, "sort_order": 100,
                            "created_at": now, "updated_at": now,
                        })
                        self._reply(dict(row), 201); return

                    # -- Project domain/status/tags --
                    if self.path.endswith("/domain") and self.path.startswith("/v1/projects/"):
                        project_id = self.path.split("/")[3]
                        store.set_project_domain(project_id, body.get("domain") or None, utc_now())
                        self._reply({"ok": True}); return
                    # A local override of a Notion-mirrored organizational
                    # field. `clear: true` drops the local opinion and falls
                    # back to Notion, which is deliberately different from
                    # setting the value to empty (that is itself an opinion).
                    if self.path.endswith("/field") and self.path.startswith("/v1/projects/"):
                        project_id = self.path.split("/")[3]
                        field = str(body["field"])
                        if body.get("clear"):
                            store.clear_project_field_override(project_id, field, utc_now())
                        else:
                            store.set_project_field(project_id, field, body.get("value"), utc_now())
                        self._reply({"ok": True}); return
                    if self.path.endswith("/tags") and self.path.startswith("/v1/projects/") and "/goals" not in self.path:
                        project_id = self.path.split("/")[3]
                        # `category` selects the organizational facet ("medium"
                        # today); omitting it means an ordinary freeform tag.
                        category = body.get("category") or None
                        tag_row = store.create_tag(str(body["tag"]), category=category) if not body.get("tag_id") else None
                        tag_id = tag_row["id"] if tag_row is not None else str(body["tag_id"])
                        store.assign_project_tag(project_id, tag_id, utc_now(), source="local")
                        self._reply({"ok": True, "tag": dict(tag_row) if tag_row else {"id": tag_id}}); return

                    # -- Project goals (before/during/after session lifecycle) --
                    if self.path.endswith("/goals") and self.path.startswith("/v1/projects/"):
                        project_id = self.path.split("/")[3]
                        rows = store.replace_project_goals(project_id, [str(g) for g in body.get("goals", [])], session_id=body.get("session_id"), source=str(body.get("source", "user")), timestamp=utc_now())
                        self._reply([dict(row) for row in rows]); return
                    if self.path.endswith("/goals/add") and self.path.startswith("/v1/projects/"):
                        project_id = self.path.split("/")[3]
                        row = store.add_project_goal(project_id, str(body["text"]), session_id=body.get("session_id"), source=str(body.get("source", "user")), timestamp=utc_now())
                        self._reply(dict(row), 201); return

                    # -- Session lifecycle: explicit end + wrap-up --
                    if self.path == "/v1/session/end":
                        if runtime is None: raise ValueError("ending a session requires the running backend")
                        closed = runtime.end_current_session(str(body.get("reason", "user_ended")))
                        self._reply(closed if closed is not None else {"ok": False, "reason": "no session was open"}); return
                    if self.path == "/v1/session/wrapup":
                        project_id = str(body["project_id"])
                        session_id = body.get("session_id")
                        if session_id is None:
                            recent = store.recent_sessions(project_id=project_id, limit=1)
                            session_id = recent[0]["id"] if recent else None
                        if session_id is not None:
                            store.record_session_wrapup({
                                "session_id": session_id, "project_id": project_id,
                                "accomplished": str(body.get("accomplished", "")), "unfinished_notes": str(body.get("unfinished_notes", "")),
                                "notes": str(body.get("notes", "")), "created_at": utc_now(),
                            })
                        next_goals = body.get("next_session_goals")
                        if next_goals is not None:
                            store.replace_project_goals(project_id, [str(g) for g in next_goals], session_id=None, source="wrapup", timestamp=utc_now())
                        self._reply({"ok": True, "session_id": session_id}); return
                self._reply({"error": "not found"}, 404)
            except (KeyError, ValueError, NotionCacheError) as error:
                self._reply({"error": str(error)}, 400)

        def do_PATCH(self) -> None:  # noqa: N802
            try:
                body = self._body()
                with CoreStore(config.database_path) as store:
                    if self.path.startswith("/v1/ideas/"):
                        item_id = self.path.rsplit("/", 1)[1]
                        if store.item_by_id(item_id) is None:
                            self._reply({"error": "idea not found"}, 404); return
                        self._reply(update_idea(store, item_id, body)); return
                    if self.path.startswith("/v1/goals/"):
                        goal_id = self.path.rsplit("/", 1)[1]
                        if store.goal_by_id(goal_id) is None:
                            self._reply({"error": "goal not found"}, 404); return
                        row = None
                        if "completed" in body:
                            row = store.set_goal_completed(goal_id, bool(body["completed"]), utc_now())
                        if "text" in body:
                            row = store.update_goal_text(goal_id, str(body["text"]), utc_now())
                        self._reply(dict(row) if row is not None else dict(store.goal_by_id(goal_id)))
                        # A widget interaction always triggers a timeline
                        # reload. Publish before returning so that reload sees
                        # the authoritative, post-action projection.
                        if runtime is not None:
                            runtime.publish_widget_snapshot()
                        return
                    if self.path.startswith("/v1/saved-views/"):
                        view_id = self.path.rsplit("/", 1)[1]
                        existing = store.saved_view_by_id(view_id)
                        if existing is None:
                            self._reply({"error": "saved view not found"}, 404); return
                        values: dict[str, Any] = {"updated_at": utc_now()}
                        for key in ("name", "sort_field", "sort_direction", "group_by"):
                            if key in body:
                                values[key] = body[key]
                        if "query" in body:
                            values["query_json"] = json.dumps(body["query"])
                        row = store.update_saved_view(view_id, values)
                        self._reply(dict(row)); return
                self._reply({"error": "not found"}, 404)
            except (KeyError, ValueError) as error:
                self._reply({"error": str(error)}, 400)

        def do_DELETE(self) -> None:  # noqa: N802
            with CoreStore(config.database_path) as store:
                if self.path.startswith("/v1/relationships/"):
                    self._reply({"removed": store.remove_relationship(self.path.rsplit("/", 1)[1])}); return
                if self.path.startswith("/v1/tags/alias/"):
                    self._reply({"removed": store.remove_tag_alias(self.path.rsplit("/", 1)[1])}); return
                if self.path.startswith("/v1/tags/assign/"):
                    _, item_id, tag_id = self.path.rsplit("/", 2)
                    self._reply({"removed": store.remove_tag(item_id, tag_id)}); return
                if "/tags/" in self.path and self.path.startswith("/v1/projects/"):
                    _, _, _, project_id, _, tag_id = self.path.split("/")
                    self._reply({"removed": store.remove_project_tag(project_id, tag_id)}); return
                if self.path.startswith("/v1/goals/"):
                    self._reply({"removed": store.remove_goal(self.path.rsplit("/", 1)[1])}); return
                if self.path.startswith("/v1/saved-views/"):
                    view_id = self.path.rsplit("/", 1)[1]
                    if store.saved_view_by_id(view_id) is None:
                        self._reply({"error": "saved view not found"}, 404); return
                    removed = store.delete_saved_view(view_id)
                    self._reply({"removed": removed}) if removed else self._reply({"error": "built-in views cannot be deleted"}, 403)
                    return
            self._reply({"error": "not found"}, 404)

    return ThreadingHTTPServer((host, port), Handler)
