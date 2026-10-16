"""Canonical SQLite read model for the v2 Workspace Watcher architecture."""

from __future__ import annotations

import json
import sqlite3
from pathlib import Path
from typing import Any, Iterable

from .core_events import WorkspaceEvent


SCHEMA_VERSION = 10
SCHEMA = """
CREATE TABLE IF NOT EXISTS schema_migrations (version INTEGER PRIMARY KEY, applied_at TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS private_item_records (
 id TEXT PRIMARY KEY, path TEXT NOT NULL UNIQUE, payload_json TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS retired_item_sidecars (
 path TEXT PRIMARY KEY, item_id TEXT NOT NULL, original_bytes BLOB NOT NULL,
 sha256 TEXT NOT NULL, archived_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS work_log_drafts (
 id TEXT PRIMARY KEY, project_id TEXT NOT NULL, project_name TEXT NOT NULL, date_key TEXT NOT NULL,
 session_ids_json TEXT NOT NULL DEFAULT '[]', payload_json TEXT NOT NULL DEFAULT '{}',
 status TEXT NOT NULL DEFAULT 'prepared', notion_page_id TEXT, sync_error TEXT,
 created_at TEXT NOT NULL, updated_at TEXT NOT NULL
);
-- `id` is a deterministic hash of (project_id, date_key) -- see
-- work_logs_v2.py's `_draft_id` -- so re-preparing the same project's same
-- day always upserts the same row. This UNIQUE constraint is defense in
-- depth against that invariant ever being violated by a bug, not the
-- primary mechanism.
CREATE UNIQUE INDEX IF NOT EXISTS idx_work_log_drafts_project_day ON work_log_drafts(project_id, date_key);
CREATE INDEX IF NOT EXISTS idx_work_log_drafts_status ON work_log_drafts(status);
CREATE TABLE IF NOT EXISTS notion_project_cache (
 notion_project_id TEXT PRIMARY KEY, project_id TEXT, name TEXT NOT NULL, local_directory TEXT,
 metadata_json TEXT NOT NULL DEFAULT '{}', refreshed_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_notion_project_cache_project ON notion_project_cache(project_id);
CREATE TABLE IF NOT EXISTS sessions (
 id TEXT PRIMARY KEY, project_id TEXT NOT NULL, project_name TEXT NOT NULL,
 started_at TEXT NOT NULL, ended_at TEXT NOT NULL, active_seconds REAL NOT NULL DEFAULT 0,
 meaningful_event_count INTEGER NOT NULL DEFAULT 0, files_json TEXT NOT NULL DEFAULT '[]',
 burst_count INTEGER NOT NULL DEFAULT 1, intensity REAL NOT NULL DEFAULT 0, confidence REAL NOT NULL DEFAULT 0,
 git_json TEXT NOT NULL DEFAULT '{}', status TEXT NOT NULL DEFAULT 'open', close_reason TEXT,
 longest_gap_seconds REAL NOT NULL DEFAULT 0, longest_burst_seconds REAL NOT NULL DEFAULT 0,
 current_burst_started_at TEXT, open_reason TEXT NOT NULL DEFAULT 'started', evidence_json TEXT NOT NULL DEFAULT '{}',
 created_at TEXT NOT NULL, updated_at TEXT NOT NULL
);
-- At most one session may be open at a time -- this is a hard DB-level
-- backstop for the "exactly one current session" invariant the sessionizer
-- otherwise maintains only in application logic (close-before-open on every
-- switch). A bug that tried to open a second one would fail loudly here
-- instead of silently duplicating "current" state.
CREATE UNIQUE INDEX IF NOT EXISTS idx_sessions_one_open ON sessions(status) WHERE status='open';
CREATE INDEX IF NOT EXISTS idx_sessions_project ON sessions(project_id, started_at DESC);
CREATE INDEX IF NOT EXISTS idx_sessions_status_ended ON sessions(status, ended_at DESC);
CREATE TABLE IF NOT EXISTS projects (
 id TEXT PRIMARY KEY, path TEXT NOT NULL, root_path TEXT NOT NULL, name TEXT NOT NULL,
 device INTEGER, inode INTEGER, status TEXT NOT NULL DEFAULT 'active', name_history_json TEXT NOT NULL DEFAULT '[]',
 discovered_at TEXT NOT NULL, updated_at TEXT NOT NULL
);
-- Only "active" needs to be unique per path: a deleted project's historical
-- row must not block a genuinely new project later claiming the same path
-- (a deliberately distinct identity -- see projects_v2.py's module docstring).
CREATE UNIQUE INDEX IF NOT EXISTS idx_projects_path_active ON projects(path) WHERE status='active';
CREATE INDEX IF NOT EXISTS idx_projects_inode ON projects(device, inode);
CREATE INDEX IF NOT EXISTS idx_projects_status ON projects(status);
CREATE TABLE IF NOT EXISTS intent_folders (
 id TEXT PRIMARY KEY, path TEXT NOT NULL UNIQUE, root_path TEXT NOT NULL, name TEXT NOT NULL,
 config_json TEXT NOT NULL DEFAULT '{}', exists_flag INTEGER NOT NULL DEFAULT 1, discovered_at TEXT NOT NULL, updated_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS intent_items (
 id TEXT PRIMARY KEY, intent_folder_id TEXT NOT NULL REFERENCES intent_folders(id), path TEXT NOT NULL UNIQUE,
 title TEXT NOT NULL, type TEXT NOT NULL, status TEXT NOT NULL, metadata_json TEXT NOT NULL DEFAULT '{}',
 device INTEGER, inode INTEGER, exists_flag INTEGER NOT NULL DEFAULT 1, created_at TEXT NOT NULL, updated_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_intent_items_folder ON intent_items(intent_folder_id, exists_flag);
CREATE INDEX IF NOT EXISTS idx_intent_items_inode ON intent_items(device, inode);
CREATE TABLE IF NOT EXISTS tags (id TEXT PRIMARY KEY, canonical TEXT NOT NULL UNIQUE, display TEXT NOT NULL, category TEXT, provenance TEXT NOT NULL DEFAULT 'user', confidence REAL NOT NULL DEFAULT 1);
CREATE TABLE IF NOT EXISTS tag_aliases (alias TEXT PRIMARY KEY, tag_id TEXT NOT NULL REFERENCES tags(id));
CREATE TABLE IF NOT EXISTS item_tags (item_id TEXT NOT NULL REFERENCES intent_items(id), tag_id TEXT NOT NULL REFERENCES tags(id), provenance TEXT NOT NULL, confidence REAL NOT NULL, PRIMARY KEY(item_id, tag_id));
CREATE TABLE IF NOT EXISTS relationships (id TEXT PRIMARY KEY, from_id TEXT NOT NULL, to_id TEXT NOT NULL, type TEXT NOT NULL, provenance TEXT NOT NULL DEFAULT 'user', confidence REAL, created_at TEXT NOT NULL, UNIQUE(from_id, to_id, type));
CREATE TABLE IF NOT EXISTS event_journal (
 id TEXT PRIMARY KEY, schema_version INTEGER NOT NULL, type TEXT NOT NULL, entity_id TEXT, source TEXT NOT NULL,
 occurred_at TEXT NOT NULL, causation_id TEXT, correlation_id TEXT, payload_json TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_event_journal_entity ON event_journal(entity_id, occurred_at DESC);
CREATE INDEX IF NOT EXISTS idx_event_journal_type ON event_journal(type, occurred_at DESC);
CREATE TABLE IF NOT EXISTS rule_evaluations (
 id INTEGER PRIMARY KEY AUTOINCREMENT, event_id TEXT NOT NULL REFERENCES event_journal(id), rule_id TEXT NOT NULL,
 result TEXT NOT NULL, explanation_json TEXT NOT NULL, evaluated_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS notifications (
 id TEXT PRIMARY KEY, type TEXT NOT NULL, title TEXT NOT NULL, body TEXT NOT NULL, entity_id TEXT,
 source_event_id TEXT, source_rule_id TEXT, priority TEXT NOT NULL, dedupe_key TEXT, state TEXT NOT NULL,
 actions_json TEXT NOT NULL DEFAULT '[]', created_at TEXT NOT NULL, expires_at TEXT, delivered_at TEXT,
 attempt_count INTEGER NOT NULL DEFAULT 0, last_attempt_at TEXT, last_error TEXT, selected_action TEXT, deferred_until TEXT, next_attempt_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_notifications_dedupe_open ON notifications(dedupe_key) WHERE dedupe_key IS NOT NULL AND state IN ('pending', 'delivered');
CREATE TABLE IF NOT EXISTS message_outbox (
 id TEXT PRIMARY KEY, destination TEXT NOT NULL, type TEXT NOT NULL, entity_id TEXT, source_event_id TEXT,
 payload_json TEXT NOT NULL, state TEXT NOT NULL, attempt_count INTEGER NOT NULL DEFAULT 0, last_error TEXT,
 created_at TEXT NOT NULL, delivered_at TEXT, last_attempt_at TEXT, next_attempt_at TEXT
);
CREATE TABLE IF NOT EXISTS watcher_state (key TEXT PRIMARY KEY, value_json TEXT NOT NULL, updated_at TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS action_results (
 id TEXT PRIMARY KEY, action_type TEXT NOT NULL, source_event_id TEXT NOT NULL, source_rule_id TEXT,
 status TEXT NOT NULL, result_json TEXT NOT NULL, failure_reason TEXT, created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS resurfacing_state (
 item_id TEXT PRIMARY KEY REFERENCES intent_items(id), last_considered_at TEXT, last_surfaced_at TEXT,
 surfaced_count INTEGER NOT NULL DEFAULT 0, last_score REAL, last_reason_json TEXT NOT NULL DEFAULT '{}'
);
-- Project browsing/organization: a project's domain is a single freeform
-- label (nullable -- "Unsorted" until a person sets one; never inferred or
-- fabricated). Tags reuse the existing `tags` table (the same canonical
-- name/alias/merge machinery intent-folder items already use) via this
-- junction table, so "AI" means the same tag everywhere in the app.
CREATE TABLE IF NOT EXISTS project_tags (
 project_id TEXT NOT NULL REFERENCES projects(id), tag_id TEXT NOT NULL REFERENCES tags(id),
 created_at TEXT NOT NULL, PRIMARY KEY(project_id, tag_id)
);
CREATE INDEX IF NOT EXISTS idx_project_tags_tag ON project_tags(tag_id);
-- A project's current, actionable goal list -- "what I intend to do next
-- here." Set before a session (proposed goals), live during it, reviewed
-- and replaced at wrap-up ("next session goals"), so the same row a widget
-- reads is the same row the app and menu bar read: one list, not a
-- per-surface copy. `session_id` records which session was open when a
-- goal was created (nullable -- goals can be set with no session open yet),
-- purely for later "which session was this for" display.
CREATE TABLE IF NOT EXISTS project_goals (
 id TEXT PRIMARY KEY, project_id TEXT NOT NULL REFERENCES projects(id), text TEXT NOT NULL,
 completed INTEGER NOT NULL DEFAULT 0, session_id TEXT, source TEXT NOT NULL DEFAULT 'user',
 sort_order INTEGER NOT NULL DEFAULT 0, created_at TEXT NOT NULL, completed_at TEXT, updated_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_project_goals_project ON project_goals(project_id, completed, sort_order);
-- A session's own retrospective, distinct from goals (goals are actionable
-- checkboxes carried forward; a wrap-up is a point-in-time note about one
-- specific session). One per session.
CREATE TABLE IF NOT EXISTS session_wrapups (
 session_id TEXT PRIMARY KEY REFERENCES sessions(id), project_id TEXT NOT NULL,
 accomplished TEXT NOT NULL DEFAULT '', unfinished_notes TEXT NOT NULL DEFAULT '', notes TEXT NOT NULL DEFAULT '',
 created_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_session_wrapups_project ON session_wrapups(project_id, created_at DESC);
-- Persisted Finder-style smart views: a structured filter tree (see
-- project_query_v2.py) plus sort/group, so the same saved view renders
-- identically in the sidebar, in a widget, and after a restart.
-- `built_in=1` rows ship with the app and are not user-deletable from the
-- UI (distinguishing "always available" from "you made this").
CREATE TABLE IF NOT EXISTS saved_views (
 id TEXT PRIMARY KEY, name TEXT NOT NULL, query_json TEXT NOT NULL DEFAULT '{}',
 sort_field TEXT NOT NULL DEFAULT 'score', sort_direction TEXT NOT NULL DEFAULT 'desc', group_by TEXT,
 built_in INTEGER NOT NULL DEFAULT 0, sort_order INTEGER NOT NULL DEFAULT 0,
 created_at TEXT NOT NULL, updated_at TEXT NOT NULL
);
-- Ideas/Notion sync bookkeeping. Deliberately its own table rather than a
-- field in the private item record; runtime sync facts (a Notion page
-- id, the hash of what was last pushed, Notion's own last-edited time) are
-- exactly the kind of derived/rebuildable state that belongs in SQLite only.
-- See notion_ideas_v2.py.
CREATE TABLE IF NOT EXISTS idea_notion_links (
 item_id TEXT PRIMARY KEY REFERENCES intent_items(id), notion_page_id TEXT,
 synced_hash TEXT, notion_last_edited_time TEXT, sync_error TEXT, updated_at TEXT NOT NULL
);
"""


class CoreStore:
    """The only v2 writer. Swift and other consumers use the API/CLI, not SQL."""

    def __init__(self, path: Path, *, read_only: bool = False) -> None:
        self.path = path
        if read_only:
            self.conn = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            # The v2 runtime serializes writes with its pipeline lock while
            # watchdog delivers settled callbacks from the coalescer thread.
            self.conn = sqlite3.connect(path, check_same_thread=False)
            self.conn.executescript(SCHEMA)
            columns = {row[1] for row in self.conn.execute("PRAGMA table_info(intent_folders)")}
            if "exists_flag" not in columns:
                self.conn.execute("ALTER TABLE intent_folders ADD COLUMN exists_flag INTEGER NOT NULL DEFAULT 1")
            self._ensure_columns("notifications", {"attempt_count": "INTEGER NOT NULL DEFAULT 0", "last_attempt_at": "TEXT", "last_error": "TEXT", "selected_action": "TEXT", "deferred_until": "TEXT", "next_attempt_at": "TEXT"})
            self._ensure_columns("message_outbox", {"last_attempt_at": "TEXT", "next_attempt_at": "TEXT"})
            self._ensure_columns("sessions", {"longest_gap_seconds": "REAL NOT NULL DEFAULT 0", "longest_burst_seconds": "REAL NOT NULL DEFAULT 0", "current_burst_started_at": "TEXT", "open_reason": "TEXT NOT NULL DEFAULT 'started'", "evidence_json": "TEXT NOT NULL DEFAULT '{}'", "commits_json": "TEXT NOT NULL DEFAULT '[]'"})
            # `domain`/`status_label`/`medium` are mirrored from the Notion
            # Projects database, but a local edit must win and survive the
            # next refresh. Storing the mirrored and local values in separate
            # columns keeps "Notion says Technology, I say Personal"
            # answerable, and the `*_local_set` flags distinguish "no local
            # opinion" from "deliberately cleared locally" -- without them a
            # local clear is indistinguishable from never having edited, so
            # the next refresh would silently undo it.
            self._ensure_columns("projects", {
                "domain": "TEXT", "domain_local": "TEXT", "domain_local_set": "INTEGER NOT NULL DEFAULT 0",
                "status_label": "TEXT", "status_label_local": "TEXT", "status_label_local_set": "INTEGER NOT NULL DEFAULT 0",
            })
            # Mediums are multi-valued in Notion (`mediums` is a
            # multi_select), exactly like tags, so they reuse the existing
            # tag machinery under `tags.category='medium'` rather than a
            # parallel table. `source` is what makes a refresh safe: it
            # reconciles only its own 'notion' rows, leaves 'local' additions
            # alone, and treats 'excluded' as "I removed this locally, do not
            # bring it back."
            self._ensure_columns("project_tags", {"source": "TEXT NOT NULL DEFAULT 'local'"})
            self.conn.execute("INSERT OR IGNORE INTO schema_migrations(version, applied_at) VALUES (?, datetime('now'))", (SCHEMA_VERSION,))
            self.conn.commit()
        self.conn.row_factory = sqlite3.Row

    def _ensure_columns(self, table: str, definitions: dict[str, str]) -> None:
        columns = {row[1] for row in self.conn.execute(f"PRAGMA table_info({table})")}
        for name, definition in definitions.items():
            if name not in columns:
                self.conn.execute(f"ALTER TABLE {table} ADD COLUMN {name} {definition}")

    def close(self) -> None:
        self.conn.close()

    def __enter__(self) -> "CoreStore":
        return self

    def __exit__(self, *_: object) -> None:
        self.close()

    def record_event(self, event: WorkspaceEvent) -> bool:
        """Idempotent insert keyed on ``event.id``. Returns whether this call
        actually inserted a new row (``False`` for a replayed/duplicate id),
        so a durable external producer can be replayed safely and callers can
        tell a genuinely new fact from one already recorded."""
        cursor = self.conn.execute("""INSERT OR IGNORE INTO event_journal
            (id,schema_version,type,entity_id,source,occurred_at,causation_id,correlation_id,payload_json)
            VALUES (?,?,?,?,?,?,?,?,?)""", (event.id, event.schema_version, event.type, event.entity_id, event.source, event.occurred_at, event.causation_id, event.correlation_id, json.dumps(event.payload, sort_keys=True)))
        self.conn.commit()
        return cursor.rowcount > 0

    def upsert_intent_folder(self, *, folder_id: str, path: str, root_path: str, name: str, config: dict[str, Any], timestamp: str) -> None:
        self.conn.execute("""INSERT INTO intent_folders(id,path,root_path,name,config_json,exists_flag,discovered_at,updated_at)
            VALUES (?,?,?,?,?,?,?,?) ON CONFLICT(path) DO UPDATE SET root_path=excluded.root_path,name=excluded.name,config_json=excluded.config_json,exists_flag=1,updated_at=excluded.updated_at""", (folder_id, path, root_path, name, json.dumps(config, sort_keys=True), 1, timestamp, timestamp))
        self.conn.commit()

    def folder_by_path(self, path: str) -> sqlite3.Row | None:
        return self.conn.execute("SELECT * FROM intent_folders WHERE path=?", (path,)).fetchone()

    def folders(self, *, existing_only: bool = True) -> list[sqlite3.Row]:
        where = " WHERE exists_flag=1" if existing_only else ""
        return self.conn.execute("SELECT * FROM intent_folders" + where + " ORDER BY name COLLATE NOCASE, path").fetchall()

    def mark_absent_folders(self, existing_paths: Iterable[str], timestamp: str) -> None:
        paths = list(existing_paths)
        if paths:
            placeholders = ",".join("?" for _ in paths)
            self.conn.execute(f"UPDATE intent_folders SET exists_flag=0,updated_at=? WHERE exists_flag=1 AND path NOT IN ({placeholders})", [timestamp, *paths])
        else:
            self.conn.execute("UPDATE intent_folders SET exists_flag=0,updated_at=? WHERE exists_flag=1", (timestamp,))
        self.conn.commit()

    def item_by_path(self, path: str) -> sqlite3.Row | None:
        return self.conn.execute("SELECT * FROM intent_items WHERE path=?", (path,)).fetchone()

    def item_by_inode(self, device: int | None, inode: int | None) -> sqlite3.Row | None:
        if device is None or inode is None:
            return None
        return self.conn.execute("SELECT * FROM intent_items WHERE device=? AND inode=? AND exists_flag=1", (device, inode)).fetchone()

    def upsert_item(self, *, item_id: str, folder_id: str, path: str, title: str, item_type: str, status: str, metadata: dict[str, Any], device: int | None, inode: int | None, timestamp: str) -> None:
        self.conn.execute("""INSERT INTO intent_items(id,intent_folder_id,path,title,type,status,metadata_json,device,inode,exists_flag,created_at,updated_at)
            VALUES (?,?,?,?,?,?,?,?,?,1,?,?) ON CONFLICT(id) DO UPDATE SET intent_folder_id=excluded.intent_folder_id,path=excluded.path,title=excluded.title,type=excluded.type,status=excluded.status,metadata_json=excluded.metadata_json,device=excluded.device,inode=excluded.inode,exists_flag=1,updated_at=excluded.updated_at""", (item_id, folder_id, path, title, item_type, status, json.dumps(metadata, sort_keys=True), device, inode, timestamp, timestamp))
        self.conn.commit()

    def absent_items(self, existing_paths: Iterable[str]) -> list[sqlite3.Row]:
        paths = list(existing_paths)
        if not paths:
            return self.conn.execute("SELECT * FROM intent_items WHERE exists_flag=1").fetchall()
        placeholders = ",".join("?" for _ in paths)
        return self.conn.execute(f"SELECT * FROM intent_items WHERE exists_flag=1 AND path NOT IN ({placeholders})", paths).fetchall()

    def mark_absent_items(self, existing_paths: Iterable[str], timestamp: str) -> None:
        paths = list(existing_paths)
        if paths:
            placeholders = ",".join("?" for _ in paths)
            self.conn.execute(f"UPDATE intent_items SET exists_flag=0,updated_at=? WHERE exists_flag=1 AND path NOT IN ({placeholders})", [timestamp, *paths])
        else:
            self.conn.execute("UPDATE intent_items SET exists_flag=0,updated_at=? WHERE exists_flag=1", (timestamp,))
        self.conn.commit()

    def items(self, *, folder_id: str | None = None, existing_only: bool = True) -> list[sqlite3.Row]:
        clauses, args = [], []
        if folder_id:
            clauses.append("intent_folder_id=?"); args.append(folder_id)
        if existing_only:
            clauses.append("exists_flag=1")
        where = " WHERE " + " AND ".join(clauses) if clauses else ""
        return self.conn.execute("SELECT * FROM intent_items" + where + " ORDER BY title COLLATE NOCASE", args).fetchall()

    def item_by_id(self, item_id: str) -> sqlite3.Row | None:
        return self.conn.execute("SELECT * FROM intent_items WHERE id=?", (item_id,)).fetchone()

    def adopt_item_identity(self, old_id: str, new_id: str) -> None:
        """Promote portable metadata UUID over a pre-cutover local-only ID."""
        if old_id == new_id:
            return
        self.conn.execute("UPDATE intent_items SET id=? WHERE id=?", (new_id, old_id))
        self.conn.execute("UPDATE item_tags SET item_id=? WHERE item_id=?", (new_id, old_id))
        self.conn.commit()

    def project_by_path(self, path: str) -> sqlite3.Row | None:
        return self.conn.execute("SELECT * FROM projects WHERE path=? AND status='active'", (path,)).fetchone()

    def project_by_inode(self, device: int | None, inode: int | None) -> sqlite3.Row | None:
        if device is None or inode is None:
            return None
        return self.conn.execute("SELECT * FROM projects WHERE device=? AND inode=? AND status='active'", (device, inode)).fetchone()

    def create_project(self, *, project_id: str, path: str, root_path: str, name: str, device: int | None, inode: int | None, timestamp: str) -> None:
        self.conn.execute("""INSERT INTO projects(id,path,root_path,name,device,inode,status,name_history_json,discovered_at,updated_at)
            VALUES (?,?,?,?,?,?,'active','[]',?,?)""", (project_id, path, root_path, name, device, inode, timestamp, timestamp))
        self.conn.commit()

    def rename_project(self, project_id: str, *, new_path: str, new_name: str, timestamp: str) -> None:
        row = self.conn.execute("SELECT path, name, name_history_json FROM projects WHERE id=?", (project_id,)).fetchone()
        if row is None:
            raise ValueError(f"unknown project id {project_id!r}")
        history = json.loads(row["name_history_json"] or "[]")
        history.append({"path": row["path"], "name": row["name"], "until": timestamp})
        self.conn.execute("UPDATE projects SET path=?,name=?,name_history_json=?,status='active',updated_at=? WHERE id=?",
            (new_path, new_name, json.dumps(history, sort_keys=True), timestamp, project_id))
        self.conn.commit()

    def mark_project_status(self, project_id: str, status: str, timestamp: str) -> None:
        self.conn.execute("UPDATE projects SET status=?,updated_at=? WHERE id=?", (status, timestamp, project_id))
        self.conn.commit()

    def projects(self, *, status: str | None = "active") -> list[sqlite3.Row]:
        if status is None:
            return self.conn.execute("SELECT * FROM projects ORDER BY name COLLATE NOCASE, path").fetchall()
        return self.conn.execute("SELECT * FROM projects WHERE status=? ORDER BY name COLLATE NOCASE, path", (status,)).fetchall()

    def project_by_id(self, project_id: str) -> sqlite3.Row | None:
        return self.conn.execute("SELECT * FROM projects WHERE id=?", (project_id,)).fetchone()

    def open_session(self) -> sqlite3.Row | None:
        return self.conn.execute("SELECT * FROM sessions WHERE status='open' LIMIT 1").fetchone()

    def session_by_id(self, session_id: str) -> sqlite3.Row | None:
        return self.conn.execute("SELECT * FROM sessions WHERE id=?", (session_id,)).fetchone()

    def recent_closed_session_for_project(self, project_id: str, *, ended_after: str) -> sqlite3.Row | None:
        """The most recently closed (completed or discarded) session for this
        project that ended at or after ``ended_after`` -- the candidate a
        caller can reopen instead of starting a noisy duplicate. Returns
        None if the most recent closed session for this project ended
        earlier than that (too long ago to be a continuation)."""
        return self.conn.execute(
            "SELECT * FROM sessions WHERE project_id=? AND status!='open' AND ended_at>=? ORDER BY ended_at DESC LIMIT 1",
            (project_id, ended_after),
        ).fetchone()

    def upsert_session(self, record: dict[str, Any]) -> None:
        """``record`` carries raw ``files``/``commits`` (lists) and ``git``
        (dict); this is the one place they're serialized, matching
        ``upsert_intent_folder``'s convention of serializing at the store
        boundary rather than asking every caller to."""
        values = dict(record, files_json=json.dumps(record.get("files", []), sort_keys=True), git_json=json.dumps(record.get("git", {}), sort_keys=True),
                      evidence_json=json.dumps(record.get("evidence", {}), sort_keys=True), commits_json=json.dumps(record.get("commits", []), sort_keys=True))
        self.conn.execute("""INSERT INTO sessions(id,project_id,project_name,started_at,ended_at,active_seconds,meaningful_event_count,files_json,burst_count,intensity,confidence,git_json,status,close_reason,longest_gap_seconds,longest_burst_seconds,current_burst_started_at,open_reason,evidence_json,commits_json,created_at,updated_at)
            VALUES (:id,:project_id,:project_name,:started_at,:ended_at,:active_seconds,:meaningful_event_count,:files_json,:burst_count,:intensity,:confidence,:git_json,:status,:close_reason,:longest_gap_seconds,:longest_burst_seconds,:current_burst_started_at,:open_reason,:evidence_json,:commits_json,:created_at,:updated_at)
            ON CONFLICT(id) DO UPDATE SET project_id=excluded.project_id,project_name=excluded.project_name,started_at=excluded.started_at,ended_at=excluded.ended_at,
                active_seconds=excluded.active_seconds,meaningful_event_count=excluded.meaningful_event_count,files_json=excluded.files_json,burst_count=excluded.burst_count,
                intensity=excluded.intensity,confidence=excluded.confidence,git_json=excluded.git_json,status=excluded.status,close_reason=excluded.close_reason,
                longest_gap_seconds=excluded.longest_gap_seconds,longest_burst_seconds=excluded.longest_burst_seconds,
                current_burst_started_at=excluded.current_burst_started_at,open_reason=excluded.open_reason,evidence_json=excluded.evidence_json,commits_json=excluded.commits_json,updated_at=excluded.updated_at""", values)
        self.conn.commit()

    def recent_sessions(self, *, limit: int = 50, project_id: str | None = None) -> list[sqlite3.Row]:
        if project_id:
            return self.conn.execute("SELECT * FROM sessions WHERE project_id=? ORDER BY started_at DESC LIMIT ?", (project_id, limit)).fetchall()
        return self.conn.execute("SELECT * FROM sessions ORDER BY started_at DESC LIMIT ?", (limit,)).fetchall()

    def get_work_log_draft(self, draft_id: str) -> sqlite3.Row | None:
        return self.conn.execute("SELECT * FROM work_log_drafts WHERE id=?", (draft_id,)).fetchone()

    def upsert_work_log_draft(self, record: dict[str, Any]) -> None:
        """``record`` carries raw ``session_ids`` (list) and ``payload``
        (dict); serialized here, matching ``upsert_session``'s convention."""
        values = dict(record, session_ids_json=json.dumps(record.get("session_ids", []), sort_keys=True), payload_json=json.dumps(record.get("payload", {}), sort_keys=True))
        self.conn.execute("""INSERT INTO work_log_drafts(id,project_id,project_name,date_key,session_ids_json,payload_json,status,notion_page_id,sync_error,created_at,updated_at)
            VALUES (:id,:project_id,:project_name,:date_key,:session_ids_json,:payload_json,:status,:notion_page_id,:sync_error,:created_at,:updated_at)
            ON CONFLICT(id) DO UPDATE SET project_id=excluded.project_id,project_name=excluded.project_name,date_key=excluded.date_key,
                session_ids_json=excluded.session_ids_json,payload_json=excluded.payload_json,status=excluded.status,
                notion_page_id=excluded.notion_page_id,sync_error=excluded.sync_error,updated_at=excluded.updated_at""", values)
        self.conn.commit()

    def mark_work_log_draft_sync(self, draft_id: str, status: str, *, notion_page_id: str | None = None, error: str | None = None, timestamp: str) -> None:
        if notion_page_id is not None:
            self.conn.execute("UPDATE work_log_drafts SET status=?,notion_page_id=?,sync_error=?,updated_at=? WHERE id=?", (status, notion_page_id, error, timestamp, draft_id))
        else:
            self.conn.execute("UPDATE work_log_drafts SET status=?,sync_error=?,updated_at=? WHERE id=?", (status, error, timestamp, draft_id))
        self.conn.commit()

    def reset_work_log_draft_page(self, draft_id: str, *, notion_page_id: str | None, status: str, timestamp: str) -> None:
        """Unlike `mark_work_log_draft_sync` (where `notion_page_id=None`
        deliberately means "leave the existing one alone" -- the common
        case, an ordinary sync attempt that only has a page id when it
        already knew one), this always sets `notion_page_id` to exactly
        what's passed, including clearing it to NULL. Only reconciliation
        repair (`reconciliation_v2.py`) needs that distinction -- "I now
        know for certain this local page id is wrong/gone."""
        self.conn.execute("UPDATE work_log_drafts SET status=?,notion_page_id=?,sync_error=NULL,updated_at=? WHERE id=?", (status, notion_page_id, timestamp, draft_id))
        self.conn.commit()

    def work_log_drafts(self, *, status: str | None = None, project_id: str | None = None, limit: int = 200) -> list[sqlite3.Row]:
        clauses, params = [], []
        if status is not None:
            clauses.append("status=?"); params.append(status)
        if project_id is not None:
            clauses.append("project_id=?"); params.append(project_id)
        where = f"WHERE {' AND '.join(clauses)}" if clauses else ""
        params.append(limit)
        return self.conn.execute(f"SELECT * FROM work_log_drafts {where} ORDER BY updated_at DESC LIMIT ?", params).fetchall()

    def replace_notion_project_cache(self, records: list[dict[str, Any]], timestamp: str) -> None:
        self.conn.execute("DELETE FROM notion_project_cache")
        for record in records:
            self.conn.execute(
                "INSERT INTO notion_project_cache(notion_project_id,project_id,name,local_directory,metadata_json,refreshed_at) VALUES (?,?,?,?,?,?)",
                (record["notion_project_id"], record.get("project_id"), record["name"], record.get("local_directory"),
                 json.dumps(record.get("metadata", {}), sort_keys=True), timestamp),
            )
        self.conn.commit()

    def cached_notion_projects(self) -> list[sqlite3.Row]:
        return self.conn.execute("SELECT * FROM notion_project_cache ORDER BY name COLLATE NOCASE").fetchall()

    def notion_project_for(self, project_id: str) -> sqlite3.Row | None:
        return self.conn.execute("SELECT * FROM notion_project_cache WHERE project_id=?", (project_id,)).fetchone()

    def project_for_notion_id(self, notion_project_id: str) -> sqlite3.Row | None:
        """The reverse of `notion_project_for`: given a Notion Projects-database
        page id (as found in a Work Log page's own project relation), find
        the v2 local project it maps to, if any. Used by `legacy_import_v2.py`
        to claim a legacy Notion Work Log page under v2's own project
        identity without needing a second matching pass."""
        row = self.conn.execute("SELECT * FROM notion_project_cache WHERE notion_project_id=?", (notion_project_id,)).fetchone()
        if row is None or row["project_id"] is None:
            return None
        return self.project_by_id(row["project_id"])

    def set_state(self, key: str, value: dict[str, Any], timestamp: str) -> None:
        # The tick loop restates several health values every second. Rewriting
        # an unchanged one committed a transaction -- a rollback journal created
        # and deleted inside the watched tree -- for nothing; `updated_at` is
        # when the value last changed.
        value_json = json.dumps(value, sort_keys=True)
        row = self.conn.execute("SELECT value_json FROM watcher_state WHERE key=?", (key,)).fetchone()
        if row is not None and row["value_json"] == value_json:
            return
        self.conn.execute("INSERT INTO watcher_state(key,value_json,updated_at) VALUES (?,?,?) ON CONFLICT(key) DO UPDATE SET value_json=excluded.value_json,updated_at=excluded.updated_at", (key, value_json, timestamp)); self.conn.commit()

    def get_state(self, key: str) -> dict[str, Any] | None:
        row = self.conn.execute("SELECT value_json FROM watcher_state WHERE key=?", (key,)).fetchone()
        return json.loads(row["value_json"]) if row else None

    def add_action_result(self, values: dict[str, Any]) -> None:
        self.conn.execute("INSERT INTO action_results(id,action_type,source_event_id,source_rule_id,status,result_json,failure_reason,created_at) VALUES (:id,:action_type,:source_event_id,:source_rule_id,:status,:result_json,:failure_reason,:created_at)", values); self.conn.commit()

    def notifications(self, limit: int = 200) -> list[sqlite3.Row]:
        return self.conn.execute("SELECT * FROM notifications ORDER BY created_at DESC LIMIT ?", (limit,)).fetchall()

    def messages(self, limit: int = 200) -> list[sqlite3.Row]:
        return self.conn.execute("SELECT * FROM message_outbox ORDER BY created_at DESC LIMIT ?", (limit,)).fetchall()

    def tags(self) -> list[sqlite3.Row]:
        return self.conn.execute("SELECT tags.*, COUNT(item_tags.item_id) AS usage_count FROM tags LEFT JOIN item_tags ON item_tags.tag_id=tags.id GROUP BY tags.id ORDER BY tags.display COLLATE NOCASE").fetchall()

    def relationships(self) -> list[sqlite3.Row]:
        return self.conn.execute("SELECT * FROM relationships ORDER BY created_at DESC").fetchall()

    def notification_by_id(self, notification_id: str) -> sqlite3.Row | None:
        return self.conn.execute("SELECT * FROM notifications WHERE id=?", (notification_id,)).fetchone()

    def notifications_due_for_delivery(self, now: str, limit: int = 20) -> list[sqlite3.Row]:
        return self.conn.execute("SELECT * FROM notifications WHERE state IN ('pending','failed') AND (next_attempt_at IS NULL OR next_attempt_at <= ?) AND (expires_at IS NULL OR expires_at > ?) AND (deferred_until IS NULL OR deferred_until <= ?) ORDER BY created_at LIMIT ?", (now, now, now, limit)).fetchall()

    def update_notification_delivery(self, notification_id: str, *, state: str, now: str, error: str | None = None, next_attempt_at: str | None = None) -> None:
        delivered = now if state == "delivered" else None
        self.conn.execute("UPDATE notifications SET state=?,attempt_count=attempt_count+1,last_attempt_at=?,last_error=?,next_attempt_at=?,delivered_at=COALESCE(?, delivered_at) WHERE id=?", (state, now, error, next_attempt_at, delivered, notification_id)); self.conn.commit()

    def update_notification_action(self, notification_id: str, action: str, now: str, defer_until: str | None = None) -> sqlite3.Row | None:
        self.conn.execute("UPDATE notifications SET selected_action=?,state=?,deferred_until=? WHERE id=?", (action, "deferred" if action == "defer" else "acted", defer_until, notification_id)); self.conn.commit()
        return self.notification_by_id(notification_id)

    def expire_notifications(self, now: str) -> int:
        cursor = self.conn.execute("UPDATE notifications SET state='expired' WHERE state IN ('pending','failed','delivered') AND expires_at IS NOT NULL AND expires_at <= ?", (now,)); self.conn.commit(); return cursor.rowcount

    def messages_due_for_delivery(self, now: str, limit: int = 20) -> list[sqlite3.Row]:
        return self.conn.execute("SELECT * FROM message_outbox WHERE state IN ('pending','failed') AND (next_attempt_at IS NULL OR next_attempt_at <= ?) ORDER BY created_at LIMIT ?", (now, limit)).fetchall()

    def update_message_delivery(self, message_id: str, *, state: str, now: str, error: str | None = None, next_attempt_at: str | None = None) -> None:
        delivered = now if state == "delivered" else None
        self.conn.execute("UPDATE message_outbox SET state=?,attempt_count=attempt_count+1,last_attempt_at=?,last_error=?,next_attempt_at=?,delivered_at=COALESCE(?, delivered_at) WHERE id=?", (state, now, error, next_attempt_at, delivered, message_id)); self.conn.commit()

    def retry_message(self, message_id: str, now: str) -> bool:
        cursor = self.conn.execute("UPDATE message_outbox SET state='pending',next_attempt_at=?,last_error=NULL WHERE id=? AND state='failed'", (now, message_id)); self.conn.commit(); return cursor.rowcount == 1

    def create_tag(self, display: str, *, provenance: str = "user", confidence: float = 1.0, category: str | None = None) -> sqlite3.Row:
        """One tag vocabulary for the whole app, keyed by canonical name.

        `category` marks which organizational facet a tag belongs to
        ("medium" today, NULL for an ordinary freeform tag). Because the
        vocabulary is shared, a name can already exist as a freeform tag when
        a Notion refresh first reports it as a medium -- so a supplied
        category is applied on conflict too, promoting that existing tag into
        the facet rather than leaving `By Medium` mysteriously missing it. A
        category is never cleared by a caller that does not specify one.
        """
        from .tags import normalize_tag
        import uuid
        canonical = normalize_tag(display)
        if not canonical:
            raise ValueError("tag must contain letters or numbers")
        self.conn.execute(
            "INSERT INTO tags(id,canonical,display,provenance,confidence,category) VALUES (?,?,?,?,?,?)"
            " ON CONFLICT(canonical) DO UPDATE SET category=COALESCE(excluded.category, tags.category)",
            (str(uuid.uuid4()), canonical, display.strip(), provenance, confidence, category),
        )
        self.conn.commit()
        return self.conn.execute("SELECT * FROM tags WHERE canonical=?", (canonical,)).fetchone()

    def add_tag_alias(self, tag_id: str, alias: str) -> None:
        from .tags import normalize_tag
        key = normalize_tag(alias)
        if not key or not self.conn.execute("SELECT 1 FROM tags WHERE id=?", (tag_id,)).fetchone():
            raise ValueError("valid tag and alias are required")
        self.conn.execute("INSERT INTO tag_aliases(alias,tag_id) VALUES (?,?)", (key, tag_id)); self.conn.commit()

    def rename_tag(self, tag_id: str, display: str) -> None:
        from .tags import normalize_tag
        canonical = normalize_tag(display)
        if not canonical:
            raise ValueError("tag must contain letters or numbers")
        cursor = self.conn.execute("UPDATE tags SET canonical=?,display=? WHERE id=?", (canonical, display.strip(), tag_id)); self.conn.commit()
        if cursor.rowcount != 1:
            raise ValueError("tag does not exist")

    def remove_tag_alias(self, alias: str) -> bool:
        from .tags import normalize_tag
        cursor = self.conn.execute("DELETE FROM tag_aliases WHERE alias=?", (normalize_tag(alias),)); self.conn.commit(); return cursor.rowcount == 1

    def merge_tags(self, source_id: str, target_id: str) -> None:
        if source_id == target_id or not self.conn.execute("SELECT 1 FROM tags WHERE id=?", (source_id,)).fetchone() or not self.conn.execute("SELECT 1 FROM tags WHERE id=?", (target_id,)).fetchone():
            raise ValueError("two distinct existing tags are required")
        self.conn.execute("UPDATE OR IGNORE item_tags SET tag_id=? WHERE tag_id=?", (target_id, source_id))
        self.conn.execute("UPDATE tag_aliases SET tag_id=? WHERE tag_id=?", (target_id, source_id))
        self.conn.execute("DELETE FROM tags WHERE id=?", (source_id,)); self.conn.commit()

    def assign_tag(self, item_id: str, tag_id: str, *, provenance: str = "user", confidence: float = 1.0) -> None:
        if not self.item_by_id(item_id) or not self.conn.execute("SELECT 1 FROM tags WHERE id=?", (tag_id,)).fetchone():
            raise ValueError("item and tag must exist")
        self.conn.execute("INSERT INTO item_tags(item_id,tag_id,provenance,confidence) VALUES (?,?,?,?) ON CONFLICT(item_id,tag_id) DO UPDATE SET provenance=excluded.provenance,confidence=excluded.confidence", (item_id, tag_id, provenance, confidence)); self.conn.commit()

    def remove_tag(self, item_id: str, tag_id: str) -> bool:
        cursor = self.conn.execute("DELETE FROM item_tags WHERE item_id=? AND tag_id=?", (item_id, tag_id)); self.conn.commit(); return cursor.rowcount == 1

    def tags_for_item(self, item_id: str) -> list[sqlite3.Row]:
        return self.conn.execute("SELECT tags.* FROM tags JOIN item_tags ON item_tags.tag_id=tags.id WHERE item_tags.item_id=? ORDER BY tags.display COLLATE NOCASE", (item_id,)).fetchall()

    def create_relationship(self, from_id: str, to_id: str, relationship_type: str, timestamp: str, *, provenance: str = "user", confidence: float | None = None) -> str:
        import uuid
        allowed = {"related_to_project", "potentially_related_to_project", "excluded_from_project", "related_to_item", "inspired_by", "derived_from", "useful_for", "not_related_to", "duplicate_of", "supersedes"}
        if relationship_type not in allowed or not from_id or not to_id or from_id == to_id:
            raise ValueError("invalid relationship")
        if not self.item_by_id(from_id) and not from_id.startswith("project:"):
            raise ValueError("relationship source must be an item or project identifier")
        if not self.item_by_id(to_id) and not to_id.startswith("project:"):
            raise ValueError("relationship target must be an item or project identifier")
        relationship_id = str(uuid.uuid4())
        self.conn.execute("INSERT OR IGNORE INTO relationships(id,from_id,to_id,type,provenance,confidence,created_at) VALUES (?,?,?,?,?,?,?)", (relationship_id, from_id, to_id, relationship_type, provenance, confidence, timestamp)); self.conn.commit()
        row = self.conn.execute("SELECT id FROM relationships WHERE from_id=? AND to_id=? AND type=?", (from_id, to_id, relationship_type)).fetchone()
        return str(row["id"])

    def remove_relationship(self, relationship_id: str) -> bool:
        cursor = self.conn.execute("DELETE FROM relationships WHERE id=?", (relationship_id,)); self.conn.commit(); return cursor.rowcount == 1

    def relationships_for(self, entity_id: str) -> list[sqlite3.Row]:
        return self.conn.execute("SELECT * FROM relationships WHERE from_id=? OR to_id=? ORDER BY created_at DESC", (entity_id, entity_id)).fetchall()

    def resurfacing_state(self, item_id: str) -> sqlite3.Row | None:
        return self.conn.execute("SELECT * FROM resurfacing_state WHERE item_id=?", (item_id,)).fetchone()

    def remember_resurfacing(self, item_id: str, *, now: str, surfaced: bool, score: float, reasons: dict[str, Any]) -> None:
        prior = self.resurfacing_state(item_id)
        count = (int(prior["surfaced_count"]) if prior else 0) + int(surfaced)
        self.conn.execute("INSERT INTO resurfacing_state(item_id,last_considered_at,last_surfaced_at,surfaced_count,last_score,last_reason_json) VALUES (?,?,?,?,?,?) ON CONFLICT(item_id) DO UPDATE SET last_considered_at=excluded.last_considered_at,last_surfaced_at=COALESCE(excluded.last_surfaced_at,resurfacing_state.last_surfaced_at),surfaced_count=excluded.surfaced_count,last_score=excluded.last_score,last_reason_json=excluded.last_reason_json", (item_id, now, now if surfaced else None, count, score, json.dumps(reasons, sort_keys=True))); self.conn.commit()

    def add_rule_evaluation(self, event_id: str, rule_id: str, result: str, explanation: dict[str, Any], timestamp: str) -> None:
        self.conn.execute("INSERT INTO rule_evaluations(event_id,rule_id,result,explanation_json,evaluated_at) VALUES (?,?,?,?,?)", (event_id, rule_id, result, json.dumps(explanation, sort_keys=True), timestamp)); self.conn.commit()

    def create_notification(self, values: dict[str, Any]) -> bool:
        try:
            self.conn.execute("""INSERT INTO notifications(id,type,title,body,entity_id,source_event_id,source_rule_id,priority,dedupe_key,state,actions_json,created_at,expires_at)
                VALUES (:id,:type,:title,:body,:entity_id,:source_event_id,:source_rule_id,:priority,:dedupe_key,'pending',:actions_json,:created_at,:expires_at)""", values)
            self.conn.commit(); return True
        except sqlite3.IntegrityError:
            return False

    def queue_message(self, values: dict[str, Any]) -> None:
        self.conn.execute("""INSERT INTO message_outbox(id,destination,type,entity_id,source_event_id,payload_json,state,created_at)
            VALUES (:id,:destination,:type,:entity_id,:source_event_id,:payload_json,'pending',:created_at)""", values); self.conn.commit()

    def recent_events(self, limit: int = 50, *, since: str | None = None, types: tuple[str, ...] | None = None) -> list[sqlite3.Row]:
        clauses, params = [], []
        if since is not None:
            clauses.append("occurred_at >= ?"); params.append(since)
        if types:
            clauses.append(f"type IN ({','.join('?' * len(types))})"); params.extend(types)
        where = f"WHERE {' AND '.join(clauses)}" if clauses else ""
        params.append(limit)
        return self.conn.execute(f"SELECT * FROM event_journal {where} ORDER BY occurred_at DESC LIMIT ?", params).fetchall()

    # -- Project domain/tags (browsing/organization; see project_model_v2.py) --

    # Single-valued organizational fields. `MIRRORED_FIELDS` is the set a
    # Notion refresh is allowed to write; anything else is local-only.
    MIRRORED_FIELDS = ("domain", "status_label")

    def set_project_domain(self, project_id: str, domain: str | None, timestamp: str) -> None:
        """A local, authoritative edit -- see `set_project_field`."""
        self.set_project_field(project_id, "domain", domain, timestamp)

    def set_project_field(self, project_id: str, field: str, value: str | None, timestamp: str) -> None:
        """Record a local override that outlives the next Notion refresh.

        Clearing (``value=None``) is itself an override: the flag is still
        set, so "I have no domain for this" is preserved rather than being
        refilled from Notion on the next refresh.
        """
        if field not in self.MIRRORED_FIELDS:
            raise ValueError(f"unknown project field {field!r}")
        cleaned = (value or "").strip() or None
        self.conn.execute(
            f"UPDATE projects SET {field}_local=?, {field}_local_set=1, updated_at=? WHERE id=?",
            (cleaned, timestamp, project_id),
        )
        self.conn.commit()

    def clear_project_field_override(self, project_id: str, field: str, timestamp: str) -> None:
        """Drop the local opinion and fall back to whatever Notion mirrors."""
        if field not in self.MIRRORED_FIELDS:
            raise ValueError(f"unknown project field {field!r}")
        self.conn.execute(
            f"UPDATE projects SET {field}_local=NULL, {field}_local_set=0, updated_at=? WHERE id=?",
            (timestamp, project_id),
        )
        self.conn.commit()

    def set_project_mirrored_field(self, project_id: str, field: str, value: str | None, timestamp: str) -> None:
        """Write the value a refresh observed upstream, never touching the
        local override -- so mirroring is idempotent and non-destructive."""
        if field not in self.MIRRORED_FIELDS:
            raise ValueError(f"unknown project field {field!r}")
        self.conn.execute(
            f"UPDATE projects SET {field}=?, updated_at=? WHERE id=?",
            ((value or "").strip() or None, timestamp, project_id),
        )
        self.conn.commit()

    def project_tags_for(self, project_id: str, *, category: str | None = None) -> list[sqlite3.Row]:
        clause = "AND tags.category IS ?" if category is None else "AND tags.category=?"
        return self.conn.execute(
            "SELECT tags.* FROM project_tags JOIN tags ON tags.id=project_tags.tag_id"
            f" WHERE project_tags.project_id=? AND project_tags.source!='excluded' {clause}"
            " ORDER BY tags.display COLLATE NOCASE",
            (project_id, category),
        ).fetchall()

    def all_project_tags_for(self, project_id: str) -> list[sqlite3.Row]:
        """Every effective tag regardless of category (freeform + medium)."""
        return self.conn.execute(
            "SELECT tags.* FROM project_tags JOIN tags ON tags.id=project_tags.tag_id"
            " WHERE project_tags.project_id=? AND project_tags.source!='excluded'"
            " ORDER BY tags.display COLLATE NOCASE",
            (project_id,),
        ).fetchall()

    def all_project_tags(self) -> list[sqlite3.Row]:
        """Every (project_id, tag) pairing across all projects in one query --
        used to build the full project view model without an N+1 query per
        project. Locally excluded pairings are omitted, so every consumer
        sees the same effective list the detail view shows."""
        return self.conn.execute(
            "SELECT project_tags.project_id, tags.* FROM project_tags JOIN tags ON tags.id=project_tags.tag_id"
            " WHERE project_tags.source!='excluded'"
        ).fetchall()

    def assign_project_tag(self, project_id: str, tag_id: str, timestamp: str, *, source: str = "local") -> None:
        if not self.project_by_id(project_id) or not self.conn.execute("SELECT 1 FROM tags WHERE id=?", (tag_id,)).fetchone():
            raise ValueError("project and tag must exist")
        if source not in ("local", "notion"):
            raise ValueError(f"unknown tag assignment source {source!r}")
        # A local re-add must lift a previous local exclusion; a Notion
        # refresh must not, or it would silently undo a deliberate removal.
        if source == "local":
            self.conn.execute(
                "INSERT INTO project_tags(project_id,tag_id,created_at,source) VALUES (?,?,?,'local')"
                " ON CONFLICT(project_id,tag_id) DO UPDATE SET source='local'",
                (project_id, tag_id, timestamp),
            )
        else:
            self.conn.execute(
                "INSERT INTO project_tags(project_id,tag_id,created_at,source) VALUES (?,?,?,'notion')"
                " ON CONFLICT(project_id,tag_id) DO NOTHING",
                (project_id, tag_id, timestamp),
            )
        self.conn.commit()

    def remove_project_tag(self, project_id: str, tag_id: str) -> bool:
        """Remove a tag locally.

        A mirrored ('notion') pairing is kept as an explicit `excluded`
        tombstone instead of being deleted, because a plain delete would be
        undone by the very next Notion refresh. A purely local pairing has
        nothing upstream to come back from, so it is simply removed.
        """
        row = self.conn.execute("SELECT source FROM project_tags WHERE project_id=? AND tag_id=?", (project_id, tag_id)).fetchone()
        if row is None or row["source"] == "excluded":
            return False
        if row["source"] == "notion":
            self.conn.execute("UPDATE project_tags SET source='excluded' WHERE project_id=? AND tag_id=?", (project_id, tag_id))
        else:
            self.conn.execute("DELETE FROM project_tags WHERE project_id=? AND tag_id=?", (project_id, tag_id))
        self.conn.commit()
        return True

    def replace_mirrored_project_tags(self, project_id: str, tag_ids: list[str], timestamp: str, *, category: str) -> None:
        """Reconcile one category's mirrored pairings for a project.

        Only `source='notion'` rows in this category are reconciled: a
        locally added tag survives, and an `excluded` tombstone is left in
        place so a removal the person made here is not undone upstream-first.
        """
        existing = self.conn.execute(
            "SELECT project_tags.tag_id, project_tags.source FROM project_tags JOIN tags ON tags.id=project_tags.tag_id"
            " WHERE project_tags.project_id=? AND tags.category=?",
            (project_id, category),
        ).fetchall()
        wanted = set(tag_ids)
        for row in existing:
            if row["source"] == "notion" and row["tag_id"] not in wanted:
                self.conn.execute("DELETE FROM project_tags WHERE project_id=? AND tag_id=?", (project_id, row["tag_id"]))
        known = {row["tag_id"]: row["source"] for row in existing}
        for tag_id in tag_ids:
            if known.get(tag_id) in ("local", "excluded"):
                continue  # a local opinion already governs this pairing
            self.conn.execute(
                "INSERT INTO project_tags(project_id,tag_id,created_at,source) VALUES (?,?,?,'notion')"
                " ON CONFLICT(project_id,tag_id) DO NOTHING",
                (project_id, tag_id, timestamp),
            )
        self.conn.commit()

    # -- Project goals (before/during/after session lifecycle) --

    def project_goals(self, project_id: str, *, include_completed: bool = True) -> list[sqlite3.Row]:
        if include_completed:
            return self.conn.execute("SELECT * FROM project_goals WHERE project_id=? ORDER BY completed, sort_order", (project_id,)).fetchall()
        return self.conn.execute("SELECT * FROM project_goals WHERE project_id=? AND completed=0 ORDER BY sort_order", (project_id,)).fetchall()

    def open_goal_counts(self) -> dict[str, int]:
        """project_id -> count of incomplete goals, for every project with
        at least one -- one query for the whole ranked/query view rather
        than one per project."""
        rows = self.conn.execute("SELECT project_id, COUNT(*) AS n FROM project_goals WHERE completed=0 GROUP BY project_id").fetchall()
        return {row["project_id"]: row["n"] for row in rows}

    def replace_project_goals(self, project_id: str, goals: list[str], *, session_id: str | None, source: str, timestamp: str) -> list[sqlite3.Row]:
        """Sets the project's current goal list wholesale -- used both
        "define goals before/during a session" and "set next-session goals
        at wrap-up" (the same mechanism; see the module docstring on
        `project_goals` in the schema). Replacing rather than diffing keeps
        this simple and matches how the GUI naturally edits a goal list (a
        small ordered set of short text items, not a large collection worth
        incremental diffing)."""
        import uuid
        self.conn.execute("DELETE FROM project_goals WHERE project_id=?", (project_id,))
        for index, text in enumerate(goals):
            text = text.strip()
            if not text:
                continue
            self.conn.execute(
                "INSERT INTO project_goals(id,project_id,text,completed,session_id,source,sort_order,created_at,updated_at) VALUES (?,?,?,0,?,?,?,?,?)",
                (str(uuid.uuid4()), project_id, text, session_id, source, index, timestamp, timestamp),
            )
        self.conn.commit()
        return self.project_goals(project_id)

    def set_goal_completed(self, goal_id: str, completed: bool, timestamp: str) -> sqlite3.Row | None:
        self.conn.execute(
            "UPDATE project_goals SET completed=?, completed_at=?, updated_at=? WHERE id=?",
            (int(completed), timestamp if completed else None, timestamp, goal_id),
        )
        self.conn.commit()
        return self.conn.execute("SELECT * FROM project_goals WHERE id=?", (goal_id,)).fetchone()

    def update_goal_text(self, goal_id: str, text: str, timestamp: str) -> sqlite3.Row | None:
        self.conn.execute("UPDATE project_goals SET text=?, updated_at=? WHERE id=?", (text.strip(), timestamp, goal_id))
        self.conn.commit()
        return self.conn.execute("SELECT * FROM project_goals WHERE id=?", (goal_id,)).fetchone()

    def add_project_goal(self, project_id: str, text: str, *, session_id: str | None, source: str, timestamp: str) -> sqlite3.Row:
        import uuid
        text = text.strip()
        if not text:
            raise ValueError("goal text must not be empty")
        next_order = self.conn.execute("SELECT COALESCE(MAX(sort_order), -1) + 1 FROM project_goals WHERE project_id=?", (project_id,)).fetchone()[0]
        goal_id = str(uuid.uuid4())
        self.conn.execute(
            "INSERT INTO project_goals(id,project_id,text,completed,session_id,source,sort_order,created_at,updated_at) VALUES (?,?,?,0,?,?,?,?,?)",
            (goal_id, project_id, text, session_id, source, next_order, timestamp, timestamp),
        )
        self.conn.commit()
        return self.conn.execute("SELECT * FROM project_goals WHERE id=?", (goal_id,)).fetchone()

    def remove_goal(self, goal_id: str) -> bool:
        cursor = self.conn.execute("DELETE FROM project_goals WHERE id=?", (goal_id,)); self.conn.commit(); return cursor.rowcount == 1

    def goal_by_id(self, goal_id: str) -> sqlite3.Row | None:
        return self.conn.execute("SELECT * FROM project_goals WHERE id=?", (goal_id,)).fetchone()

    # -- Session wrap-ups --

    def record_session_wrapup(self, values: dict[str, Any]) -> None:
        self.conn.execute(
            """INSERT INTO session_wrapups(session_id,project_id,accomplished,unfinished_notes,notes,created_at)
               VALUES (:session_id,:project_id,:accomplished,:unfinished_notes,:notes,:created_at)
               ON CONFLICT(session_id) DO UPDATE SET accomplished=excluded.accomplished,unfinished_notes=excluded.unfinished_notes,notes=excluded.notes""",
            values,
        )
        self.conn.commit()

    def wrapup_for_session(self, session_id: str) -> sqlite3.Row | None:
        return self.conn.execute("SELECT * FROM session_wrapups WHERE session_id=?", (session_id,)).fetchone()

    def latest_wrapup_for_project(self, project_id: str) -> sqlite3.Row | None:
        return self.conn.execute("SELECT * FROM session_wrapups WHERE project_id=? ORDER BY created_at DESC LIMIT 1", (project_id,)).fetchone()

    # -- Saved views (Finder-style smart views) --

    def saved_views(self) -> list[sqlite3.Row]:
        return self.conn.execute("SELECT * FROM saved_views ORDER BY built_in DESC, sort_order, name COLLATE NOCASE").fetchall()

    def saved_view_by_id(self, view_id: str) -> sqlite3.Row | None:
        return self.conn.execute("SELECT * FROM saved_views WHERE id=?", (view_id,)).fetchone()

    def create_saved_view(self, values: dict[str, Any]) -> sqlite3.Row:
        self.conn.execute(
            """INSERT INTO saved_views(id,name,query_json,sort_field,sort_direction,group_by,built_in,sort_order,created_at,updated_at)
               VALUES (:id,:name,:query_json,:sort_field,:sort_direction,:group_by,:built_in,:sort_order,:created_at,:updated_at)""",
            values,
        )
        self.conn.commit()
        return self.saved_view_by_id(values["id"])

    def update_saved_view(self, view_id: str, values: dict[str, Any]) -> sqlite3.Row | None:
        existing = self.saved_view_by_id(view_id)
        if existing is None:
            return None
        merged = {**dict(existing), **values}
        self.conn.execute(
            "UPDATE saved_views SET name=?, query_json=?, sort_field=?, sort_direction=?, group_by=?, updated_at=? WHERE id=?",
            (merged["name"], merged["query_json"], merged["sort_field"], merged["sort_direction"], merged["group_by"], values.get("updated_at", existing["updated_at"]), view_id),
        )
        self.conn.commit()
        return self.saved_view_by_id(view_id)

    def delete_saved_view(self, view_id: str) -> bool:
        """Refuses to delete a built-in view -- callers should check
        `built_in` before offering delete in the UI, but this is the actual
        backstop, since a client bug or a stale UI must not be able to
        remove one."""
        cursor = self.conn.execute("DELETE FROM saved_views WHERE id=? AND built_in=0", (view_id,))
        self.conn.commit()
        return cursor.rowcount == 1

    # -- Filesystem-authored tags: reconciles an item's `watcher.item.toml`
    # `tags` list into the same canonical `tags`/`item_tags` machinery the
    # UI uses for manual assignment, so an idea's tags are directly
    # comparable to a project's tags (both resolve to the same canonical
    # tag row) -- see IntentIndexer.rebuild() and resurfacing.py.

    def reconcile_filesystem_tags(self, item_id: str, display_names: Iterable[str]) -> None:
        from .tags import normalize_tag
        wanted = {normalize_tag(name): name for name in display_names if normalize_tag(name)}
        existing = self.conn.execute(
            "SELECT tags.id, tags.canonical FROM tags JOIN item_tags ON item_tags.tag_id=tags.id WHERE item_tags.item_id=? AND item_tags.provenance='filesystem'",
            (item_id,),
        ).fetchall()
        for row in existing:
            if row["canonical"] not in wanted:
                self.conn.execute("DELETE FROM item_tags WHERE item_id=? AND tag_id=? AND provenance='filesystem'", (item_id, row["id"]))
        for canonical, display in wanted.items():
            if any(row["canonical"] == canonical for row in existing):
                continue
            tag = self.create_tag(display, provenance="filesystem")
            self.conn.execute(
                "INSERT INTO item_tags(item_id,tag_id,provenance,confidence) VALUES (?,?,?,1) ON CONFLICT(item_id,tag_id) DO NOTHING",
                (item_id, tag["id"], "filesystem"),
            )
        self.conn.commit()

    # -- Idea<->project/idea relationship reconciliation: resolves the
    # human-authored project *names* in `watcher.item.toml` (friendly to
    # write by hand) into `relationships` rows keyed by project id (the
    # `project:<id>` convention `create_relationship` already expects), and
    # withdraws ones no longer named. Unmatched names are simply skipped --
    # a project association is optional and self-heals once a matching
    # project appears on a later reconcile.

    def reconcile_item_relationships(self, item_id: str, *, related_projects: Iterable[str] = (), potential_projects: Iterable[str] = (),
                                      excluded_projects: Iterable[str] = (), related_ideas: Iterable[str] = (), timestamp: str) -> None:
        by_name = {row["name"].casefold(): row["id"] for row in self.projects(status=None)}
        wanted: dict[str, set[str]] = {"related_to_project": set(), "potentially_related_to_project": set(), "excluded_from_project": set(), "related_to_item": set()}
        for name in related_projects:
            if (project_id := by_name.get(str(name).casefold())):
                wanted["related_to_project"].add(f"project:{project_id}")
        for name in potential_projects:
            if (project_id := by_name.get(str(name).casefold())):
                wanted["potentially_related_to_project"].add(f"project:{project_id}")
        for name in excluded_projects:
            if (project_id := by_name.get(str(name).casefold())):
                wanted["excluded_from_project"].add(f"project:{project_id}")
        for other_id in related_ideas:
            if other_id and other_id != item_id and self.item_by_id(other_id):
                wanted["related_to_item"].add(other_id)
        managed_types = tuple(wanted.keys())
        existing = self.conn.execute(
            f"SELECT id, to_id, type FROM relationships WHERE from_id=? AND provenance='filesystem' AND type IN ({','.join('?' for _ in managed_types)})",
            (item_id, *managed_types),
        ).fetchall()
        for row in existing:
            if row["to_id"] not in wanted.get(row["type"], set()):
                self.conn.execute("DELETE FROM relationships WHERE id=?", (row["id"],))
        for relationship_type, targets in wanted.items():
            for to_id in targets:
                if not any(row["to_id"] == to_id and row["type"] == relationship_type for row in existing):
                    self.create_relationship(item_id, to_id, relationship_type, timestamp, provenance="filesystem")
        self.conn.commit()

    # -- Ideas<->Notion sync bookkeeping --

    def idea_notion_link(self, item_id: str) -> sqlite3.Row | None:
        return self.conn.execute("SELECT * FROM idea_notion_links WHERE item_id=?", (item_id,)).fetchone()

    def upsert_idea_notion_link(self, item_id: str, *, notion_page_id: str | None, synced_hash: str | None, notion_last_edited_time: str | None, sync_error: str | None, timestamp: str) -> None:
        self.conn.execute(
            """INSERT INTO idea_notion_links(item_id,notion_page_id,synced_hash,notion_last_edited_time,sync_error,updated_at) VALUES (?,?,?,?,?,?)
               ON CONFLICT(item_id) DO UPDATE SET notion_page_id=excluded.notion_page_id,synced_hash=excluded.synced_hash,notion_last_edited_time=excluded.notion_last_edited_time,sync_error=excluded.sync_error,updated_at=excluded.updated_at""",
            (item_id, notion_page_id, synced_hash, notion_last_edited_time, sync_error, timestamp),
        )
        self.conn.commit()

    def idea_notion_links(self) -> list[sqlite3.Row]:
        return self.conn.execute("SELECT * FROM idea_notion_links").fetchall()
