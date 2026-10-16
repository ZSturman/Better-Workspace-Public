"""The one shared project view model: identity, domain/tags, score, next
action, and session/goal summary. Every surface that needs to answer
"what is this project, and what should I do with it" -- the ranked widget,
the per-project widget, the Finder-style browser, the query/filter engine,
the project detail inspector -- builds its answer from `build_project_views`
in this module. Nothing computes its own, different notion of a project's
state; this is the single place that reads `projects`/`sessions`/
`project_goals`/`work_log_drafts`/`notion_project_cache` and produces one
consistent shape.

Scoring is deterministic and fully explainable (`score_factors` on every
view): it never fabricates data, and a project with no session history
simply scores 0 rather than being guessed at.
"""

from __future__ import annotations

import json
from datetime import datetime, timezone
from pathlib import Path, PurePosixPath
from typing import Any

from .core_store import CoreStore
from .project_documents import document_path
from .project_files import notion_page_url

# Tuned, documented weights -- not learned, not hidden. Recency and
# unfinished-work signal dominate because the product question is "what
# should I get back to," not "what is objectively most important."
RECENCY_WEIGHT = 0.35
MOMENTUM_WEIGHT = 0.20
UNFINISHED_WEIGHT = 0.25
CONFIDENCE_WEIGHT = 0.20
RECENCY_HALF_LIFE_DAYS = 4.0
MOMENTUM_WINDOW_DAYS = 14
MOMENTUM_SESSIONS_FOR_MAX = 5
ATTENTION_STALE_DAYS = 7.0


def _parse(ts: str) -> datetime:
    value = datetime.fromisoformat(ts)
    return value if value.tzinfo else value.replace(tzinfo=timezone.utc)


def _now() -> datetime:
    return datetime.now(timezone.utc)


def _score(*, days_since_last: float | None, sessions_recent: int, has_open_goals: bool, avg_confidence: float) -> tuple[float, dict[str, float]]:
    recency = 0.0 if days_since_last is None else 0.5 ** (days_since_last / RECENCY_HALF_LIFE_DAYS)
    momentum = min(1.0, sessions_recent / MOMENTUM_SESSIONS_FOR_MAX)
    unfinished = 1.0 if has_open_goals else 0.0
    confidence = max(0.0, min(1.0, avg_confidence))
    factors = {
        "recency": round(recency, 3), "momentum": round(momentum, 3),
        "unfinished_work": round(unfinished, 3), "session_confidence": round(confidence, 3),
        "weights": {"recency": RECENCY_WEIGHT, "momentum": MOMENTUM_WEIGHT, "unfinished_work": UNFINISHED_WEIGHT, "session_confidence": CONFIDENCE_WEIGHT},
    }
    raw = RECENCY_WEIGHT * recency + MOMENTUM_WEIGHT * momentum + UNFINISHED_WEIGHT * unfinished + CONFIDENCE_WEIGHT * confidence
    return round(raw * 100, 1), factors


def _next_action(project_id: str, *, open_goals: list[Any], last_wrapup: Any, last_session: Any, next_step_hint: str | None) -> str:
    if open_goals:
        first = open_goals[0]["text"]
        return first if len(open_goals) == 1 else f"{first} (+{len(open_goals) - 1} more goal(s))"
    if last_wrapup is not None and str(last_wrapup["unfinished_notes"] or "").strip():
        text = str(last_wrapup["unfinished_notes"]).strip()
        return text if len(text) <= 140 else text[:137] + "..."
    if next_step_hint:
        return next_step_hint
    if last_session is not None:
        files = json.loads(last_session["files_json"] or "[]")
        # Name the last file that represents actual work. Without this filter
        # almost every project in a real portfolio reported "last touched
        # Project.betterproject" or ".DS_Store" -- metadata the Better
        # Projects app and Finder write on their own, which tells a person
        # nothing about where they left off.
        meaningful = [path for path in files if not _is_background_file(path)]
        if meaningful:
            return f"Resume: last touched {meaningful[-1].rsplit('/', 1)[-1]}"
        return "Resume where you left off"
    return "Not started yet"


def _is_background_file(path: str) -> bool:
    """Files written by tooling rather than by a person working.

    Deliberately the same judgement the scoring layer makes about session
    evidence (see `scoring/session_quality.py`), so the inspector and the
    measurements never disagree about what counted as work.
    """
    from .scoring.session_quality import NOISE_DIRECTORIES, NOISE_FILENAMES
    parts = PurePosixPath(path)
    return bool(set(parts.parts) & NOISE_DIRECTORIES) or parts.name in NOISE_FILENAMES


def effective_field(project: Any, field: str) -> str | None:
    """The value to browse and group by: a local edit if one was made,
    otherwise whatever the last Notion refresh mirrored.

    `<field>_local_set` is what makes "cleared locally" distinct from "never
    edited" -- without consulting it, deliberately emptying a domain would
    silently read back as Notion's value.
    """
    keys = project.keys()
    if f"{field}_local_set" in keys and project[f"{field}_local_set"]:
        return project[f"{field}_local"] or None
    return (project[field] or None) if field in keys else None


def field_source(project: Any, field: str) -> str:
    """Why the effective value is what it is, so the UI can show a local
    override as deliberate rather than looking like stale mirrored data."""
    keys = project.keys()
    if f"{field}_local_set" in keys and project[f"{field}_local_set"]:
        return "local"
    return "notion" if field in keys and project[field] else "unset"


def build_project_views(store: CoreStore, *, statuses: tuple[str, ...] = ("active",), now: datetime | None = None) -> list[dict[str, Any]]:
    """One pass over each supporting table, joined in Python (project counts
    are small -- real production data is in the low hundreds -- so this is
    simpler, more testable, and injection-proof compared to hand-building
    SQL per query shape). ``now`` is injectable so scoring is deterministic
    and testable against a fixed clock; production callers leave it as the
    real current time."""
    now = now or _now()
    projects = [row for row in store.projects(status=None) if statuses is None or row["status"] in statuses]
    tags_by_project: dict[str, list[dict[str, str]]] = {}
    mediums_by_project: dict[str, list[dict[str, str]]] = {}
    for row in store.all_project_tags():
        # One query supplies both lenses: `category='medium'` rows are the
        # By Medium facet, everything else is an ordinary freeform tag. Both
        # carry their tag id, so a client can remove either through the one
        # existing tag endpoint.
        bucket = mediums_by_project if row["category"] == "medium" else tags_by_project
        bucket.setdefault(row["project_id"], []).append({"id": row["id"], "display": row["display"]})
    open_goal_counts = store.open_goal_counts()
    current = store.get_state("project.current")
    current_project_id = current.get("project_id") if current else None
    open_session = store.open_session()

    views: list[dict[str, Any]] = []
    for project in projects:
        project_id = project["id"]
        recent_sessions = store.recent_sessions(project_id=project_id, limit=20)
        closed_sessions = [row for row in recent_sessions if row["status"] != "open"]
        last_session = closed_sessions[0] if closed_sessions else (recent_sessions[0] if recent_sessions else None)
        days_since_last = None
        if last_session is not None:
            days_since_last = (now - _parse(last_session["ended_at"])).total_seconds() / 86400.0
        sessions_recent = sum(
            1 for row in recent_sessions
            if (now - _parse(row["ended_at"])).total_seconds() / 86400.0 <= MOMENTUM_WINDOW_DAYS
        )
        confidences = [float(row["confidence"]) for row in closed_sessions[:3]]
        avg_confidence = sum(confidences) / len(confidences) if confidences else 0.0
        open_goals = list(store.project_goals(project_id, include_completed=False))
        score, factors = _score(
            days_since_last=days_since_last, sessions_recent=sessions_recent,
            has_open_goals=bool(open_goals), avg_confidence=avg_confidence,
        )
        last_wrapup = store.latest_wrapup_for_project(project_id)
        latest_draft = next(iter(store.work_log_drafts(project_id=project_id, limit=1)), None)
        next_step_hint = None
        if latest_draft is not None:
            payload = json.loads(latest_draft["payload_json"] or "{}")
            llm = payload.get("llm") or {}
            next_step_hint = llm.get("next_step")
        notion_row = store.notion_project_for(project_id)
        views.append({
            "id": project_id, "name": project["name"], "path": project["path"], "status": project["status"],
            "domain": effective_field(project, "domain"),
            "domain_source": field_source(project, "domain"),
            "status_label": effective_field(project, "status_label"),
            "status_label_source": field_source(project, "status_label"),
            "tags": tags_by_project.get(project_id, []),
            "mediums": sorted(mediums_by_project.get(project_id, []), key=lambda item: item["display"].casefold()),
            "notion_linked": notion_row is not None,
            "notion_project_id": notion_row["notion_project_id"] if notion_row else None,
            "score": score, "score_factors": factors,
            "last_session_at": last_session["ended_at"] if last_session is not None else None,
            "last_session_status": last_session["status"] if last_session is not None else None,
            "days_since_last_session": round(days_since_last, 2) if days_since_last is not None else None,
            "sessions_recent_14d": sessions_recent,
            "session_count": len(recent_sessions),
            "open_goals_count": len(open_goals),
            "needs_attention": bool(open_goals) and (days_since_last is None or days_since_last >= ATTENTION_STALE_DAYS),
            "is_current": project_id == current_project_id,
            "has_active_session": open_session is not None and open_session["project_id"] == project_id,
            "next_action": _next_action(project_id, open_goals=open_goals, last_wrapup=last_wrapup, last_session=last_session, next_step_hint=next_step_hint),
        })
    return views


def project_detail(
    store: CoreStore,
    project_id: str,
    *,
    now: datetime | None = None,
    workspace_root: Path | None = None,
) -> dict[str, Any] | None:
    """Everything needed to render the project inspector -- the full
    version of one row from `build_project_views`, plus the data that's too
    heavy to compute for every project in a list view (full goal list,
    recent sessions, recent work logs, recent relevant telemetry)."""
    views = build_project_views(store, statuses=None, now=now)
    view = next((v for v in views if v["id"] == project_id), None)
    if view is None:
        return None
    project = store.project_by_id(project_id)
    sessions = store.recent_sessions(project_id=project_id, limit=20)
    goals = store.project_goals(project_id, include_completed=True)
    wrapups = store.conn.execute(
        "SELECT * FROM session_wrapups WHERE project_id=? ORDER BY created_at DESC LIMIT 5", (project_id,)
    ).fetchall()
    work_logs = store.work_log_drafts(project_id=project_id, limit=10)
    absolute_path = None
    project_document_path = None
    if project is not None and workspace_root is not None:
        absolute_path = str((workspace_root / project["path"]).resolve())
        candidate = document_path(Path(absolute_path))
        if candidate.is_file():
            project_document_path = str(candidate)
    return {
        **view,
        "root_path": project["root_path"] if project else None,
        "absolute_path": absolute_path,
        "project_document_path": project_document_path,
        # The three ways out of the app and into the real project. Each is
        # None when genuinely unavailable so the UI can disable exactly the
        # action that cannot work, instead of offering a button that fails.
        "notion_url": notion_page_url(view.get("notion_project_id")),
        "discovered_at": project["discovered_at"] if project else None,
        "name_history": json.loads(project["name_history_json"] or "[]") if project else [],
        "goals": [dict(row) for row in goals],
        "sessions": [
            {"id": row["id"], "started_at": row["started_at"], "ended_at": row["ended_at"], "status": row["status"],
             "close_reason": row["close_reason"], "open_reason": row["open_reason"], "active_seconds": row["active_seconds"],
             "confidence": row["confidence"], "files": json.loads(row["files_json"] or "[]"),
             "commits": json.loads(row["commits_json"] or "[]") if "commits_json" in row.keys() else [],
             "git": json.loads(row["git_json"] or "{}")}
            for row in sessions
        ],
        "wrapups": [dict(row) for row in wrapups],
        "work_logs": [
            {"id": row["id"], "date_key": row["date_key"], "status": row["status"],
             "summary": json.loads(row["payload_json"] or "{}").get("summary"), "notion_page_id": row["notion_page_id"]}
            for row in work_logs
        ],
    }
