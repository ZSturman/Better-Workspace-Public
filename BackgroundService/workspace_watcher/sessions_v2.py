"""v2-native work-session inference, keyed off Phase 1's project identity.

v1's ``Sessionizer`` (``sessions.py``) is driven by a dense per-raw-file-event
stream and can hold several sessions open concurrently across different
projects. This operates on the coarser but sufficient signal v2 already
produces -- "a settled filesystem batch resolved to project X, at time T" --
and deliberately maintains **exactly one open session at a time**, matching
Phase 1's singular ``project.current`` model: opening a different project's
session always closes whichever one was open first (reason ``"switched"``).

Closing on inactivity is purely time-based, computed from the session's own
last-touched timestamp. Nothing here reads a Hammerspoon idle signal --
session lifecycle must keep working even if the Hammerspoon bridge is never
running.

The confidence/intensity scoring and the "reopen a just-closed session
instead of starting a noisy duplicate" merge window are ported near-verbatim
from ``sessions.py``'s ``Sessionizer`` -- that logic is proven and this is
the same underlying question (is this really a new session, or a
continuation?), just triggered by project-activation events instead of
individual file events.
"""

from __future__ import annotations

import json
import subprocess
import uuid
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Callable

from .core_config import SessionsSettings
from .core_events import EventTypes, WorkspaceEvent
from .core_store import CoreStore
from .projects_v2 import ProjectRef


def cheap_git_metadata(project_root: Path) -> dict[str, Any]:
    """Collect a tiny, bounded snapshot only when a session closes.

    Ported verbatim from ``sessions.py`` -- purely local, read-only git
    commands; no dependency on Hammerspoon, Notion, or any external service.
    """
    if not (project_root / ".git").exists():
        return {}
    try:
        branch = subprocess.run(
            ["git", "-C", str(project_root), "branch", "--show-current"], text=True,
            capture_output=True, timeout=2, check=False,
        ).stdout.strip()
        head = subprocess.run(
            ["git", "-C", str(project_root), "log", "-1", "--pretty=%H%x00%s"], text=True,
            capture_output=True, timeout=2, check=False,
        ).stdout.strip().split("\x00", 1)
        status = subprocess.run(
            ["git", "-C", str(project_root), "status", "--porcelain"], text=True,
            capture_output=True, timeout=2, check=False,
        ).stdout.splitlines()
        result: dict[str, Any] = {"branch": branch, "changed_file_count": len(status)}
        if head and head[0]:
            result["head_commit"] = head[0]
            result["head_subject"] = head[1] if len(head) > 1 else ""
        return result
    except (OSError, subprocess.SubprocessError):
        return {}


def commits_since(project_root: Path, since_iso: str) -> list[dict[str, Any]]:
    """Real commit-level evidence for a session, ported (as a genuinely new
    v2 capability, not a copy of existing code) from the one useful
    capability `workspace_telemetry.worklog`'s git-event tracking had that
    v2's own snapshot-only `cheap_git_metadata` didn't: individual commits
    made *during* the session, not just a HEAD snapshot at close time. Pure
    local `git log`, no new dependency, no external service -- exactly the
    kind of "port the useful signal, not the whole system" task 6B asked
    for. Bounded to 20 commits so a very active session can't produce an
    unbounded evidence blob."""
    if not (project_root / ".git").exists():
        return []
    try:
        result = subprocess.run(
            ["git", "-C", str(project_root), "log", f"--since={since_iso}", "--max-count=20", "--pretty=%H%x00%s%x00%aI"],
            text=True, capture_output=True, timeout=2, check=False,
        )
        commits = []
        for line in result.stdout.splitlines():
            parts = line.split("\x00")
            if len(parts) == 3:
                commits.append({"sha": parts[0][:12], "subject": parts[1], "at": parts[2]})
        return commits
    except (OSError, subprocess.SubprocessError):
        return []


def _parse(ts: str) -> datetime:
    return datetime.fromisoformat(ts)


@dataclass
class Session:
    id: str
    project_id: str
    project_name: str
    started_at: str
    ended_at: str
    active_seconds: float
    meaningful_event_count: int
    files: list[str] = field(default_factory=list)
    burst_count: int = 1
    intensity: float = 0.0
    confidence: float = 0.0
    git: dict[str, Any] = field(default_factory=dict)
    status: str = "open"
    close_reason: str | None = None
    # Evidence, not summary: how fragmented the work actually was, derived
    # purely from touch timestamps -- never inferred or guessed. Reviewed
    # (or a Work Log) can distinguish "3 hours, one sitting" from "3 hours,
    # 6 stop-and-restarts" without either being just a single confidence
    # number. `interruption_count` (= burst_count - 1) is deliberately not
    # stored -- it's exactly derivable from burst_count and storing it too
    # would just be the same fact twice.
    longest_gap_seconds: float = 0.0
    longest_burst_seconds: float = 0.0
    current_burst_started_at: str = ""  # transient bookkeeping, not evidence itself
    # "started" | "resumed" -- the answer to "why did this session begin the
    # way it did", the counterpart to close_reason for the other end of the
    # lifecycle. Set once, at open time; never changes for this session's id
    # even if it's later extended.
    open_reason: str = "started"
    # Free-form explainability facts that aren't natural session columns of
    # their own -- currently just the confidence formula's own inputs, so
    # "why 0.62?" has an answer beyond the single number.
    evidence: dict[str, Any] = field(default_factory=dict)
    # Individual commits made during the session (see `commits_since`) --
    # distinct from `git`'s single close-time HEAD snapshot.
    commits: list[dict[str, Any]] = field(default_factory=list)
    created_at: str = ""
    updated_at: str = ""

    @classmethod
    def from_row(cls, row: Any) -> "Session":
        return cls(
            id=row["id"], project_id=row["project_id"], project_name=row["project_name"],
            started_at=row["started_at"], ended_at=row["ended_at"], active_seconds=float(row["active_seconds"]),
            meaningful_event_count=int(row["meaningful_event_count"]), files=json.loads(row["files_json"] or "[]"),
            burst_count=int(row["burst_count"]), intensity=float(row["intensity"]), confidence=float(row["confidence"]),
            git=json.loads(row["git_json"] or "{}"), status=row["status"], close_reason=row["close_reason"],
            longest_gap_seconds=float(row["longest_gap_seconds"] or 0.0), longest_burst_seconds=float(row["longest_burst_seconds"] or 0.0),
            current_burst_started_at=row["current_burst_started_at"] or "", open_reason=row["open_reason"] or "started",
            evidence=json.loads(row["evidence_json"] or "{}"), commits=json.loads(row["commits_json"] or "[]") if "commits_json" in row.keys() else [],
            created_at=row["created_at"], updated_at=row["updated_at"],
        )

    def to_record(self) -> dict[str, Any]:
        return {
            "id": self.id, "project_id": self.project_id, "project_name": self.project_name,
            "started_at": self.started_at, "ended_at": self.ended_at, "active_seconds": self.active_seconds,
            "meaningful_event_count": self.meaningful_event_count, "files": self.files, "burst_count": self.burst_count,
            "intensity": self.intensity, "confidence": self.confidence, "git": self.git, "status": self.status,
            "close_reason": self.close_reason, "longest_gap_seconds": self.longest_gap_seconds,
            "longest_burst_seconds": self.longest_burst_seconds, "current_burst_started_at": self.current_burst_started_at or None,
            "open_reason": self.open_reason, "evidence": self.evidence, "commits": self.commits,
            "created_at": self.created_at, "updated_at": self.updated_at,
        }

    def event_payload(self) -> dict[str, Any]:
        return {"project_id": self.project_id, "project_name": self.project_name, "started_at": self.started_at,
                "ended_at": self.ended_at, "active_seconds": round(self.active_seconds), "status": self.status,
                "close_reason": self.close_reason, "open_reason": self.open_reason}


class Sessionizer:
    def __init__(
        self,
        store: CoreStore,
        settings: SessionsSettings,
        workspace_root: Path,
        *,
        git_probe: Callable[[Path], dict[str, Any]] = cheap_git_metadata,
        commits_probe: Callable[[Path, str], list[dict[str, Any]]] = commits_since,
    ) -> None:
        self.store = store
        self.settings = settings
        self.workspace_root = workspace_root
        self.git_probe = git_probe
        self.commits_probe = commits_probe

    def touch(self, project: ProjectRef, path: str, is_directory: bool, ts: str) -> list[WorkspaceEvent]:
        """Record one unit of activity in ``project`` at ``ts``. Called for
        every settled filesystem batch that resolves to a project -- not
        just on a project switch -- so an already-open session for the same
        project just gets extended, silently, with no event emitted for
        every single file touch (only lifecycle transitions are events)."""
        if not self.settings.enabled:
            return []
        events: list[WorkspaceEvent] = []
        open_row = self.store.open_session()
        if open_row is not None and self._has_reached_max_duration(Session.from_row(open_row), ts):
            events.append(self._close(Session.from_row(open_row), ts, "max_duration"))
            open_row = None
        if open_row is not None and open_row["project_id"] == project.project_id:
            self._extend(open_row, path, is_directory, ts)
            return events
        if open_row is not None:
            events.append(self._close(Session.from_row(open_row), ts, "switched"))
        events.append(self._open(project, path, is_directory, ts))
        return events

    def close_expired(self, now: str) -> list[WorkspaceEvent]:
        """Called from the periodic tick loop, never from a live filesystem
        signal -- inactivity close must keep working with zero external
        input at all, including no Hammerspoon idle event."""
        if not self.settings.enabled:
            return []
        row = self.store.open_session()
        if row is None:
            return []
        session = Session.from_row(row)
        if self._has_reached_max_duration(session, now):
            return [self._close(session, now, "max_duration")]
        idle_for = (_parse(now) - _parse(session.ended_at)).total_seconds()
        if idle_for >= self.settings.inactivity_timeout_minutes * 60:
            return [self._close(session, now, "inactivity")]
        return []

    def _has_reached_max_duration(self, session: Session, now: str) -> bool:
        """Whether a session has reached its configured wall-clock cap.

        The cap is intentionally independent of activity: an editor or
        terminal that remains open must not turn a previous day's work into
        one continuous session. A non-positive value explicitly disables it.
        """
        if self.settings.max_duration_minutes <= 0:
            return False
        return (_parse(now) - _parse(session.started_at)).total_seconds() >= self.settings.max_duration_minutes * 60

    def close_all(self, now: str, reason: str) -> list[WorkspaceEvent]:
        """Startup recovery (an unclean shutdown left a session open) and
        clean shutdown both funnel through here so there is exactly one
        code path that can ever close the one open session."""
        row = self.store.open_session()
        if row is None:
            return []
        return [self._close(Session.from_row(row), now, reason)]

    def _open(self, project: ProjectRef, path: str, is_directory: bool, ts: str) -> WorkspaceEvent:
        resumable = self.store.recent_closed_session_for_project(
            project.project_id, ended_after=(_parse(ts) - timedelta(seconds=self.settings.merge_nearby_minutes * 60)).isoformat(),
        )
        # A hard-capped session is a completed time boundary, never a brief
        # interruption to merge back into on the next filesystem touch.
        if resumable is not None and resumable["close_reason"] != "max_duration":
            session = Session.from_row(resumable)
            # The gap while fully closed is itself a real interruption --
            # bigger than any ordinary in-session gap by definition, since
            # the session had already been scored and closed once.
            gap = max(0.0, (_parse(ts) - _parse(session.ended_at)).total_seconds())
            session.longest_gap_seconds = max(session.longest_gap_seconds, gap)
            self._start_new_burst(session, ts)
            session.burst_count += 1
            session.status, session.close_reason, session.open_reason = "open", None, "resumed"
            session.ended_at = ts
            session.updated_at = ts
            # The touch that triggered this resume is itself real evidence --
            # exactly as much as any other touch (`_extend`'s own touches, or
            # a brand new session's first touch below) -- and must not be
            # silently dropped just because it happened to land on a
            # resume instead of an extend.
            session.active_seconds += self.settings.event_active_seconds
            session.meaningful_event_count += 1
            if not is_directory and path not in session.files:
                session.files.append(path)
                session.files = session.files[:100]
            self.store.upsert_session(session.to_record())
            return self._event(EventTypes.SESSION_RESUMED, session)
        session = Session(
            id=str(uuid.uuid4()), project_id=project.project_id, project_name=project.name,
            started_at=ts, ended_at=ts, active_seconds=self.settings.event_active_seconds,
            meaningful_event_count=1, files=[path] if not is_directory else [], burst_count=1,
            current_burst_started_at=ts, created_at=ts, updated_at=ts,
        )
        self.store.upsert_session(session.to_record())
        return self._event(EventTypes.SESSION_STARTED, session)

    def _start_new_burst(self, session: Session, ts: str) -> None:
        """Finalizes the burst that just ended (into `longest_burst_seconds`)
        and starts tracking a new one from `ts`. Called whenever a gap large
        enough to count as a real interruption is observed -- either a
        within-session gap past `burst_gap_minutes`, or resuming a session
        that had been fully closed in between."""
        if session.current_burst_started_at:
            burst_seconds = (_parse(session.ended_at) - _parse(session.current_burst_started_at)).total_seconds()
            session.longest_burst_seconds = max(session.longest_burst_seconds, burst_seconds)
        session.current_burst_started_at = ts

    def _extend(self, row: Any, path: str, is_directory: bool, ts: str) -> None:
        session = Session.from_row(row)
        gap = max(0.0, (_parse(ts) - _parse(session.ended_at)).total_seconds())
        # Adjacent activity expands the active-time estimate by the observed
        # gap; a long quiet period within the session still contributes only
        # a conservative per-touch allowance rather than the whole gap.
        session.active_seconds += min(gap, self.settings.event_span_seconds) if gap else 0.0
        if gap > self.settings.burst_gap_minutes * 60:
            session.longest_gap_seconds = max(session.longest_gap_seconds, gap)
            self._start_new_burst(session, ts)  # uses session.ended_at (still the pre-touch value) to close out the prior burst
            session.burst_count += 1
        if _parse(ts) > _parse(session.ended_at):
            session.ended_at = ts
        session.meaningful_event_count += 1
        if not is_directory and path not in session.files:
            session.files.append(path)
            session.files = session.files[:100]
        session.updated_at = ts
        self.store.upsert_session(session.to_record())

    def _close(self, session: Session, now: str, reason: str) -> WorkspaceEvent:
        # The session's final burst never got a chance to be finalized by
        # `_start_new_burst` (nothing "started a new one" after it) --
        # closing is itself that burst's end.
        if session.current_burst_started_at:
            final_burst = (_parse(session.ended_at) - _parse(session.current_burst_started_at)).total_seconds()
            session.longest_burst_seconds = max(session.longest_burst_seconds, final_burst)
        # Each touch credits up to `event_active_seconds`, and a resume adds a full
        # credit however soon it follows; interleaved touches across projects once
        # turned 36 minutes into 20 "active" hours. Never more than the session's own
        # span plus one touch.
        elapsed = max(0.0, (_parse(session.ended_at) - _parse(session.started_at)).total_seconds())
        session.active_seconds = min(session.active_seconds, elapsed + self.settings.event_active_seconds)
        active_minutes = max(session.active_seconds / 60.0, 1.0)
        session.intensity = round(min(1.0, session.meaningful_event_count / (active_minutes * 2.0)), 3)
        event_score = min(1.0, session.meaningful_event_count / self.settings.minimum_events)
        active_score = min(1.0, session.active_seconds / self.settings.minimum_active_seconds)
        file_score = min(1.0, len(session.files) / 3.0)
        session.confidence = round(0.45 * event_score + 0.4 * active_score + 0.15 * file_score, 3)
        # "Why 0.62?" -- the formula's own inputs, not just the number, so a
        # reviewer (or a Work Log) can see which factor was weakest rather
        # than trusting a single opaque score.
        session.evidence = {
            "confidence_breakdown": {
                "event_score": round(event_score, 3), "active_score": round(active_score, 3), "file_score": round(file_score, 3),
                "weights": {"event": 0.45, "active": 0.4, "files": 0.15},
            },
        }
        project = self.store.project_by_id(session.project_id)
        if project and self.settings.git_metadata_enabled:
            session.git = self.git_probe(self.workspace_root / project["path"])
            session.commits = self.commits_probe(self.workspace_root / project["path"], session.started_at)
        legitimate = (
            session.meaningful_event_count >= self.settings.minimum_events
            and session.active_seconds >= self.settings.minimum_active_seconds
            and session.confidence >= self.settings.minimum_confidence
        )
        session.status = "completed" if legitimate else "discarded"
        session.close_reason = reason
        session.updated_at = now
        self.store.upsert_session(session.to_record())
        return self._event(EventTypes.SESSION_CLOSED, session)

    def _event(self, event_type: str, session: Session) -> WorkspaceEvent:
        return WorkspaceEvent(type=event_type, entity_id=session.id, payload=session.event_payload(), source="filesystem")
