"""SQLite persistence layer.

This is the durable substrate for everything downstream: the event history,
the project identity registry, generic filesystem-entry tracking (used for
things like "what's currently in the Inbox"), handler errors, and a small
key/value `state` table for cheap pointers like "current active project".

The schema is intentionally plain SQL so any language with a SQLite driver
(Swift, Lua, Node) can query it directly -- see README.md for the schema
reference. Python consumers should prefer `workspace_watcher.client`.
"""

from __future__ import annotations

import json
import sqlite3
import threading
import time
from functools import wraps
from pathlib import Path
from typing import Any, Callable, Iterable, Optional, TypeVar, cast

from .events import NormalizedEvent


StoreMethod = TypeVar("StoreMethod", bound=Callable[..., Any])


def _serialized(method: StoreMethod) -> StoreMethod:
    """Serialize a public store operation on its one SQLite connection."""

    @wraps(method)
    def wrapped(self: "WorkspaceStore", *args: Any, **kwargs: Any) -> Any:
        with self._connection_lock:
            return method(self, *args, **kwargs)

    return cast(StoreMethod, wrapped)


def _serialize_public_methods(cls: type) -> type:
    """Keep the store safe for its watcher and timer threads.

    SQLite permits a connection to be shared only when callers serialize use.
    Applying this once at the class boundary avoids a fragile, easy-to-miss
    lock around each future query method. ``RLock`` preserves safe calls such
    as ``update_project_path()`` -> ``get_project()``.
    """

    for name, member in tuple(vars(cls).items()):
        if callable(member) and not name.startswith("_"):
            setattr(cls, name, _serialized(member))
    return cls

SCHEMA = """
CREATE TABLE IF NOT EXISTS events (
    id TEXT PRIMARY KEY,
    ts REAL NOT NULL,
    ts_iso TEXT NOT NULL,
    type TEXT NOT NULL,
    path TEXT NOT NULL,
    prev_path TEXT,
    is_directory INTEGER NOT NULL,
    area TEXT NOT NULL,
    area_kind TEXT NOT NULL,
    project_id TEXT,
    project_name TEXT,
    meaningful INTEGER NOT NULL,
    matched_rule TEXT,
    raw_event_count INTEGER NOT NULL DEFAULT 1,
    metadata_json TEXT NOT NULL DEFAULT '{}'
);
CREATE INDEX IF NOT EXISTS idx_events_ts ON events(ts);
CREATE INDEX IF NOT EXISTS idx_events_project ON events(project_id);
CREATE INDEX IF NOT EXISTS idx_events_area_kind ON events(area_kind);

CREATE TABLE IF NOT EXISTS fs_entries (
    path TEXT PRIMARY KEY,
    area TEXT NOT NULL,
    area_kind TEXT NOT NULL,
    is_directory INTEGER NOT NULL,
    project_id TEXT,
    first_seen_at REAL NOT NULL,
    last_event_at REAL NOT NULL,
    last_event_type TEXT NOT NULL,
    event_count INTEGER NOT NULL DEFAULT 1,
    exists_flag INTEGER NOT NULL DEFAULT 1
);
CREATE INDEX IF NOT EXISTS idx_fs_entries_area_kind ON fs_entries(area_kind);

CREATE TABLE IF NOT EXISTS projects (
    project_id TEXT PRIMARY KEY,
    path TEXT NOT NULL,
    name TEXT NOT NULL,
    device INTEGER,
    inode INTEGER,
    first_seen_at REAL NOT NULL,
    last_activity_at REAL,
    meaningful_event_count INTEGER NOT NULL DEFAULT 0,
    name_history_json TEXT NOT NULL DEFAULT '[]',
    status TEXT NOT NULL DEFAULT 'active'
);
CREATE INDEX IF NOT EXISTS idx_projects_path ON projects(path);

CREATE TABLE IF NOT EXISTS handler_errors (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    ts REAL NOT NULL,
    handler TEXT NOT NULL,
    event_id TEXT,
    error TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS state (
    key TEXT PRIMARY KEY,
    value_json TEXT NOT NULL,
    updated_at REAL NOT NULL
);

-- Downstream activity-intelligence tables.  They intentionally live beside
-- the normalized event stream so a dashboard can query one ordinary SQLite
-- file without depending on the watcher process or an external service.
CREATE TABLE IF NOT EXISTS notion_project_cache (
    notion_project_id TEXT PRIMARY KEY,
    local_project_id TEXT,
    local_path TEXT,
    name TEXT NOT NULL,
    status TEXT,
    priority REAL,
    current_work_json TEXT NOT NULL DEFAULT '[]',
    recent_work_json TEXT NOT NULL DEFAULT '[]',
    next_work_json TEXT NOT NULL DEFAULT '[]',
    scores_json TEXT NOT NULL DEFAULT '{}',
    metadata_json TEXT NOT NULL DEFAULT '{}',
    refreshed_at REAL NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_notion_project_cache_local ON notion_project_cache(local_project_id);
CREATE INDEX IF NOT EXISTS idx_notion_project_cache_priority ON notion_project_cache(priority DESC);

CREATE TABLE IF NOT EXISTS activity_sessions (
    session_id TEXT PRIMARY KEY,
    project_id TEXT NOT NULL,
    project_name TEXT NOT NULL,
    started_at REAL NOT NULL,
    ended_at REAL NOT NULL,
    active_seconds REAL NOT NULL DEFAULT 0,
    meaningful_event_count INTEGER NOT NULL DEFAULT 0,
    files_json TEXT NOT NULL DEFAULT '[]',
    burst_count INTEGER NOT NULL DEFAULT 0,
    surrounding_switch_count INTEGER NOT NULL DEFAULT 0,
    intensity REAL NOT NULL DEFAULT 0,
    git_json TEXT NOT NULL DEFAULT '{}',
    confidence REAL NOT NULL DEFAULT 0,
    status TEXT NOT NULL DEFAULT 'open',
    close_reason TEXT,
    created_at REAL NOT NULL,
    updated_at REAL NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_activity_sessions_project_time ON activity_sessions(project_id, started_at);
CREATE INDEX IF NOT EXISTS idx_activity_sessions_status_time ON activity_sessions(status, ended_at);

CREATE TABLE IF NOT EXISTS fragmentation_metrics (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    evaluated_at REAL NOT NULL,
    window_started_at REAL NOT NULL,
    window_minutes REAL NOT NULL,
    project_count INTEGER NOT NULL,
    switch_count INTEGER NOT NULL,
    recurring_project_count INTEGER NOT NULL,
    short_stint_count INTEGER NOT NULL,
    details_json TEXT NOT NULL DEFAULT '{}'
);
CREATE INDEX IF NOT EXISTS idx_fragmentation_metrics_time ON fragmentation_metrics(evaluated_at);

CREATE TABLE IF NOT EXISTS priority_alignment_snapshots (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    evaluated_at REAL NOT NULL,
    window_started_at REAL NOT NULL,
    details_json TEXT NOT NULL DEFAULT '{}'
);
CREATE INDEX IF NOT EXISTS idx_priority_alignment_time ON priority_alignment_snapshots(evaluated_at);

CREATE TABLE IF NOT EXISTS work_log_drafts (
    draft_id TEXT PRIMARY KEY,
    project_id TEXT NOT NULL,
    project_name TEXT NOT NULL,
    date_key TEXT NOT NULL,
    session_ids_json TEXT NOT NULL DEFAULT '[]',
    payload_json TEXT NOT NULL DEFAULT '{}',
    status TEXT NOT NULL DEFAULT 'prepared',
    notion_page_id TEXT,
    created_at REAL NOT NULL,
    updated_at REAL NOT NULL,
    UNIQUE(project_id, date_key)
);
CREATE INDEX IF NOT EXISTS idx_work_log_drafts_date ON work_log_drafts(date_key, project_id);

CREATE TABLE IF NOT EXISTS nudge_decisions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    evaluated_at REAL NOT NULL,
    rule TEXT NOT NULL,
    project_id TEXT,
    project_name TEXT,
    confidence REAL NOT NULL,
    decision TEXT NOT NULL,
    suppression_reason TEXT,
    evidence_json TEXT NOT NULL DEFAULT '{}',
    message TEXT NOT NULL DEFAULT ''
);
CREATE INDEX IF NOT EXISTS idx_nudge_decisions_time ON nudge_decisions(evaluated_at);
CREATE INDEX IF NOT EXISTS idx_nudge_decisions_rule_time ON nudge_decisions(rule, evaluated_at);

-- Additive, downstream-only relevance/resurfacing state. Existing event and
-- activity data are untouched when an older database opens under this code.
CREATE TABLE IF NOT EXISTS relevance_documents (
    candidate_id TEXT PRIMARY KEY,
    source TEXT NOT NULL,
    source_id TEXT NOT NULL,
    title TEXT NOT NULL,
    text_content TEXT NOT NULL DEFAULT '',
    tags_json TEXT NOT NULL DEFAULT '[]',
    project_ids_json TEXT NOT NULL DEFAULT '[]',
    updated_at REAL,
    content_hash TEXT NOT NULL,
    metadata_json TEXT NOT NULL DEFAULT '{}',
    UNIQUE(source, source_id)
);
CREATE INDEX IF NOT EXISTS idx_relevance_documents_source ON relevance_documents(source);

CREATE TABLE IF NOT EXISTS relevance_runs (
    run_id TEXT PRIMARY KEY,
    project_id TEXT NOT NULL,
    project_name TEXT NOT NULL,
    started_at REAL NOT NULL,
    completed_at REAL NOT NULL,
    status TEXT NOT NULL,
    context_json TEXT NOT NULL DEFAULT '{}',
    error TEXT
);
CREATE INDEX IF NOT EXISTS idx_relevance_runs_project_time ON relevance_runs(project_id, completed_at DESC);

CREATE TABLE IF NOT EXISTS relevance_candidates (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    run_id TEXT NOT NULL,
    candidate_id TEXT NOT NULL,
    source TEXT NOT NULL,
    project_id TEXT NOT NULL,
    score REAL NOT NULL,
    decision TEXT NOT NULL,
    suppression_reason TEXT,
    explanation_json TEXT NOT NULL DEFAULT '{}',
    created_at REAL NOT NULL,
    UNIQUE(run_id, candidate_id)
);
CREATE INDEX IF NOT EXISTS idx_relevance_candidates_run ON relevance_candidates(run_id, score DESC);

CREATE TABLE IF NOT EXISTS relevance_item_memory (
    candidate_id TEXT NOT NULL,
    source TEXT NOT NULL,
    project_id TEXT NOT NULL,
    first_seen_at REAL NOT NULL,
    last_considered_at REAL NOT NULL,
    last_surfaced_at REAL,
    surfaced_count INTEGER NOT NULL DEFAULT 0,
    last_dismissed_at REAL,
    dismissal_count INTEGER NOT NULL DEFAULT 0,
    snoozed_until REAL,
    accepted_at REAL,
    most_recent_score REAL,
    evidence_json TEXT NOT NULL DEFAULT '{}',
    PRIMARY KEY(candidate_id, source, project_id)
);
CREATE INDEX IF NOT EXISTS idx_relevance_memory_project ON relevance_item_memory(project_id, last_surfaced_at);

CREATE TABLE IF NOT EXISTS project_detection_decisions (
    project_id TEXT PRIMARY KEY,
    project_name TEXT NOT NULL,
    detected_at REAL NOT NULL,
    status TEXT NOT NULL DEFAULT 'pending',
    options_json TEXT NOT NULL DEFAULT '[]',
    resolution_json TEXT NOT NULL DEFAULT '{}',
    updated_at REAL NOT NULL
);

-- The Finder-facing local read model.  ``.project`` remains the writable
-- authority; this table is deliberately regenerated by ProjectIndex.
CREATE TABLE IF NOT EXISTS local_project_index (
    project_id TEXT PRIMARY KEY,
    watcher_project_id TEXT NOT NULL UNIQUE,
    path TEXT NOT NULL UNIQUE,
    name TEXT NOT NULL,
    managed INTEGER NOT NULL,
    metadata_json TEXT NOT NULL DEFAULT '{}',
    indexed_at REAL NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_local_project_index_name ON local_project_index(name COLLATE NOCASE);

CREATE TABLE IF NOT EXISTS local_project_entities (
    entity_id TEXT PRIMARY KEY,
    project_id TEXT NOT NULL,
    kind TEXT NOT NULL,
    title TEXT,
    data_json TEXT NOT NULL,
    indexed_at REAL NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_local_project_entities_project ON local_project_entities(project_id, kind);

-- Reconciliation findings are durable UI state, not transient notifications.
CREATE TABLE IF NOT EXISTS reconciliation_issues (
    issue_id TEXT PRIMARY KEY,
    kind TEXT NOT NULL,
    project_id TEXT,
    path TEXT,
    severity TEXT NOT NULL,
    state TEXT NOT NULL DEFAULT 'open',
    evidence_json TEXT NOT NULL DEFAULT '{}',
    notification_state TEXT NOT NULL DEFAULT 'new',
    detected_at REAL NOT NULL,
    updated_at REAL NOT NULL,
    resolved_at REAL
);
CREATE INDEX IF NOT EXISTS idx_reconciliation_issues_state ON reconciliation_issues(state, detected_at DESC);

-- Intent folders: tags, items, and Work Log entries the watcher itself
-- generates for significant human decisions (Useful / Not Related / ...).
CREATE TABLE IF NOT EXISTS tags (
    tag_id TEXT PRIMARY KEY,
    normalized TEXT NOT NULL UNIQUE,
    display TEXT NOT NULL,
    created_at REAL NOT NULL
);

CREATE TABLE IF NOT EXISTS tag_aliases (
    alias_normalized TEXT PRIMARY KEY,
    tag_id TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS item_tags (
    item_id TEXT NOT NULL,
    tag_id TEXT NOT NULL,
    provenance TEXT NOT NULL DEFAULT 'user',
    confidence REAL NOT NULL DEFAULT 1.0,
    created_at REAL NOT NULL,
    PRIMARY KEY(item_id, tag_id)
);
CREATE INDEX IF NOT EXISTS idx_item_tags_tag ON item_tags(tag_id);

CREATE TABLE IF NOT EXISTS items (
    item_id TEXT PRIMARY KEY,
    intent_folder TEXT NOT NULL,
    folder_path TEXT NOT NULL,
    path TEXT NOT NULL UNIQUE,
    name TEXT NOT NULL,
    is_directory INTEGER NOT NULL,
    device INTEGER,
    inode INTEGER,
    title TEXT,
    description TEXT,
    source TEXT,
    source_project TEXT,
    action TEXT,
    priority TEXT NOT NULL DEFAULT 'normal',
    archive_state TEXT NOT NULL DEFAULT 'active',
    exists_flag INTEGER NOT NULL DEFAULT 1,
    created_at REAL NOT NULL,
    last_seen_at REAL NOT NULL,
    last_reviewed_at REAL,
    metadata_json TEXT NOT NULL DEFAULT '{}',
    lm_state_json TEXT NOT NULL DEFAULT '{}'
);
CREATE INDEX IF NOT EXISTS idx_items_folder ON items(intent_folder, exists_flag);
CREATE INDEX IF NOT EXISTS idx_items_device_inode ON items(device, inode);

CREATE TABLE IF NOT EXISTS work_log_manual_entries (
    entry_id TEXT PRIMARY KEY,
    project_id TEXT,
    project_name TEXT,
    ts REAL NOT NULL,
    kind TEXT NOT NULL,
    summary TEXT NOT NULL,
    metadata_json TEXT NOT NULL DEFAULT '{}',
    notion_sync_status TEXT NOT NULL DEFAULT 'pending',
    notion_page_id TEXT,
    created_at REAL NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_work_log_manual_entries_project ON work_log_manual_entries(project_id, ts DESC);

-- Product-facing derived state. This deliberately remains separate from the
-- normalized event stream: it can be discarded and recomputed without losing
-- filesystem evidence or canonical project metadata.
CREATE TABLE IF NOT EXISTS folder_statuses (
    path TEXT PRIMARY KEY,
    project_id TEXT,
    status TEXT NOT NULL,
    reasons_json TEXT NOT NULL DEFAULT '[]',
    updated_at REAL NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_folder_statuses_status ON folder_statuses(status, updated_at DESC);

CREATE TABLE IF NOT EXISTS activity_feed (
    activity_id TEXT PRIMARY KEY,
    ts REAL NOT NULL,
    kind TEXT NOT NULL,
    project_id TEXT,
    area_kind TEXT,
    summary TEXT NOT NULL,
    details_json TEXT NOT NULL DEFAULT '{}'
);
CREATE INDEX IF NOT EXISTS idx_activity_feed_time ON activity_feed(ts DESC);
CREATE INDEX IF NOT EXISTS idx_activity_feed_project ON activity_feed(project_id, ts DESC);

CREATE TABLE IF NOT EXISTS project_signals (
    signal_id TEXT PRIMARY KEY,
    project_id TEXT NOT NULL,
    kind TEXT NOT NULL,
    severity TEXT NOT NULL,
    summary TEXT NOT NULL,
    evidence_json TEXT NOT NULL DEFAULT '{}',
    state TEXT NOT NULL DEFAULT 'open',
    created_at REAL NOT NULL,
    resolved_at REAL
);
CREATE INDEX IF NOT EXISTS idx_project_signals_open ON project_signals(project_id, state, created_at DESC);
"""

# Columns added after the tables above first shipped. SQLite's
# ``CREATE TABLE IF NOT EXISTS`` does not add columns to an existing table,
# so an older database needs an explicit, additive ``ALTER TABLE`` -- each
# entry is (table, column, ddl-type-and-default), applied only if missing.
_ADDITIVE_COLUMNS: list[tuple[str, str, str]] = [
    ("relevance_item_memory", "status", "TEXT"),
    ("relevance_item_memory", "reason_json", "TEXT NOT NULL DEFAULT '{}'"),
    ("relevance_item_memory", "defer_next_session_set_at", "REAL"),
    ("project_detection_decisions", "snoozed_until", "REAL"),
]


@_serialize_public_methods
class WorkspaceStore:
    def __init__(self, db_path: Path, read_only: bool = False):
        self.db_path = db_path
        self._connection_lock = threading.RLock()
        if read_only:
            uri = f"file:{db_path}?mode=ro"
            self.conn = sqlite3.connect(uri, uri=True, check_same_thread=False)
        else:
            db_path.parent.mkdir(parents=True, exist_ok=True)
            self.conn = sqlite3.connect(str(db_path), check_same_thread=False)
            self.conn.execute("PRAGMA journal_mode=WAL")
            self.conn.executescript(SCHEMA)
            self._apply_additive_columns()
            self.conn.commit()
        self.conn.row_factory = sqlite3.Row

    def _apply_additive_columns(self) -> None:
        for table, column, ddl in _ADDITIVE_COLUMNS:
            existing = {row[1] for row in self.conn.execute(f"PRAGMA table_info({table})").fetchall()}
            if column not in existing:
                self.conn.execute(f"ALTER TABLE {table} ADD COLUMN {column} {ddl}")

    def close(self) -> None:
        self.conn.close()

    # -- events -----------------------------------------------------------

    def insert_event(self, event: NormalizedEvent) -> None:
        self.conn.execute(
            """INSERT INTO events
               (id, ts, ts_iso, type, path, prev_path, is_directory, area,
                area_kind, project_id, project_name, meaningful, matched_rule,
                raw_event_count, metadata_json)
               VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)""",
            (
                event.event_id, event.ts, event.ts_iso, event.type, event.path,
                event.prev_path, int(event.is_directory), event.area, event.area_kind,
                event.project_id, event.project_name, int(event.meaningful),
                event.matched_rule, event.raw_event_count, json.dumps(event.metadata),
            ),
        )
        self.conn.commit()

    def recent_events(
        self,
        limit: int = 50,
        area_kind: Optional[str] = None,
        project_id: Optional[str] = None,
        meaningful_only: bool = True,
        since_ts: Optional[float] = None,
    ) -> list[sqlite3.Row]:
        clauses = []
        params: list[Any] = []
        if meaningful_only:
            clauses.append("meaningful = 1")
        if area_kind:
            clauses.append("area_kind = ?")
            params.append(area_kind)
        if project_id:
            clauses.append("project_id = ?")
            params.append(project_id)
        if since_ts is not None:
            clauses.append("ts >= ?")
            params.append(since_ts)
        where = f"WHERE {' AND '.join(clauses)}" if clauses else ""
        params.append(limit)
        return self.conn.execute(
            f"SELECT * FROM events {where} ORDER BY ts DESC LIMIT ?", params
        ).fetchall()

    def events_between(
        self, start_ts: float, end_ts: float, *, project_id: Optional[str] = None,
        meaningful_only: bool = True,
    ) -> list[sqlite3.Row]:
        clauses = ["ts >= ?", "ts <= ?"]
        params: list[Any] = [start_ts, end_ts]
        if meaningful_only:
            clauses.append("meaningful = 1")
        if project_id:
            clauses.append("project_id = ?")
            params.append(project_id)
        return self.conn.execute(
            f"SELECT * FROM events WHERE {' AND '.join(clauses)} ORDER BY ts ASC, id ASC", params
        ).fetchall()

    def count_events_since(self, project_id: str, since_ts: float, meaningful_only: bool = True) -> int:
        clause = "AND meaningful = 1" if meaningful_only else ""
        row = self.conn.execute(
            f"SELECT COUNT(*) AS n FROM events WHERE project_id = ? AND ts >= ? {clause}",
            (project_id, since_ts),
        ).fetchone()
        return row["n"] if row else 0

    # -- fs_entries ---------------------------------------------------------

    def upsert_fs_entry(
        self, path: str, area: str, area_kind: str, is_directory: bool,
        project_id: Optional[str], event_type: str, ts: float,
    ) -> None:
        existing = self.conn.execute(
            "SELECT first_seen_at, event_count FROM fs_entries WHERE path = ?", (path,)
        ).fetchone()
        if existing:
            self.conn.execute(
                """UPDATE fs_entries SET area=?, area_kind=?, is_directory=?, project_id=?,
                   last_event_at=?, last_event_type=?, event_count=event_count+1, exists_flag=1
                   WHERE path=?""",
                (area, area_kind, int(is_directory), project_id, ts, event_type, path),
            )
        else:
            self.conn.execute(
                """INSERT INTO fs_entries
                   (path, area, area_kind, is_directory, project_id, first_seen_at,
                    last_event_at, last_event_type, event_count, exists_flag)
                   VALUES (?,?,?,?,?,?,?,?,1,1)""",
                (path, area, area_kind, int(is_directory), project_id, ts, ts, event_type),
            )
        self.conn.commit()

    def rename_fs_entry(self, old_path: str, new_path: str, ts: float, event_type: str) -> None:
        existing = self.conn.execute(
            "SELECT * FROM fs_entries WHERE path = ?", (old_path,)
        ).fetchone()
        self.conn.execute("DELETE FROM fs_entries WHERE path = ?", (old_path,))
        first_seen_at = existing["first_seen_at"] if existing else ts
        event_count = (existing["event_count"] + 1) if existing else 1
        area = existing["area"] if existing else ""
        area_kind = existing["area_kind"] if existing else ""
        is_directory = existing["is_directory"] if existing else 0
        project_id = existing["project_id"] if existing else None
        self.conn.execute(
            """INSERT INTO fs_entries
               (path, area, area_kind, is_directory, project_id, first_seen_at,
                last_event_at, last_event_type, event_count, exists_flag)
               VALUES (?,?,?,?,?,?,?,?,?,1)
               ON CONFLICT(path) DO UPDATE SET
                 last_event_at=excluded.last_event_at,
                 last_event_type=excluded.last_event_type,
                 event_count=excluded.event_count,
                 exists_flag=1""",
            (new_path, area, area_kind, is_directory, project_id, first_seen_at, ts, event_type, event_count),
        )
        self.conn.commit()

    def mark_fs_entry_deleted(self, path: str, ts: float) -> None:
        self.conn.execute(
            "UPDATE fs_entries SET exists_flag=0, last_event_at=?, last_event_type='deleted' WHERE path=?",
            (ts, path),
        )
        self.conn.commit()

    def fs_entries(self, area_kind: str, only_existing: bool = True) -> list[sqlite3.Row]:
        clause = "AND exists_flag = 1" if only_existing else ""
        return self.conn.execute(
            f"SELECT * FROM fs_entries WHERE area_kind = ? {clause} ORDER BY first_seen_at DESC",
            (area_kind,),
        ).fetchall()

    # -- projects -----------------------------------------------------------

    def get_project_by_path(self, path: str) -> Optional[sqlite3.Row]:
        return self.conn.execute("SELECT * FROM projects WHERE path = ?", (path,)).fetchone()

    def get_project_by_inode(self, device: int, inode: int) -> Optional[sqlite3.Row]:
        return self.conn.execute(
            "SELECT * FROM projects WHERE device = ? AND inode = ? AND status != 'deleted'",
            (device, inode),
        ).fetchone()

    def get_project(self, project_id: str) -> Optional[sqlite3.Row]:
        return self.conn.execute("SELECT * FROM projects WHERE project_id = ?", (project_id,)).fetchone()

    def all_projects(self, status: Optional[str] = "active") -> list[sqlite3.Row]:
        if status:
            return self.conn.execute(
                "SELECT * FROM projects WHERE status = ? ORDER BY last_activity_at DESC NULLS LAST", (status,)
            ).fetchall()
        return self.conn.execute("SELECT * FROM projects ORDER BY last_activity_at DESC NULLS LAST").fetchall()

    def create_project(
        self, project_id: str, path: str, name: str,
        device: Optional[int], inode: Optional[int], ts: float,
    ) -> None:
        self.conn.execute(
            """INSERT INTO projects
               (project_id, path, name, device, inode, first_seen_at, last_activity_at,
                meaningful_event_count, name_history_json, status)
               VALUES (?,?,?,?,?,?,?,0,?,'active')""",
            (project_id, path, name, device, inode, ts, ts, json.dumps([{"name": name, "at": ts}])),
        )
        self.conn.commit()

    def update_project_path(self, project_id: str, new_path: str, new_name: str, ts: float) -> None:
        row = self.get_project(project_id)
        history = json.loads(row["name_history_json"]) if row else []
        if not history or history[-1]["name"] != new_name:
            history.append({"name": new_name, "at": ts})
        self.conn.execute(
            "UPDATE projects SET path=?, name=?, name_history_json=? WHERE project_id=?",
            (new_path, new_name, json.dumps(history), project_id),
        )
        self.conn.commit()

    def mark_project_status(self, project_id: str, status: str) -> None:
        self.conn.execute("UPDATE projects SET status=? WHERE project_id=?", (status, project_id))
        self.conn.commit()

    def record_project_activity(self, project_id: str, ts: float) -> None:
        self.conn.execute(
            "UPDATE projects SET last_activity_at=?, meaningful_event_count=meaningful_event_count+1 WHERE project_id=?",
            (ts, project_id),
        )
        self.conn.commit()

    # -- handler errors -------------------------------------------------------

    def record_handler_error(self, handler: str, event_id: Optional[str], error_text: str) -> None:
        self.conn.execute(
            "INSERT INTO handler_errors (ts, handler, event_id, error) VALUES (?,?,?,?)",
            (time.time(), handler, event_id, error_text),
        )
        self.conn.commit()

    def recent_handler_errors(self, limit: int = 20) -> list[sqlite3.Row]:
        return self.conn.execute(
            "SELECT * FROM handler_errors ORDER BY ts DESC LIMIT ?", (limit,)
        ).fetchall()

    # -- state ----------------------------------------------------------------

    def get_state(self, key: str) -> Optional[Any]:
        row = self.conn.execute("SELECT value_json FROM state WHERE key = ?", (key,)).fetchone()
        return json.loads(row["value_json"]) if row else None

    def set_state(self, key: str, value: Any) -> None:
        self.conn.execute(
            """INSERT INTO state (key, value_json, updated_at) VALUES (?,?,?)
               ON CONFLICT(key) DO UPDATE SET value_json=excluded.value_json, updated_at=excluded.updated_at""",
            (key, json.dumps(value), time.time()),
        )
        self.conn.commit()

    # -- activity intelligence -----------------------------------------------

    def replace_notion_project_cache(self, records: Iterable[dict[str, Any]], refreshed_at: float) -> None:
        """Atomically replace a successful remote snapshot.

        A failed Notion call never reaches this method, so the last useful
        local cache remains available during outages.
        """

        self.conn.execute("DELETE FROM notion_project_cache")
        for record in records:
            self.conn.execute(
                """INSERT INTO notion_project_cache
                   (notion_project_id, local_project_id, local_path, name, status, priority,
                    current_work_json, recent_work_json, next_work_json, scores_json,
                    metadata_json, refreshed_at)
                   VALUES (?,?,?,?,?,?,?,?,?,?,?,?)""",
                (
                    record["notion_project_id"], record.get("local_project_id"), record.get("local_path"),
                    record["name"], record.get("status"), record.get("priority"),
                    json.dumps(record.get("current_work", [])), json.dumps(record.get("recent_work", [])),
                    json.dumps(record.get("next_work", [])), json.dumps(record.get("scores", {})),
                    json.dumps(record.get("metadata", {})), refreshed_at,
                ),
            )
        self.conn.commit()

    def cached_notion_projects(self) -> list[sqlite3.Row]:
        return self.conn.execute(
            "SELECT * FROM notion_project_cache ORDER BY priority DESC NULLS LAST, name COLLATE NOCASE"
        ).fetchall()

    def update_notion_project_mapping(
        self, notion_project_id: str, local_project_id: Optional[str], local_path: Optional[str], metadata: dict[str, Any]
    ) -> None:
        self.conn.execute(
            "UPDATE notion_project_cache SET local_project_id=?, local_path=?, metadata_json=? WHERE notion_project_id=?",
            (local_project_id, local_path, json.dumps(metadata), notion_project_id),
        )
        self.conn.commit()

    def upsert_activity_session(self, record: dict[str, Any]) -> None:
        self.conn.execute(
            """INSERT INTO activity_sessions
               (session_id, project_id, project_name, started_at, ended_at, active_seconds,
                meaningful_event_count, files_json, burst_count, surrounding_switch_count,
                intensity, git_json, confidence, status, close_reason, created_at, updated_at)
               VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
               ON CONFLICT(session_id) DO UPDATE SET
                 ended_at=excluded.ended_at, active_seconds=excluded.active_seconds,
                 meaningful_event_count=excluded.meaningful_event_count, files_json=excluded.files_json,
                 burst_count=excluded.burst_count, surrounding_switch_count=excluded.surrounding_switch_count,
                 intensity=excluded.intensity, git_json=excluded.git_json, confidence=excluded.confidence,
                 status=excluded.status, close_reason=excluded.close_reason, updated_at=excluded.updated_at""",
            (
                record["session_id"], record["project_id"], record["project_name"], record["started_at"],
                record["ended_at"], record["active_seconds"], record["meaningful_event_count"],
                json.dumps(record.get("files", [])), record.get("burst_count", 0),
                record.get("surrounding_switch_count", 0), record.get("intensity", 0.0),
                json.dumps(record.get("git", {})), record.get("confidence", 0.0),
                record.get("status", "open"), record.get("close_reason"),
                record.get("created_at", record["started_at"]), record.get("updated_at", record["ended_at"]),
            ),
        )
        self.conn.commit()

    def get_activity_session(self, session_id: str) -> Optional[sqlite3.Row]:
        return self.conn.execute("SELECT * FROM activity_sessions WHERE session_id = ?", (session_id,)).fetchone()

    def open_activity_sessions(self) -> list[sqlite3.Row]:
        return self.conn.execute(
            "SELECT * FROM activity_sessions WHERE status = 'open' ORDER BY ended_at ASC"
        ).fetchall()

    def recent_activity_sessions(
        self, start_ts: Optional[float] = None, *, project_id: Optional[str] = None,
        include_discarded: bool = False, limit: int = 100,
    ) -> list[sqlite3.Row]:
        clauses: list[str] = []
        params: list[Any] = []
        if start_ts is not None:
            clauses.append("ended_at >= ?")
            params.append(start_ts)
        if project_id:
            clauses.append("project_id = ?")
            params.append(project_id)
        if not include_discarded:
            clauses.append("status != 'discarded'")
        where = f"WHERE {' AND '.join(clauses)}" if clauses else ""
        params.append(limit)
        return self.conn.execute(
            f"SELECT * FROM activity_sessions {where} ORDER BY started_at DESC LIMIT ?", params
        ).fetchall()

    def insert_fragmentation_metric(self, record: dict[str, Any]) -> None:
        self.conn.execute(
            """INSERT INTO fragmentation_metrics
               (evaluated_at, window_started_at, window_minutes, project_count, switch_count,
                recurring_project_count, short_stint_count, details_json)
               VALUES (?,?,?,?,?,?,?,?)""",
            (
                record["evaluated_at"], record["window_started_at"], record["window_minutes"],
                record["project_count"], record["switch_count"], record["recurring_project_count"],
                record["short_stint_count"], json.dumps(record.get("details", {})),
            ),
        )
        self.conn.commit()

    def recent_fragmentation_metrics(self, limit: int = 100) -> list[sqlite3.Row]:
        return self.conn.execute(
            "SELECT * FROM fragmentation_metrics ORDER BY evaluated_at DESC LIMIT ?", (limit,)
        ).fetchall()

    def insert_priority_alignment_snapshot(self, evaluated_at: float, window_started_at: float, details: dict[str, Any]) -> None:
        self.conn.execute(
            "INSERT INTO priority_alignment_snapshots (evaluated_at, window_started_at, details_json) VALUES (?,?,?)",
            (evaluated_at, window_started_at, json.dumps(details)),
        )
        self.conn.commit()

    def recent_priority_alignment_snapshots(self, limit: int = 100) -> list[sqlite3.Row]:
        return self.conn.execute(
            "SELECT * FROM priority_alignment_snapshots ORDER BY evaluated_at DESC LIMIT ?", (limit,)
        ).fetchall()

    def upsert_work_log_draft(self, record: dict[str, Any]) -> None:
        self.conn.execute(
            """INSERT INTO work_log_drafts
               (draft_id, project_id, project_name, date_key, session_ids_json, payload_json,
                status, notion_page_id, created_at, updated_at)
               VALUES (?,?,?,?,?,?,?,?,?,?)
               ON CONFLICT(project_id, date_key) DO UPDATE SET
                 session_ids_json=excluded.session_ids_json, payload_json=excluded.payload_json,
                 status=excluded.status, notion_page_id=COALESCE(excluded.notion_page_id, work_log_drafts.notion_page_id),
                 updated_at=excluded.updated_at""",
            (
                record["draft_id"], record["project_id"], record["project_name"], record["date_key"],
                json.dumps(record.get("session_ids", [])), json.dumps(record.get("payload", {})),
                record.get("status", "prepared"), record.get("notion_page_id"),
                record["created_at"], record["updated_at"],
            ),
        )
        self.conn.commit()

    def work_log_drafts(self, date_key: Optional[str] = None, limit: int = 100) -> list[sqlite3.Row]:
        if date_key:
            return self.conn.execute(
                "SELECT * FROM work_log_drafts WHERE date_key = ? OR date_key LIKE ? ORDER BY project_name LIMIT ?",
                (date_key, f"{date_key}:%", limit),
            ).fetchall()
        return self.conn.execute(
            "SELECT * FROM work_log_drafts ORDER BY date_key DESC, project_name LIMIT ?", (limit,)
        ).fetchall()

    def get_work_log_draft(self, project_id: str, date_key: str) -> Optional[sqlite3.Row]:
        return self.conn.execute(
            "SELECT * FROM work_log_drafts WHERE project_id = ? AND date_key = ?", (project_id, date_key)
        ).fetchone()

    def mark_work_log_draft_sync(self, draft_id: str, status: str, notion_page_id: Optional[str] = None) -> None:
        self.conn.execute(
            "UPDATE work_log_drafts SET status=?, notion_page_id=COALESCE(?, notion_page_id), updated_at=? WHERE draft_id=?",
            (status, notion_page_id, time.time(), draft_id),
        )
        self.conn.commit()

    def record_nudge_decision(self, record: dict[str, Any]) -> int:
        cursor = self.conn.execute(
            """INSERT INTO nudge_decisions
               (evaluated_at, rule, project_id, project_name, confidence, decision,
                suppression_reason, evidence_json, message)
               VALUES (?,?,?,?,?,?,?,?,?)""",
            (
                record["evaluated_at"], record["rule"], record.get("project_id"), record.get("project_name"),
                record["confidence"], record["decision"], record.get("suppression_reason"),
                json.dumps(record.get("evidence", {})), record.get("message", ""),
            ),
        )
        self.conn.commit()
        return int(cursor.lastrowid)

    def recent_nudge_decisions(self, limit: int = 100) -> list[sqlite3.Row]:
        return self.conn.execute(
            "SELECT * FROM nudge_decisions ORDER BY evaluated_at DESC, id DESC LIMIT ?", (limit,)
        ).fetchall()

    def latest_delivered_nudge(self, *, rule: Optional[str] = None, project_id: Optional[str] = None) -> Optional[sqlite3.Row]:
        clauses = ["decision = 'delivered'"]
        params: list[Any] = []
        if rule:
            clauses.append("rule = ?")
            params.append(rule)
        if project_id:
            clauses.append("project_id = ?")
            params.append(project_id)
        return self.conn.execute(
            f"SELECT * FROM nudge_decisions WHERE {' AND '.join(clauses)} ORDER BY evaluated_at DESC, id DESC LIMIT 1", params
        ).fetchone()

    def delivered_nudge_count_between(self, start_ts: float, end_ts: float) -> int:
        row = self.conn.execute(
            "SELECT COUNT(*) AS n FROM nudge_decisions WHERE decision = 'delivered' AND evaluated_at >= ? AND evaluated_at < ?",
            (start_ts, end_ts),
        ).fetchone()
        return int(row["n"] if row else 0)

    # -- relevance / project-detection downstream state --------------------

    def upsert_relevance_documents(self, records: Iterable[dict[str, Any]]) -> None:
        for record in records:
            self.conn.execute(
                """INSERT INTO relevance_documents
                   (candidate_id, source, source_id, title, text_content, tags_json,
                    project_ids_json, updated_at, content_hash, metadata_json)
                   VALUES (?,?,?,?,?,?,?,?,?,?)
                   ON CONFLICT(candidate_id) DO UPDATE SET
                     title=excluded.title, text_content=excluded.text_content,
                     tags_json=excluded.tags_json, project_ids_json=excluded.project_ids_json,
                     updated_at=excluded.updated_at, content_hash=excluded.content_hash,
                     metadata_json=excluded.metadata_json""",
                (record["candidate_id"], record["source"], record["source_id"], record["title"],
                 record.get("text", ""), json.dumps(record.get("tags", [])),
                 json.dumps(record.get("project_ids", [])), record.get("updated_at"),
                 record["content_hash"], json.dumps(record.get("metadata", {}))),
            )
        self.conn.commit()

    def relevance_documents(self, limit: int = 500) -> list[sqlite3.Row]:
        return self.conn.execute(
            "SELECT * FROM relevance_documents ORDER BY updated_at DESC NULLS LAST, title COLLATE NOCASE LIMIT ?", (limit,)
        ).fetchall()

    def get_relevance_memory(self, candidate_id: str, source: str, project_id: str) -> Optional[sqlite3.Row]:
        return self.conn.execute(
            "SELECT * FROM relevance_item_memory WHERE candidate_id=? AND source=? AND project_id=?",
            (candidate_id, source, project_id),
        ).fetchone()

    def upsert_relevance_memory(self, record: dict[str, Any]) -> None:
        self.conn.execute(
            """INSERT INTO relevance_item_memory
               (candidate_id, source, project_id, first_seen_at, last_considered_at,
                last_surfaced_at, surfaced_count, last_dismissed_at, dismissal_count,
                snoozed_until, accepted_at, most_recent_score, evidence_json,
                status, reason_json, defer_next_session_set_at)
               VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
               ON CONFLICT(candidate_id, source, project_id) DO UPDATE SET
                 last_considered_at=excluded.last_considered_at, last_surfaced_at=excluded.last_surfaced_at,
                 surfaced_count=excluded.surfaced_count, last_dismissed_at=excluded.last_dismissed_at,
                 dismissal_count=excluded.dismissal_count, snoozed_until=excluded.snoozed_until,
                 accepted_at=excluded.accepted_at, most_recent_score=excluded.most_recent_score,
                 evidence_json=excluded.evidence_json, status=excluded.status, reason_json=excluded.reason_json,
                 defer_next_session_set_at=excluded.defer_next_session_set_at""",
            (record["candidate_id"], record["source"], record["project_id"], record["first_seen_at"],
             record["last_considered_at"], record.get("last_surfaced_at"), record.get("surfaced_count", 0),
             record.get("last_dismissed_at"), record.get("dismissal_count", 0), record.get("snoozed_until"),
             record.get("accepted_at"), record.get("most_recent_score"), json.dumps(record.get("evidence", {})),
             record.get("status"), json.dumps(record.get("reason", {})), record.get("defer_next_session_set_at")),
        )
        self.conn.commit()

    def create_relevance_run(self, record: dict[str, Any], candidates: Iterable[dict[str, Any]]) -> None:
        self.conn.execute(
            """INSERT INTO relevance_runs (run_id, project_id, project_name, started_at, completed_at, status, context_json, error)
               VALUES (?,?,?,?,?,?,?,?)""",
            (record["run_id"], record["project_id"], record["project_name"], record["started_at"],
             record["completed_at"], record["status"], json.dumps(record.get("context", {})), record.get("error")),
        )
        for candidate in candidates:
            self.conn.execute(
                """INSERT INTO relevance_candidates
                   (run_id, candidate_id, source, project_id, score, decision, suppression_reason, explanation_json, created_at)
                   VALUES (?,?,?,?,?,?,?,?,?)""",
                (record["run_id"], candidate["candidate_id"], candidate["source"], record["project_id"],
                 candidate["score"], candidate["decision"], candidate.get("suppression_reason"),
                 json.dumps(candidate.get("explanation", {})), record["completed_at"]),
            )
        self.conn.commit()

    def relevance_runs(self, limit: int = 20) -> list[sqlite3.Row]:
        return self.conn.execute("SELECT * FROM relevance_runs ORDER BY completed_at DESC LIMIT ?", (limit,)).fetchall()

    def relevance_candidates(self, run_id: str) -> list[sqlite3.Row]:
        return self.conn.execute("SELECT * FROM relevance_candidates WHERE run_id=? ORDER BY score DESC, id ASC", (run_id,)).fetchall()

    def set_relevance_feedback(self, candidate_id: str, source: str, project_id: str, action: str, now: float, snoozed_until: float | None = None) -> bool:
        row = self.get_relevance_memory(candidate_id, source, project_id)
        if not row:
            return False
        fields: dict[str, Any] = {"last_considered_at": now, "last_surfaced_at": row["last_surfaced_at"],
                                  "surfaced_count": row["surfaced_count"], "last_dismissed_at": row["last_dismissed_at"],
                                  "dismissal_count": row["dismissal_count"], "snoozed_until": row["snoozed_until"],
                                  "accepted_at": row["accepted_at"], "most_recent_score": row["most_recent_score"],
                                  "evidence": json.loads(row["evidence_json"] or "{}")}
        if action == "dismiss":
            fields["last_dismissed_at"], fields["dismissal_count"] = now, int(row["dismissal_count"]) + 1
        elif action == "snooze":
            fields["snoozed_until"] = snoozed_until
        elif action == "accept":
            fields["accepted_at"] = now
        else:
            raise ValueError("relevance feedback action must be dismiss, snooze, or accept")
        self.upsert_relevance_memory({"candidate_id": candidate_id, "source": source, "project_id": project_id,
                                      "first_seen_at": row["first_seen_at"], **fields})
        return True

    def ensure_project_detection_decision(self, project_id: str, project_name: str, detected_at: float, options: list[dict[str, Any]]) -> None:
        self.conn.execute(
            """INSERT INTO project_detection_decisions (project_id, project_name, detected_at, status, options_json, resolution_json, updated_at)
               VALUES (?,?,?,'pending',?,'{}',?) ON CONFLICT(project_id) DO NOTHING""",
            (project_id, project_name, detected_at, json.dumps(options), detected_at),
        )
        self.conn.commit()

    def project_detection_decisions(self, status: Optional[str] = None, *, due_at: Optional[float] = None) -> list[sqlite3.Row]:
        """List decisions, optionally filtered by status.

        ``due_at`` excludes decisions the user asked to be re-asked about
        later (snoozed_until in the future) -- pass the current time to get
        only what is actually actionable right now.
        """
        query = "SELECT * FROM project_detection_decisions"
        params: list[Any] = []
        if status:
            query += " WHERE status=?"
            params.append(status)
        if due_at is not None:
            query += " AND " if params else " WHERE "
            query += "(snoozed_until IS NULL OR snoozed_until<=?)"
            params.append(due_at)
        query += " ORDER BY detected_at DESC"
        return self.conn.execute(query, params).fetchall()

    def resolve_project_detection(self, project_id: str, status: str, resolution: dict[str, Any], now: float) -> bool:
        cursor = self.conn.execute(
            "UPDATE project_detection_decisions SET status=?, resolution_json=?, snoozed_until=NULL, updated_at=? WHERE project_id=?",
            (status, json.dumps(resolution), now, project_id),
        )
        self.conn.commit()
        return bool(cursor.rowcount)

    def snooze_project_detection(self, project_id: str, until: float, now: float) -> bool:
        """Ask again later instead of forcing a pick now.

        Only meaningful for a still-pending decision -- once resolved, the
        choice is final and snoozing has nothing to defer.
        """
        cursor = self.conn.execute(
            "UPDATE project_detection_decisions SET snoozed_until=?, updated_at=? WHERE project_id=? AND status='pending'",
            (until, now, project_id),
        )
        self.conn.commit()
        return bool(cursor.rowcount)

    # -- local project index / reconciliation --------------------------------

    def replace_local_project_index(self, records: Iterable[dict[str, Any]], indexed_at: float) -> None:
        """Atomically replace the disposable Finder read model.

        This is intentionally separate from ``projects``: that table tracks
        filesystem identity, whereas this one exposes canonical ``.project``
        IDs and metadata to native clients.
        """
        self.conn.execute("BEGIN IMMEDIATE")
        try:
            self.conn.execute("DELETE FROM local_project_entities")
            self.conn.execute("DELETE FROM local_project_index")
            for record in records:
                self.conn.execute(
                    """INSERT INTO local_project_index
                       (project_id, watcher_project_id, path, name, managed, metadata_json, indexed_at)
                       VALUES (?,?,?,?,?,?,?)""",
                    (record["project_id"], record["watcher_project_id"], record["path"], record["name"],
                     int(record["managed"]), json.dumps(record.get("metadata", {})), indexed_at),
                )
                for entity in record.get("entities", []):
                    self.conn.execute(
                        """INSERT OR REPLACE INTO local_project_entities
                           (entity_id, project_id, kind, title, data_json, indexed_at) VALUES (?,?,?,?,?,?)""",
                        (entity["id"], record["project_id"], entity["kind"], entity.get("title"),
                         json.dumps(entity), indexed_at),
                    )
            self.conn.execute("COMMIT")
        except Exception:
            self.conn.execute("ROLLBACK")
            raise

    def upsert_reconciliation_issue(
        self, issue_id: str, kind: str, project_id: str | None, path: str | None,
        severity: str, evidence: dict[str, Any], now: float,
    ) -> bool:
        """Insert/update a finding without resurrecting an ignored item.

        Returns true only for a genuinely new issue, which callers use to
        decide whether one conservative native notification is appropriate.
        """
        existing = self.conn.execute("SELECT state FROM reconciliation_issues WHERE issue_id=?", (issue_id,)).fetchone()
        if existing:
            self.conn.execute(
                "UPDATE reconciliation_issues SET evidence_json=?, updated_at=? WHERE issue_id=?",
                (json.dumps(evidence), now, issue_id),
            )
            self.conn.commit()
            return False
        self.conn.execute(
            """INSERT INTO reconciliation_issues
               (issue_id, kind, project_id, path, severity, state, evidence_json, notification_state, detected_at, updated_at)
               VALUES (?,?,?,?,?,'open',?,'new',?,?)""",
            (issue_id, kind, project_id, path, severity, json.dumps(evidence), now, now),
        )
        self.conn.commit()
        return True

    def reconciliation_issues(self, state: str | None = "open") -> list[sqlite3.Row]:
        if state is None:
            return self.conn.execute("SELECT * FROM reconciliation_issues ORDER BY detected_at DESC").fetchall()
        return self.conn.execute(
            "SELECT * FROM reconciliation_issues WHERE state=? ORDER BY detected_at DESC", (state,)
        ).fetchall()

    def local_project_index_record_for_watcher(self, watcher_project_id: str) -> Optional[sqlite3.Row]:
        return self.conn.execute(
            "SELECT * FROM local_project_index WHERE watcher_project_id=?", (watcher_project_id,)
        ).fetchone()

    def set_reconciliation_issue_state(self, issue_id: str, state: str, now: float) -> bool:
        resolved_at = now if state in {"resolved", "ignored"} else None
        result = self.conn.execute(
            "UPDATE reconciliation_issues SET state=?, updated_at=?, resolved_at=? WHERE issue_id=?",
            (state, now, resolved_at, issue_id),
        )
        self.conn.commit()
        return bool(result.rowcount)

    def mark_reconciliation_issue_notified(self, issue_id: str, now: float) -> None:
        self.conn.execute(
            "UPDATE reconciliation_issues SET notification_state='notified', updated_at=? WHERE issue_id=?",
            (now, issue_id),
        )
        self.conn.commit()

    # -- tags -----------------------------------------------------------------

    def get_or_create_tag(self, display: str, now: Optional[float] = None) -> str:
        from .tags import normalize_tag

        normalized = normalize_tag(display)
        row = self.conn.execute("SELECT tag_id FROM tags WHERE normalized=?", (normalized,)).fetchone()
        if row:
            return str(row["tag_id"])
        alias = self.conn.execute("SELECT tag_id FROM tag_aliases WHERE alias_normalized=?", (normalized,)).fetchone()
        if alias:
            return str(alias["tag_id"])
        import uuid as _uuid
        tag_id = str(_uuid.uuid4())
        self.conn.execute(
            "INSERT INTO tags (tag_id, normalized, display, created_at) VALUES (?,?,?,?)",
            (tag_id, normalized, display.strip(), now if now is not None else time.time()),
        )
        self.conn.commit()
        return tag_id

    def add_tag_alias(self, alias_display: str, canonical_tag_id: str) -> None:
        from .tags import normalize_tag

        self.conn.execute(
            "INSERT INTO tag_aliases (alias_normalized, tag_id) VALUES (?,?) ON CONFLICT(alias_normalized) DO UPDATE SET tag_id=excluded.tag_id",
            (normalize_tag(alias_display), canonical_tag_id),
        )
        self.conn.commit()

    def search_tags(self, query: str, limit: int = 20) -> list[sqlite3.Row]:
        from .tags import normalize_tag

        needle = f"%{normalize_tag(query)}%"
        return self.conn.execute(
            "SELECT * FROM tags WHERE normalized LIKE ? ORDER BY display COLLATE NOCASE LIMIT ?", (needle, limit)
        ).fetchall()

    def tags_for_item(self, item_id: str) -> list[sqlite3.Row]:
        return self.conn.execute(
            """SELECT t.tag_id, t.display, t.normalized, it.provenance, it.confidence
               FROM item_tags it JOIN tags t ON t.tag_id = it.tag_id
               WHERE it.item_id = ? ORDER BY it.provenance, t.display COLLATE NOCASE""",
            (item_id,),
        ).fetchall()

    def items_for_tag(self, tag_id: str) -> list[sqlite3.Row]:
        return self.conn.execute(
            """SELECT i.* FROM items i JOIN item_tags it ON it.item_id = i.item_id
               WHERE it.tag_id = ? AND i.exists_flag = 1 ORDER BY i.name COLLATE NOCASE""",
            (tag_id,),
        ).fetchall()

    def related_tags(self, tag_id: str, limit: int = 20) -> list[sqlite3.Row]:
        """Tags that co-occur with ``tag_id`` on the same item, most items first."""
        return self.conn.execute(
            """SELECT t.tag_id, t.display, COUNT(*) AS shared_items
               FROM item_tags a JOIN item_tags b ON a.item_id = b.item_id AND a.tag_id != b.tag_id
               JOIN tags t ON t.tag_id = b.tag_id
               WHERE a.tag_id = ?
               GROUP BY b.tag_id ORDER BY shared_items DESC, t.display COLLATE NOCASE LIMIT ?""",
            (tag_id, limit),
        ).fetchall()

    def set_item_user_tags(self, item_id: str, display_tags: Iterable[str], now: Optional[float] = None) -> None:
        """Replace all *user*-provenance tags for an item; inferred tags are untouched."""
        current_time = now if now is not None else time.time()
        self.conn.execute("DELETE FROM item_tags WHERE item_id=? AND provenance='user'", (item_id,))
        for display in display_tags:
            tag_id = self.get_or_create_tag(display, current_time)
            self.conn.execute(
                """INSERT INTO item_tags (item_id, tag_id, provenance, confidence, created_at) VALUES (?,?,'user',1.0,?)
                   ON CONFLICT(item_id, tag_id) DO UPDATE SET provenance='user', confidence=1.0""",
                (item_id, tag_id, current_time),
            )
        self.conn.commit()

    def add_item_tag(self, item_id: str, display: str, provenance: str = "user", confidence: float = 1.0, now: Optional[float] = None) -> None:
        current_time = now if now is not None else time.time()
        tag_id = self.get_or_create_tag(display, current_time)
        self.conn.execute(
            """INSERT INTO item_tags (item_id, tag_id, provenance, confidence, created_at) VALUES (?,?,?,?,?)
               ON CONFLICT(item_id, tag_id) DO UPDATE SET
                 provenance=CASE WHEN item_tags.provenance='user' THEN item_tags.provenance ELSE excluded.provenance END,
                 confidence=excluded.confidence""",
            (item_id, tag_id, provenance, confidence, current_time),
        )
        self.conn.commit()

    def set_item_inferred_tags(self, item_id: str, tag_confidences: Iterable[tuple[str, float]], now: Optional[float] = None) -> None:
        current_time = now if now is not None else time.time()
        self.conn.execute("DELETE FROM item_tags WHERE item_id=? AND provenance='inferred'", (item_id,))
        for display, confidence in tag_confidences:
            tag_id = self.get_or_create_tag(display, current_time)
            self.conn.execute(
                """INSERT INTO item_tags (item_id, tag_id, provenance, confidence, created_at) VALUES (?,?,'inferred',?,?)
                   ON CONFLICT(item_id, tag_id) DO UPDATE SET
                     confidence=CASE WHEN item_tags.provenance='user' THEN item_tags.confidence ELSE excluded.confidence END""",
                (item_id, tag_id, confidence, current_time),
            )
        self.conn.commit()

    # -- items (intent-folder contents) ----------------------------------------

    def get_item_by_path(self, path: str) -> Optional[sqlite3.Row]:
        return self.conn.execute("SELECT * FROM items WHERE path=?", (path,)).fetchone()

    def get_item_by_inode(self, device: Optional[int], inode: Optional[int]) -> Optional[sqlite3.Row]:
        if device is None or inode is None:
            return None
        return self.conn.execute(
            "SELECT * FROM items WHERE device=? AND inode=? AND exists_flag=1", (device, inode)
        ).fetchone()

    def get_item(self, item_id: str) -> Optional[sqlite3.Row]:
        return self.conn.execute("SELECT * FROM items WHERE item_id=?", (item_id,)).fetchone()

    def all_items(self, intent_folder: Optional[str] = None, only_existing: bool = False) -> list[sqlite3.Row]:
        clauses, params = [], []
        if intent_folder:
            clauses.append("intent_folder=?")
            params.append(intent_folder)
        if only_existing:
            clauses.append("exists_flag=1")
        where = f"WHERE {' AND '.join(clauses)}" if clauses else ""
        return self.conn.execute(f"SELECT * FROM items {where} ORDER BY name COLLATE NOCASE", params).fetchall()

    def upsert_item(self, record: dict[str, Any]) -> None:
        """Insert, or update in place -- by ``item_id`` first (survives a
        rename/move via inode identity, like ``ProjectRegistry``), falling
        back to ``path`` so an unrelated new item at a reused path still
        upserts cleanly instead of raising a UNIQUE conflict."""

        params = (
            record["intent_folder"], record["folder_path"], record["path"], record["name"],
            int(record["is_directory"]), record.get("device"), record.get("inode"),
            record.get("title"), record.get("description"), record.get("source"), record.get("source_project"),
            record.get("action"), record.get("priority", "normal"), record.get("archive_state", "active"),
            record["last_seen_at"], json.dumps(record.get("metadata_json", {})), record["item_id"],
        )
        cursor = self.conn.execute(
            """UPDATE items SET intent_folder=?, folder_path=?, path=?, name=?, is_directory=?, device=?, inode=?,
                 title=?, description=?, source=?, source_project=?, action=?, priority=?, archive_state=?,
                 exists_flag=1, last_seen_at=?, metadata_json=? WHERE item_id=?""",
            params,
        )
        if cursor.rowcount == 0:
            self.conn.execute(
                """INSERT INTO items
                   (item_id, intent_folder, folder_path, path, name, is_directory, device, inode,
                    title, description, source, source_project, action, priority, archive_state,
                    exists_flag, created_at, last_seen_at, metadata_json)
                   VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,1,?,?,?)
                   ON CONFLICT(path) DO UPDATE SET
                     item_id=excluded.item_id, intent_folder=excluded.intent_folder, folder_path=excluded.folder_path,
                     name=excluded.name, is_directory=excluded.is_directory, device=excluded.device, inode=excluded.inode,
                     title=excluded.title, description=excluded.description, source=excluded.source,
                     source_project=excluded.source_project, action=excluded.action, priority=excluded.priority,
                     archive_state=excluded.archive_state, exists_flag=1, last_seen_at=excluded.last_seen_at,
                     metadata_json=excluded.metadata_json""",
                (
                    record["item_id"], record["intent_folder"], record["folder_path"], record["path"], record["name"],
                    int(record["is_directory"]), record.get("device"), record.get("inode"),
                    record.get("title"), record.get("description"), record.get("source"), record.get("source_project"),
                    record.get("action"), record.get("priority", "normal"), record.get("archive_state", "active"),
                    record["created_at"], record["last_seen_at"], json.dumps(record.get("metadata_json", {})),
                ),
            )
        self.conn.commit()

    def mark_item_deleted(self, path: str, now: float) -> None:
        self.conn.execute("UPDATE items SET exists_flag=0, last_seen_at=? WHERE path=?", (now, path))
        self.conn.commit()

    def mark_item_reviewed(self, item_id: str, now: float) -> None:
        self.conn.execute("UPDATE items SET last_reviewed_at=? WHERE item_id=?", (now, item_id))
        self.conn.commit()

    def mark_item_archive_state(self, item_id: str, state: str) -> None:
        self.conn.execute("UPDATE items SET archive_state=? WHERE item_id=?", (state, item_id))
        self.conn.commit()

    def set_item_lm_state(self, item_id: str, state: dict[str, Any]) -> None:
        self.conn.execute("UPDATE items SET lm_state_json=? WHERE item_id=?", (json.dumps(state), item_id))
        self.conn.commit()

    # -- item/project relationships (extends relevance_item_memory) -----------

    def set_item_relationship(
        self, candidate_id: str, source: str, project_id: str, status: str, now: float,
        *, reason: Optional[dict[str, Any]] = None, defer_until: Optional[float] = None,
        defer_next_session: bool = False,
    ) -> None:
        """Record Useful / Not Related / Deferred / Archived for one item+project pair.

        Builds on the same memory row ``RelevanceEngine`` already reads for
        cooldown/snooze/dismissal, so a decision made here is immediately
        respected by the next relevance run without a second lookup table.
        """
        previous = self.get_relevance_memory(candidate_id, source, project_id)
        fields: dict[str, Any] = {
            "first_seen_at": previous["first_seen_at"] if previous else now,
            "last_considered_at": now,
            "last_surfaced_at": previous["last_surfaced_at"] if previous else None,
            "surfaced_count": previous["surfaced_count"] if previous else 0,
            "last_dismissed_at": previous["last_dismissed_at"] if previous else None,
            "dismissal_count": previous["dismissal_count"] if previous else 0,
            "snoozed_until": previous["snoozed_until"] if previous else None,
            "accepted_at": previous["accepted_at"] if previous else None,
            "most_recent_score": previous["most_recent_score"] if previous else None,
            "evidence": json.loads(previous["evidence_json"] or "{}") if previous else {},
        }
        fields["status"] = status
        fields["reason"] = reason or {}
        fields["defer_next_session_set_at"] = now if defer_next_session else None
        if status == "useful":
            fields["accepted_at"] = now
        elif status == "not_related":
            fields["last_dismissed_at"] = now
            fields["dismissal_count"] = int(fields["dismissal_count"]) + 1
        elif status == "deferred":
            fields["snoozed_until"] = defer_until
        self.upsert_relevance_memory({"candidate_id": candidate_id, "source": source, "project_id": project_id, **fields})

    def has_activity_session_started_since(self, project_id: str, since_ts: float) -> bool:
        row = self.conn.execute(
            "SELECT 1 FROM activity_sessions WHERE project_id=? AND started_at>? LIMIT 1", (project_id, since_ts)
        ).fetchone()
        return row is not None

    # -- Work Log manual entries (significant human decisions) ----------------

    def add_work_log_manual_entry(self, record: dict[str, Any]) -> None:
        self.conn.execute(
            """INSERT INTO work_log_manual_entries
               (entry_id, project_id, project_name, ts, kind, summary, metadata_json, notion_sync_status, notion_page_id, created_at)
               VALUES (?,?,?,?,?,?,?,?,?,?)""",
            (
                record["entry_id"], record.get("project_id"), record.get("project_name"), record["ts"],
                record["kind"], record["summary"], json.dumps(record.get("metadata", {})),
                record.get("notion_sync_status", "pending"), record.get("notion_page_id"), record.get("created_at", record["ts"]),
            ),
        )
        self.conn.commit()

    def recent_work_log_manual_entries(self, project_id: Optional[str] = None, limit: int = 50) -> list[sqlite3.Row]:
        if project_id:
            return self.conn.execute(
                "SELECT * FROM work_log_manual_entries WHERE project_id=? ORDER BY ts DESC LIMIT ?", (project_id, limit)
            ).fetchall()
        return self.conn.execute("SELECT * FROM work_log_manual_entries ORDER BY ts DESC LIMIT ?", (limit,)).fetchall()

    def pending_work_log_manual_entries(self, limit: int = 10) -> list[sqlite3.Row]:
        return self.conn.execute(
            "SELECT * FROM work_log_manual_entries WHERE notion_sync_status IN ('pending','sync_failed') ORDER BY ts LIMIT ?",
            (limit,),
        ).fetchall()

    def mark_work_log_manual_entry_synced(self, entry_id: str, status: str, notion_page_id: Optional[str] = None) -> None:
        self.conn.execute(
            "UPDATE work_log_manual_entries SET notion_sync_status=?, notion_page_id=COALESCE(?, notion_page_id) WHERE entry_id=?",
            (status, notion_page_id, entry_id),
        )
        self.conn.commit()

    # -- Product read models -------------------------------------------------

    def upsert_folder_status(self, path: str, project_id: Optional[str], status: str, reasons: list[dict[str, Any]], now: float) -> bool:
        """Write only when explainable state changed; return whether it did."""
        encoded = json.dumps(reasons, sort_keys=True)
        existing = self.conn.execute("SELECT project_id, status, reasons_json FROM folder_statuses WHERE path=?", (path,)).fetchone()
        if existing and existing["project_id"] == project_id and existing["status"] == status and existing["reasons_json"] == encoded:
            return False
        self.conn.execute(
            """INSERT INTO folder_statuses(path, project_id, status, reasons_json, updated_at) VALUES (?,?,?,?,?)
               ON CONFLICT(path) DO UPDATE SET project_id=excluded.project_id, status=excluded.status,
               reasons_json=excluded.reasons_json, updated_at=excluded.updated_at""",
            (path, project_id, status, encoded, now),
        )
        self.conn.commit()
        return True

    def folder_statuses(self, *, project_id: Optional[str] = None, status: Optional[str] = None) -> list[sqlite3.Row]:
        clauses, params = [], []
        if project_id:
            clauses.append("project_id=?"); params.append(project_id)
        if status:
            clauses.append("status=?"); params.append(status)
        where = " WHERE " + " AND ".join(clauses) if clauses else ""
        return self.conn.execute(f"SELECT * FROM folder_statuses{where} ORDER BY updated_at DESC, path COLLATE NOCASE", params).fetchall()

    def delete_folder_status(self, path: str) -> None:
        self.conn.execute("DELETE FROM folder_statuses WHERE path=?", (path,))
        self.conn.commit()

    def add_activity_feed(self, activity_id: str, ts: float, kind: str, summary: str, *, project_id: Optional[str] = None, area_kind: Optional[str] = None, details: Optional[dict[str, Any]] = None) -> None:
        self.conn.execute(
            "INSERT OR IGNORE INTO activity_feed(activity_id, ts, kind, project_id, area_kind, summary, details_json) VALUES (?,?,?,?,?,?,?)",
            (activity_id, ts, kind, project_id, area_kind, summary, json.dumps(details or {})),
        )
        self.conn.commit()

    def recent_activity_feed(self, limit: int = 50, *, project_id: Optional[str] = None, kind: Optional[str] = None) -> list[sqlite3.Row]:
        clauses, params = [], []
        if project_id:
            clauses.append("project_id=?"); params.append(project_id)
        if kind:
            clauses.append("kind=?"); params.append(kind)
        where = " WHERE " + " AND ".join(clauses) if clauses else ""
        params.append(limit)
        return self.conn.execute(f"SELECT * FROM activity_feed{where} ORDER BY ts DESC, activity_id DESC LIMIT ?", params).fetchall()

    def record_project_signal(self, signal_id: str, project_id: str, kind: str, severity: str, summary: str, evidence: dict[str, Any], now: float) -> None:
        self.conn.execute(
            "INSERT INTO project_signals(signal_id, project_id, kind, severity, summary, evidence_json, state, created_at) VALUES (?,?,?,?,?,?, 'open', ?)",
            (signal_id, project_id, kind, severity, summary, json.dumps(evidence), now),
        )
        self.conn.commit()

    def project_signals(self, project_id: str, *, state: str = "open") -> list[sqlite3.Row]:
        return self.conn.execute("SELECT * FROM project_signals WHERE project_id=? AND state=? ORDER BY created_at DESC", (project_id, state)).fetchall()

    def resolve_project_signals(self, project_id: str, kind: Optional[str], now: float) -> int:
        clauses, params = ["project_id=?", "state='open'"], [project_id]
        if kind:
            clauses.append("kind=?"); params.append(kind)
        result = self.conn.execute(f"UPDATE project_signals SET state='resolved', resolved_at=? WHERE {' AND '.join(clauses)}", [now, *params])
        self.conn.commit()
        return int(result.rowcount)
