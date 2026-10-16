"""Separating automated, bulk filesystem operations from work on a project.

The sessionizer sees one settled filesystem batch at a time and keeps one open
session, so a tool that writes into hundreds of projects within seconds (a
workspace audit, icon generation, batch audio processing) opens or resumes a
session in every one of them. Each looks like a short visit; repeated passes
resume those sessions until they pass the legitimacy thresholds, and every
project then reads as "recently worked on".

The distinguishing evidence is cross-project. A person moves between a few
projects in a couple of minutes; automation activates many. A session is
classified as automated only when *every* one of its activations (start or
resume, from the event journal) fell inside such a fan-out window **and** it
never showed sustained activity of its own (its longest uninterrupted burst
stayed short). Focused work that merely overlapped a bulk run keeps its status.

Classification never deletes anything. A flagged session becomes ``discarded``
(a status every consumer already ignores), with the reason and its previous
status recorded in ``evidence_json["automation"]`` so it can be reversed.
Work-log drafts are recomputed without those sessions; a draft left with no
real sessions becomes ``automated`` and keeps its Notion page id untouched.
"""

from __future__ import annotations

import bisect
import json
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from typing import Any, Iterable

ACTIVATION_EVENTS = ("session.started", "session.resumed")
AUTOMATED_DRAFT_STATUS = "automated"


@dataclass(frozen=True)
class AutomationRule:
    # Distinct projects activated within +/- window_seconds of an activation.
    min_projects: int = 6
    window_seconds: float = 120.0
    # Longer than this uninterrupted, a session shows its own sustained work.
    max_sustained_seconds: float = 120.0


@dataclass(frozen=True)
class Activation:
    at: datetime
    project_id: str
    session_id: str


def _parse(value: str) -> datetime:
    parsed = datetime.fromisoformat(value)
    return parsed if parsed.tzinfo else parsed.replace(tzinfo=timezone.utc)


def fan_out(activations: list[Activation], rule: AutomationRule) -> list[int]:
    """For each activation (sorted by time), how many distinct projects were
    activated within the rule's window around it."""
    times = [item.at for item in activations]
    window = timedelta(seconds=rule.window_seconds)
    result = []
    for item in activations:
        lo = bisect.bisect_left(times, item.at - window)
        hi = bisect.bisect_right(times, item.at + window)
        result.append(len({activations[index].project_id for index in range(lo, hi)}))
    return result


def classify(activations: Iterable[Activation], sessions: Iterable[dict[str, Any]], rule: AutomationRule = AutomationRule()) -> dict[str, dict[str, Any]]:
    """Session id -> automation evidence, for completed sessions that are automated."""
    ordered = sorted(activations, key=lambda item: item.at)
    counts = fan_out(ordered, rule)
    per_session: dict[str, list[int]] = {}
    for item, count in zip(ordered, counts):
        per_session.setdefault(item.session_id, []).append(count)
    result: dict[str, dict[str, Any]] = {}
    for session in sessions:
        fans = per_session.get(session["id"])
        if not fans or session.get("status") != "completed":
            continue
        if min(fans) < rule.min_projects:
            continue  # at least one activation looked like a person choosing this project
        if float(session.get("longest_burst_seconds") or 0) >= rule.max_sustained_seconds:
            continue  # sustained activity of its own, even if it began during a bulk run
        result[session["id"]] = {
            "reason": "bulk_filesystem_fanout",
            "activations": len(fans),
            "min_projects_in_window": min(fans),
            "max_projects_in_window": max(fans),
            "window_seconds": rule.window_seconds,
            "longest_burst_seconds": round(float(session.get("longest_burst_seconds") or 0), 1),
        }
    return result


def load_activations(conn: Any, *, since: str | None, session_ids: Iterable[str] | None = None) -> list[Activation]:
    query = f"SELECT occurred_at, entity_id, payload_json FROM event_journal WHERE type IN ({','.join('?' * len(ACTIVATION_EVENTS))})"
    params: list[Any] = list(ACTIVATION_EVENTS)
    if since is not None:
        query += " AND occurred_at >= ?"
        params.append(since)
    if session_ids is not None:
        ids = sorted(set(session_ids))
        if not ids:
            return []
        query += f" AND entity_id IN ({','.join('?' * len(ids))})"
        params.extend(ids)
    result = []
    for row in conn.execute(query + " ORDER BY occurred_at", params):
        try:
            payload = json.loads(row[2] or "{}")
            result.append(Activation(_parse(row[0]), str(payload["project_id"]), str(row[1])))
        except (KeyError, TypeError, ValueError):
            continue
    return result


def apply_classification(store: Any, *, since: str | None = None, settled_before: str | None = None,
                         rule: AutomationRule = AutomationRule(), apply: bool = False, now: str | None = None) -> dict[str, Any]:
    """Classifies completed sessions whose activations fall after ``since``.

    Only activations older than ``settled_before`` decide anything, so a burst
    still in progress is never judged on half its window. With ``apply=False``
    nothing is written and the report says what would change.
    """
    now = now or datetime.now(timezone.utc).isoformat()
    conn = store.conn
    window = timedelta(seconds=rule.window_seconds)
    cutoff = _parse(settled_before) if settled_before else None
    recent = load_activations(conn, since=since)
    candidates = {item.session_id for item in recent}
    # Every activation of each candidate decides its verdict, including ones before `since`.
    own = load_activations(conn, since=None, session_ids=candidates) if since else recent
    # A session with an activation newer than the cutoff is still settling; judge it later.
    if cutoff is not None:
        unsettled = {item.session_id for item in own if item.at > cutoff}
        candidates -= unsettled
        own = [item for item in own if item.session_id in candidates]
    if not candidates:
        return {"apply": apply, "examined_sessions": 0, "automated_sessions": 0, "observed_hours": 0.0, "drafts_updated": 0, "drafts_automated": 0, "days": {}}
    earliest = min(item.at for item in own) - window
    context = [item for item in load_activations(conn, since=earliest.isoformat()) if cutoff is None or item.at <= cutoff + window]
    rows = [dict(row) for row in conn.execute(
        f"SELECT * FROM sessions WHERE id IN ({','.join('?' * len(candidates))})", sorted(candidates))]
    automated = classify(context, rows, rule)
    by_id = {row["id"]: row for row in rows}
    days: dict[str, int] = {}
    for session_id in automated:
        day = by_id[session_id]["started_at"][:10]
        days[day] = days.get(day, 0) + 1
    report: dict[str, Any] = {
        "apply": apply, "examined_sessions": len(rows), "automated_sessions": len(automated),
        "observed_hours": round(sum(float(by_id[s]["active_seconds"] or 0) for s in automated) / 3600, 1),
        "drafts_updated": 0, "drafts_automated": 0, "days": dict(sorted(days.items())),
    }
    if not apply or not automated:
        return report
    for session_id, evidence in automated.items():
        row = by_id[session_id]
        stored = json.loads(row.get("evidence_json") or "{}")
        stored["automation"] = dict(evidence, previous_status=row["status"], classified_at=now)
        conn.execute("UPDATE sessions SET status='discarded', evidence_json=?, updated_at=? WHERE id=? AND status='completed'",
                     (json.dumps(stored, sort_keys=True), now, session_id))
    updated, emptied = _recompute_drafts(store, set(automated), now)
    conn.commit()
    report["drafts_updated"], report["drafts_automated"] = updated, emptied
    return report


def _recompute_drafts(store: Any, automated: set[str], now: str) -> tuple[int, int]:
    from .work_logs_v2 import WorkLogGenerator

    updated = emptied = 0
    for row in store.conn.execute("SELECT * FROM work_log_drafts").fetchall():
        session_ids = json.loads(row["session_ids_json"] or "[]")
        if not automated.intersection(session_ids):
            continue
        payload = json.loads(row["payload_json"] or "{}")
        remaining_ids = [item for item in session_ids if item not in automated]
        components = [item for item in payload.get("sessions") or [] if item.get("session_id") not in automated]
        removed = payload.setdefault("automation", {}).setdefault("excluded_session_ids", [])
        removed.extend(item for item in session_ids if item in automated and item not in removed)
        if components:
            combined = WorkLogGenerator.combined_payload(row["project_id"], row["project_name"], payload.get("date") or row["date_key"], components)
            for key in ("llm",):
                if key in payload:
                    combined[key] = payload[key]
            combined["automation"] = payload["automation"]
            status = row["status"]
            updated += 1
        else:
            # Kept for recovery and for its Notion page; no longer reported as work.
            combined = payload
            combined["automation"]["previous_status"] = row["status"]
            status = AUTOMATED_DRAFT_STATUS
            emptied += 1
        store.conn.execute("UPDATE work_log_drafts SET session_ids_json=?, payload_json=?, status=?, updated_at=? WHERE id=?",
                           (json.dumps(remaining_ids if components else session_ids, sort_keys=True), json.dumps(combined, sort_keys=True), status, now, row["id"]))
    return updated, emptied
