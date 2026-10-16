"""Local Work Log backfill: rebuild missed history from surviving raw evidence.

The live service only records sessions while it is running and healthy. When it was
not (before the v2 runtime's first session, and on days it silently stopped), the
raw evidence still survived on disk:

- Hammerspoon's filesystem journal (``{"path", "timestamp"}`` per line), and
- the zsh terminal journal (``{"timestamp", "cwd", "repo_root", "category"}``).

This replays that evidence through the *same* ``Sessionizer`` the live runtime uses
-- same noise filter, same project resolution, same inactivity, merge and duration
rules -- against a scratch store, then writes the resulting sessions into the real
store and folds them into the ordinary one-draft-per-project-per-day Work Log. A day
therefore becomes a few project entries made of real sittings, never one entry per
file event.

Rules that keep it honest:

- **Gaps only.** Evidence inside a window the live service already recorded (any
  live session, extended by the inactivity timeout) is skipped, so nothing is counted
  twice and nothing the service observed directly is replaced.
- **Provenance.** Every reconstructed session carries
  ``evidence.provenance.source == "backfill"`` and an id prefixed ``backfill-``; a
  draft says how many of its sessions were reconstructed.
- **No invention.** A day with no surviving evidence is recorded as ``no_evidence``
  in the coverage report, never filled in.
- **Idempotent.** Session ids are a hash of (project, start); a re-run first removes
  its own previous output in the range, then writes the same result again.
- **Local only.** Drafts that exist only because of a backfill get the status
  ``backfilled``, which Notion sync never selects (it sends ``prepared`` and
  ``sync_failed``). Nothing here talks to Notion.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import subprocess
import tempfile
from collections import Counter, defaultdict
from dataclasses import dataclass, field
from datetime import date, datetime, time, timedelta, timezone
from pathlib import Path
from typing import Any, Callable, Iterable, Iterator
from zoneinfo import ZoneInfo

from .core_config import CoreConfig
from .core_engine import utc_now
from .core_store import CoreStore
from .noise import NoiseFilter
from .projects_v2 import ProjectRef, ProjectRegistry
from .sessions_v2 import Session, Sessionizer
from .work_logs_v2 import WorkLogGenerator

BACKFILL_PREFIX = "backfill-"
BACKFILL_DRAFT_STATUS = "backfilled"
COVERAGE_STATE_KEY = "work_logs.backfill"
MINIMUM_ACTIVE_MINUTES = 3  # a sitting leaves evidence in several minutes; a sweep in one or two
METHOD = "replay of surviving local journals through the live sessionizer"

# The journal records every path the moment it changes; the live coalescer sees the
# settled result. These are the shapes that differ, so they are dropped from replay:
#   - an atomic save's temporary (``name.tmp.<pid>.<hex>``, Xcode's ``.sb-…``, BBEdit's
#     ``.!<n>!name``) and a download's partial file (``.name.<8 chars>``): the rename
#     onto the real file is its own event, so counting both doubles one save;
#   - files only tools write: the retired apps' ``Project.betterproject`` documents and
#     lock files.
REPLAY_IGNORED = [re.compile(pattern) for pattern in (
    r"\.tmp\.\d+\.[0-9a-f]+$",
    r"\.sb-[0-9a-f]+-[A-Za-z0-9]+$",
    r"(^|/)\.![0-9]+!",
    r"(^|/)\.[^/]+\.[A-Za-z0-9_]{8}$",
    r"(^|/)Project~?\.betterproject$",
    r"\.lock$",
)]


@dataclass(frozen=True)
class Evidence:
    """One raw observation: a file changed, or a terminal command ran, at ``at``."""

    at: datetime  # UTC
    path: str  # absolute
    kind: str  # "filesystem" | "terminal"


@dataclass
class DayCoverage:
    filesystem_events: int = 0
    terminal_events: int = 0
    in_live_windows: int = 0
    outside_projects: int = 0
    noise: int = 0
    replayed: int = 0
    live_sessions: int = 0
    reconstructed_sessions: int = 0
    reconstructed_active_minutes: float = 0.0

    def status(self) -> str:
        if self.filesystem_events == 0 and self.terminal_events == 0 and self.live_sessions == 0:
            return "no_evidence"
        if self.reconstructed_sessions and self.live_sessions:
            return "recorded_and_reconstructed"
        if self.reconstructed_sessions:
            return "reconstructed"
        if self.live_sessions:
            return "recorded"
        return "no_project_work"  # evidence exists, but none of it was work in a project

    def to_dict(self) -> dict[str, Any]:
        return {**self.__dict__, "reconstructed_active_minutes": round(self.reconstructed_active_minutes, 1), "status": self.status()}


@dataclass
class BackfillResult:
    start: date
    end: date
    sessions: list[dict[str, Any]] = field(default_factory=list)
    coverage: dict[str, DayCoverage] = field(default_factory=dict)
    removed_sessions: int = 0
    drafts_touched: int = 0
    applied: bool = False

    def summary(self) -> dict[str, Any]:
        completed = [s for s in self.sessions if s["status"] == "completed"]
        return {
            "range": [self.start.isoformat(), self.end.isoformat()], "applied": self.applied,
            "sessions_reconstructed": len(completed), "sessions_discarded_as_too_slight": len(self.sessions) - len(completed),
            "previous_backfill_sessions_replaced": self.removed_sessions, "drafts_touched": self.drafts_touched,
            "days": {day: cov.to_dict() for day, cov in sorted(self.coverage.items())},
        }


def read_filesystem_journal(path: Path, start: datetime, end: datetime) -> Iterator[Evidence]:
    """Lines are ``{"path": "...", "timestamp": "YYYY-MM-DDTHH:MM:SSZ"}``. Malformed
    lines are skipped; the journal is append-only and a torn last line is normal."""
    yield from _read_journal(path, start, end, kind="filesystem", path_key="path")


def read_terminal_journal(path: Path, start: datetime, end: datetime) -> Iterator[Evidence]:
    yield from _read_journal(path, start, end, kind="terminal", path_key="cwd")


def _read_journal(path: Path, start: datetime, end: datetime, *, kind: str, path_key: str) -> Iterator[Evidence]:
    if not path.exists():
        return
    with path.open("r", encoding="utf-8", errors="replace") as handle:
        for raw in handle:
            try:
                row = json.loads(raw)
                at = datetime.fromisoformat(str(row["timestamp"]).replace("Z", "+00:00")).astimezone(timezone.utc)
                target = str(row.get(path_key) or "")
            except (ValueError, KeyError, TypeError):
                continue
            if target and start <= at < end:
                yield Evidence(at, os.path.expanduser(target), kind)


def live_windows(store: CoreStore, start: datetime, end: datetime, slack: timedelta) -> list[tuple[datetime, datetime]]:
    """Periods the live service already accounted for: every session it recorded
    (whatever its outcome), from its start to its end plus the inactivity timeout."""
    rows = store.conn.execute(
        "SELECT started_at, ended_at FROM sessions WHERE id NOT LIKE ? AND ended_at >= ? AND started_at < ?",
        (BACKFILL_PREFIX + "%", (start - slack).isoformat(), end.isoformat()),
    ).fetchall()
    windows = sorted((_utc(row[0]), _utc(row[1]) + slack) for row in rows)
    merged: list[tuple[datetime, datetime]] = []
    for lo, hi in windows:
        if merged and lo <= merged[-1][1]:
            merged[-1] = (merged[-1][0], max(merged[-1][1], hi))
        else:
            merged.append((lo, hi))
    return merged


def _utc(value: str) -> datetime:
    parsed = datetime.fromisoformat(value)
    return (parsed if parsed.tzinfo else parsed.replace(tzinfo=timezone.utc)).astimezone(timezone.utc)


def _inside(windows: list[tuple[datetime, datetime]], at: datetime) -> bool:
    # Windows are few (a day has tens at most); a linear scan is clear and fast enough.
    return any(lo <= at <= hi for lo, hi in windows)


def commits_between(project_root: Path, since: str, until: str) -> list[dict[str, Any]]:
    """Historical counterpart of ``sessions_v2.commits_since``: bounded at both ends,
    because a reconstructed session is in the past."""
    if not (project_root / ".git").exists():
        return []
    try:
        result = subprocess.run(
            ["git", "-C", str(project_root), "log", f"--since={since}", f"--until={until}", "--max-count=20", "--pretty=%H%x00%s%x00%aI"],
            text=True, capture_output=True, timeout=5, check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return []
    commits = []
    for line in result.stdout.splitlines():
        parts = line.split("\x00")
        if len(parts) == 3:
            commits.append({"sha": parts[0][:12], "subject": parts[1], "at": parts[2]})
    return commits


class WorkLogBackfill:
    def __init__(
        self,
        store: CoreStore,
        config: CoreConfig,
        *,
        filesystem_journals: Iterable[Path],
        terminal_journals: Iterable[Path] = (),
        timezone_name: str | None = None,
        commits_probe: Callable[[Path, str, str], list[dict[str, Any]]] = commits_between,
        is_directory: Callable[[Path], bool] = lambda path: path.is_dir(),
        now: Callable[[], str] = utc_now,
    ) -> None:
        self.store = store
        self.config = config
        self.filesystem_journals = [Path(p) for p in filesystem_journals]
        self.terminal_journals = [Path(p) for p in terminal_journals]
        self.zone = ZoneInfo(timezone_name) if timezone_name else datetime.now().astimezone().tzinfo
        self.commits_probe = commits_probe
        self.is_directory = is_directory
        self.now = now
        self.noise = NoiseFilter(config.ignore_patterns, config.self_exclude_relpath)
        self.root = config.workspace_root

    # -- planning ---------------------------------------------------------

    def _day_bounds(self, start: date, end: date) -> tuple[datetime, datetime]:
        lo = datetime.combine(start, time.min, tzinfo=self.zone).astimezone(timezone.utc)
        hi = datetime.combine(end + timedelta(days=1), time.min, tzinfo=self.zone).astimezone(timezone.utc)
        return lo, hi

    def _local_day(self, at: datetime) -> str:
        return at.astimezone(self.zone).date().isoformat()

    def plan(self, start: date, end: date) -> BackfillResult:
        """Reconstruct sessions for ``start``..``end`` (local days, inclusive). Writes
        nothing to the real store."""
        lo, hi = self._day_bounds(start, end)
        result = BackfillResult(start, end)
        day = start
        while day <= end:
            result.coverage[day.isoformat()] = DayCoverage()
            day += timedelta(days=1)

        settings = self.config.sessions
        slack = timedelta(minutes=settings.inactivity_timeout_minutes)
        windows = live_windows(self.store, lo, hi, slack)
        for row in self.store.conn.execute(
            "SELECT started_at FROM sessions WHERE id NOT LIKE ? AND started_at >= ? AND started_at < ?",
            (BACKFILL_PREFIX + "%", lo.isoformat(), hi.isoformat()),
        ):
            cov = result.coverage.get(self._local_day(_utc(row[0])))
            if cov is not None:
                cov.live_sessions += 1

        evidence: list[Evidence] = []
        for journal in self.filesystem_journals:
            evidence.extend(read_filesystem_journal(journal, lo, hi))
        for journal in self.terminal_journals:
            evidence.extend(read_terminal_journal(journal, lo, hi))
        evidence.sort(key=lambda item: (item.at, item.kind, item.path))

        with tempfile.TemporaryDirectory(prefix="bw-backfill-") as scratch:
            replay_store = CoreStore(Path(scratch) / "replay.db")
            try:
                refs = self._copy_projects(replay_store)
                registry = ProjectRegistry(replay_store, self.root, self.config.projects.root, write_documents=False)
                sessionizer = Sessionizer(replay_store, settings, self.root, git_probe=lambda _p: {}, commits_probe=lambda _p, _s: [])
                terminal_by_session: Counter[str] = Counter()
                minutes_by_session: dict[str, set[str]] = defaultdict(set)
                bursts = _BurstCollapser(self.config)
                last_at: datetime | None = None
                for item in evidence:
                    cov = result.coverage[self._local_day(item.at)]
                    if item.kind == "filesystem":
                        cov.filesystem_events += 1
                    else:
                        cov.terminal_events += 1
                    if _inside(windows, item.at):
                        cov.in_live_windows += 1
                        continue
                    relpath = self._relpath(item.path)
                    root_relpath = registry.project_root_relpath(relpath) if relpath else None
                    ref = refs.get(root_relpath or "")
                    if ref is None:
                        cov.outside_projects += 1
                        continue
                    is_directory = item.kind == "terminal" or self.is_directory(Path(item.path))
                    if item.kind == "filesystem" and (is_directory or self.noise.classify(relpath).ignored
                                                      or any(rx.search(relpath) for rx in REPLAY_IGNORED)):
                        cov.noise += 1
                        continue
                    if item.kind == "filesystem":
                        verdict = bursts.offer(relpath, item.at)
                        if verdict == "collapsed":
                            cov.noise += 1
                            continue
                        if verdict == "bulk":
                            # The live coalescer's `bulk_change`: one directory-shaped event.
                            relpath, is_directory = str(Path(relpath).parent), True
                    ts = item.at.isoformat()
                    # The live tick loop closes an idle session on its own; replay it.
                    sessionizer.close_expired(ts)
                    sessionizer.touch(ref, relpath, is_directory, ts)
                    cov.replayed += 1
                    open_row = replay_store.open_session()
                    if open_row is not None:
                        minutes_by_session[open_row["id"]].add(ts[:16])
                        if item.kind == "terminal":
                            terminal_by_session[open_row["id"]] += 1
                    last_at = item.at
                if last_at is not None:
                    sessionizer.close_all((last_at + slack).isoformat(), "inactivity")
                rows = replay_store.conn.execute("SELECT * FROM sessions ORDER BY started_at").fetchall()
                result.sessions = [self._finish(Session.from_row(row), terminal_by_session[row["id"]],
                                                len(minutes_by_session[row["id"]]), result) for row in rows]
            finally:
                replay_store.close()
        return result

    def _copy_projects(self, replay_store: CoreStore) -> dict[str, ProjectRef]:
        """Only projects the live service already knows. An unknown folder is never
        given a new identity from history."""
        refs: dict[str, ProjectRef] = {}
        ts = self.now()
        for row in self.store.projects(status="active"):
            replay_store.create_project(project_id=row["id"], path=row["path"], root_path=row["root_path"], name=row["name"],
                                        device=row["device"], inode=row["inode"], timestamp=ts)
            refs[row["path"]] = ProjectRef(row["id"], row["name"], row["path"])
        return refs

    def _relpath(self, absolute: str) -> str | None:
        root = str(self.root).rstrip("/") + "/"
        return absolute[len(root):] if absolute.startswith(root) else None

    def _finish(self, session: Session, terminal_commands: int, active_minutes: int, result: BackfillResult) -> dict[str, Any]:
        session.id = BACKFILL_PREFIX + hashlib.sha256(f"{session.project_id}\0{session.started_at}".encode()).hexdigest()[:24]
        project = self.store.project_by_id(session.project_id)
        if project is not None and session.status == "completed" and self.config.sessions.git_metadata_enabled:
            session.commits = self.commits_probe(self.root / project["path"], session.started_at, session.ended_at)
        session.git = {}  # a close-time HEAD snapshot would describe today, not then
        session.evidence = {
            **session.evidence,
            "terminal_commands": terminal_commands, "minutes_with_evidence": active_minutes,
            "provenance": {"source": "backfill", "method": METHOD, "version": 1},
        }
        session.created_at = session.updated_at = session.ended_at
        session.current_burst_started_at = ""
        if session.status == "completed" and active_minutes < MINIMUM_ACTIVE_MINUTES:
            # Hundreds of paths in an instant or two is a scripted pass over repositories
            # (a clone, a bulk commit, a generator), not a sitting. The live merge window
            # can stitch two such instants half an hour apart into one "session", so the
            # test is how many distinct minutes hold evidence, not the span. Kept, not as work.
            session.status = "discarded"
            session.evidence["discarded_because"] = f"sweep: evidence in only {active_minutes} distinct minute(s)"
        if session.status == "completed":
            cov = result.coverage[self._local_day(_utc(session.started_at))]
            cov.reconstructed_sessions += 1
            cov.reconstructed_active_minutes += session.active_seconds / 60
        return session.to_record()

    # -- applying ---------------------------------------------------------

    def apply(self, result: BackfillResult, generator: WorkLogGenerator) -> BackfillResult:
        """Replace this range's previous backfill output with ``result``, and fold the
        completed sessions into the project-day drafts."""
        lo, hi = self._day_bounds(result.start, result.end)
        previous = [row["id"] for row in self.store.conn.execute(
            "SELECT id FROM sessions WHERE id LIKE ? AND started_at >= ? AND started_at < ?",
            (BACKFILL_PREFIX + "%", lo.isoformat(), hi.isoformat()))]
        touched = self._remove_from_drafts(set(previous))
        with self.store.conn:
            self.store.conn.executemany("DELETE FROM sessions WHERE id=?", [(sid,) for sid in previous])
        result.removed_sessions = len(previous)
        for record in result.sessions:
            self.store.upsert_session(record)
        for record in result.sessions:
            if record["status"] != "completed":
                continue
            session = Session.from_row(self.store.session_by_id(record["id"]))
            draft = generator.prepare(session, status_if_new=BACKFILL_DRAFT_STATUS, keep_existing_status=True)
            if draft is not None:
                touched.add(draft["id"])
        result.drafts_touched = len(touched)
        result.applied = True
        self.store.set_state(COVERAGE_STATE_KEY, {"ran_at": self.now(), **result.summary()}, self.now())
        return result

    def _remove_from_drafts(self, session_ids: set[str]) -> set[str]:
        """Take a previous run's sessions back out of the drafts they were folded into.
        A draft left with no sessions that only a backfill had created is removed."""
        touched: set[str] = set()
        if not session_ids:
            return touched
        for row in self.store.work_log_drafts(limit=100_000):
            ids = json.loads(row["session_ids_json"] or "[]")
            if not session_ids.intersection(ids):
                continue
            touched.add(row["id"])
            remaining = [sid for sid in ids if sid not in session_ids]
            payload = json.loads(row["payload_json"] or "{}")
            facts = [item for item in payload.get("sessions") or [] if item.get("session_id") not in session_ids]
            if not facts:
                with self.store.conn:
                    self.store.conn.execute("DELETE FROM work_log_drafts WHERE id=?", (row["id"],))
                continue
            combined = WorkLogGenerator.combined_payload(row["project_id"], row["project_name"], payload.get("date") or row["date_key"], facts)
            if "llm" in payload:
                combined["llm"] = payload["llm"]
            self.store.upsert_work_log_draft({
                "id": row["id"], "project_id": row["project_id"], "project_name": row["project_name"], "date_key": row["date_key"],
                "session_ids": remaining, "payload": combined, "status": row["status"], "notion_page_id": row["notion_page_id"],
                "sync_error": row["sync_error"], "created_at": row["created_at"], "updated_at": row["updated_at"],
            })
        return touched


def default_journals(home: Path | None = None) -> tuple[list[Path], list[Path]]:
    """Where Hammerspoon and the zsh hook write on this machine: the current inbox
    files, plus the pre-2026-09-12 files they replaced."""
    base = (home or Path.home()) / "Library/Application Support/WorkspaceTelemetry"
    return (
        [base / "fs-events.jsonl", base / "inbox/hammerspoon-filesystem.jsonl"],
        [base / "terminal-events.jsonl", base / "inbox/terminal-events.jsonl"],
    )


class _BurstCollapser:
    """The coalescer's bulk mode, replayed: once a directory sees ``burst_threshold``
    distinct paths within ``burst_window_seconds``, the rest of that burst is one event.
    A checkout, a build or a publish is a single change, not a thousand edits."""

    def __init__(self, config: CoreConfig) -> None:
        coalescing = getattr(config, "coalescing", None)
        self.window = timedelta(seconds=float(getattr(coalescing, "burst_window_seconds", 5.0)))
        self.threshold = int(getattr(coalescing, "burst_threshold", 20))
        self.recent: dict[str, list[tuple[datetime, str]]] = defaultdict(list)
        self.active_until: dict[str, datetime] = {}

    def offer(self, relpath: str, at: datetime) -> str:
        parent = str(Path(relpath).parent)
        until = self.active_until.get(parent)
        if until is not None and at <= until:
            self.active_until[parent] = at + self.window
            return "collapsed"
        recent = [entry for entry in self.recent[parent] if at - entry[0] <= self.window]
        recent.append((at, relpath))
        self.recent[parent] = recent
        if len({path for _, path in recent}) >= self.threshold:
            self.active_until[parent] = at + self.window
            self.recent[parent] = []
            return "bulk"
        return "single"
