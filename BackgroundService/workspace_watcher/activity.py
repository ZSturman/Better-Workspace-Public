"""Simple activity inference.

Deliberately minimal, per the design brief: "do not over-engineer activity
inference... a simple initial implementation is fine." This gives future,
richer inference something concrete to replace rather than trying to
anticipate it.

Current rule for "active project": the project with the most recent
meaningful event, provided that event happened within
`active_project_recency_minutes` AND the project has accumulated at least
`active_project_min_events` meaningful events within the trailing
`active_project_window_minutes`. Both thresholds exist so a single stray
touch (e.g. opening a file to read it) doesn't flip the active project.
"""

from __future__ import annotations

import time
from dataclasses import dataclass
from typing import Optional

from .config import WatcherSettings
from .events import EventType, NormalizedEvent
from .store import WorkspaceStore

STATE_KEY_ACTIVE_PROJECT = "active_project"


@dataclass
class ActiveProjectState:
    project_id: str
    project_name: str
    since: float


class ActivityTracker:
    def __init__(self, store: WorkspaceStore, settings: WatcherSettings):
        self.store = store
        self.settings = settings

    def after_project_event(self, event: NormalizedEvent) -> Optional[NormalizedEvent]:
        """Call after persisting a meaningful event that belongs to a project.
        Returns a synthetic `project_active_changed` event if the active
        project changed as a result, otherwise None."""
        if not (event.meaningful and event.project_id):
            return None

        self.store.record_project_activity(event.project_id, event.ts)
        return self._recompute_active_project(time.time())

    def _recompute_active_project(self, now: float) -> Optional[NormalizedEvent]:
        window_start = now - self.settings.active_project_window_minutes * 60
        recency_cutoff = now - self.settings.active_project_recency_minutes * 60

        candidate = None
        for row in self.store.all_projects(status="active"):
            last_activity = row["last_activity_at"]
            if last_activity is None or last_activity < recency_cutoff:
                continue
            count = self.store.count_events_since(row["project_id"], window_start)
            if count < self.settings.active_project_min_events:
                continue
            if candidate is None or last_activity > candidate["last_activity_at"]:
                candidate = row

        previous = self.store.get_state(STATE_KEY_ACTIVE_PROJECT)
        new_project_id = candidate["project_id"] if candidate else None

        if previous and previous.get("project_id") == new_project_id:
            return None  # no change
        if previous is None and new_project_id is None:
            return None

        if new_project_id is None:
            self.store.set_state(STATE_KEY_ACTIVE_PROJECT, None)
        else:
            self.store.set_state(
                STATE_KEY_ACTIVE_PROJECT,
                {"project_id": candidate["project_id"], "project_name": candidate["name"], "since": now},
            )

        return NormalizedEvent(
            type=EventType.PROJECT_ACTIVE_CHANGED,
            path=candidate["path"] if candidate else "",
            is_directory=True,
            area="Projects",
            area_kind="system",
            meaningful=True,
            project_id=new_project_id,
            project_name=candidate["name"] if candidate else None,
            matched_rule=None,
            metadata={
                "from_project_id": previous.get("project_id") if previous else None,
                "from_project_name": previous.get("project_name") if previous else None,
                "to_project_id": new_project_id,
                "to_project_name": candidate["name"] if candidate else None,
            },
            ts=now,
        )

    def active_project(self) -> Optional[ActiveProjectState]:
        state = self.store.get_state(STATE_KEY_ACTIVE_PROJECT)
        if not state:
            return None
        return ActiveProjectState(state["project_id"], state["project_name"], state["since"])

    def tick(self, now: float | None = None) -> Optional[NormalizedEvent]:
        """Expire an active project without waiting for another file save."""
        return self._recompute_active_project(time.time() if now is None else now)
