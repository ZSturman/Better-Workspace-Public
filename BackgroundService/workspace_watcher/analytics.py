"""Explainable context-switch and Notion-priority analyses."""

from __future__ import annotations

import json
from collections import Counter
from dataclasses import dataclass
from typing import Any

from .config import FragmentationSettings, PrioritySettings
from .store import WorkspaceStore


@dataclass(frozen=True)
class FragmentationResult:
    evaluated_at: float
    window_started_at: float
    window_minutes: float
    project_count: int
    switch_count: int
    recurring_project_count: int
    short_stint_count: int
    stints: list[dict[str, Any]]

    def to_dict(self) -> dict[str, Any]:
        return {
            "evaluated_at": self.evaluated_at, "window_started_at": self.window_started_at,
            "window_minutes": self.window_minutes, "project_count": self.project_count,
            "switch_count": self.switch_count, "recurring_project_count": self.recurring_project_count,
            "short_stint_count": self.short_stint_count, "stints": self.stints,
        }


class FragmentationAnalyzer:
    def __init__(self, store: WorkspaceStore, settings: FragmentationSettings) -> None:
        self.store = store
        self.settings = settings

    def evaluate(self, now: float, *, persist: bool = False) -> FragmentationResult:
        start = now - self.settings.window_minutes * 60
        rows = self.store.events_between(start, now, meaningful_only=True)
        stints: list[dict[str, Any]] = []
        for row in rows:
            project_id = row["project_id"]
            if not project_id:
                continue
            if stints and stints[-1]["project_id"] == project_id:
                stints[-1]["ended_at"] = row["ts"]
                stints[-1]["event_count"] += 1
                continue
            stints.append({
                "project_id": project_id, "project_name": row["project_name"] or project_id,
                "started_at": row["ts"], "ended_at": row["ts"], "event_count": 1,
            })
        visits = Counter(stint["project_id"] for stint in stints)
        short_seconds = self.settings.short_stint_minutes * 60
        result = FragmentationResult(
            evaluated_at=now, window_started_at=start, window_minutes=self.settings.window_minutes,
            project_count=len(visits), switch_count=max(0, len(stints) - 1),
            recurring_project_count=sum(1 for count in visits.values() if count > 1),
            short_stint_count=sum(1 for stint in stints if stint["ended_at"] - stint["started_at"] <= short_seconds),
            stints=stints,
        )
        if persist:
            self.store.insert_fragmentation_metric({
                **result.to_dict(), "details": {"stints": stints, "visits_by_project": dict(visits)},
            })
        return result


@dataclass(frozen=True)
class PriorityAlignmentResult:
    evaluated_at: float
    window_started_at: float
    ranked_projects: list[dict[str, Any]]
    activity_by_project: list[dict[str, Any]]
    ignored_high_priority: list[dict[str, Any]]
    stale_current_work: list[dict[str, Any]]
    dominant_low_priority: dict[str, Any] | None
    aligned: bool | None

    def to_dict(self) -> dict[str, Any]:
        return {
            "evaluated_at": self.evaluated_at, "window_started_at": self.window_started_at,
            "ranked_projects": self.ranked_projects, "activity_by_project": self.activity_by_project,
            "ignored_high_priority": self.ignored_high_priority,
            "stale_current_work": self.stale_current_work,
            "dominant_low_priority": self.dominant_low_priority, "aligned": self.aligned,
        }


class PriorityAnalyzer:
    def __init__(self, store: WorkspaceStore, settings: PrioritySettings) -> None:
        self.store = store
        self.settings = settings

    def evaluate(self, now: float, *, persist: bool = False) -> PriorityAlignmentResult:
        start = now - self.settings.analysis_window_hours * 3600
        cached = [row for row in self.store.cached_notion_projects() if row["local_project_id"]]
        ranked = [
            {
                "notion_project_id": row["notion_project_id"], "project_id": row["local_project_id"],
                "project_name": row["name"], "priority": float(row["priority"] or 0), "status": row["status"],
                "current_work": json.loads(row["current_work_json"] or "[]"),
                "next_work": json.loads(row["next_work_json"] or "[]"),
            }
            for row in cached if row["priority"] is not None and float(row["priority"] or 0) > 0
        ]
        ranked.sort(key=lambda item: (-item["priority"], item["project_name"].casefold()))
        counts: Counter[str] = Counter(row["project_id"] for row in self.store.events_between(start, now) if row["project_id"])
        names = {row["project_id"]: row["project_name"] for row in self.store.events_between(start, now) if row["project_id"]}
        priority_by_id = {item["project_id"]: item["priority"] for item in ranked}
        activity = [
            {"project_id": project_id, "project_name": names.get(project_id, project_id), "event_count": count,
             "priority": priority_by_id.get(project_id)}
            for project_id, count in counts.most_common()
        ]
        top = ranked[:self.settings.top_project_count]
        ignored = [item for item in top if counts.get(item["project_id"], 0) == 0]
        # This is deliberately a fact, not a nudge.  A Notion Current Work
        # tag can be intentionally stale, so it is useful review context but
        # insufficient evidence to interrupt someone.
        stale_current_work = [item for item in ranked if item["current_work"] and counts.get(item["project_id"], 0) == 0]
        total = sum(counts.values())
        dominant = activity[0] if activity and total else None
        max_priority = ranked[0]["priority"] if ranked else 0.0
        dominant_low: dict[str, Any] | None = None
        if dominant and max_priority > 0:
            fraction = dominant["event_count"] / total
            priority = dominant.get("priority") or 0.0
            if fraction >= self.settings.dominant_activity_ratio and priority <= max_priority * self.settings.low_priority_ratio:
                dominant_low = {**dominant, "activity_ratio": round(fraction, 3), "highest_priority": max_priority}
        aligned: bool | None
        if not ranked or not dominant:
            aligned = None
        else:
            # Being one of a tiny set of ranked projects is not automatically
            # alignment when its score is materially lower than the leader.
            aligned = dominant_low is None and dominant["project_id"] in {item["project_id"] for item in top}
        result = PriorityAlignmentResult(now, start, ranked, activity, ignored, stale_current_work, dominant_low, aligned)
        if persist:
            self.store.insert_priority_alignment_snapshot(now, start, result.to_dict())
        return result
