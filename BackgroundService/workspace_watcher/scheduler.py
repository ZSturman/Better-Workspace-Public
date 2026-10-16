"""Low-overhead deterministic time triggers for the local runtime."""

from __future__ import annotations

from datetime import datetime, timezone
import time

from .core_events import WorkspaceEvent
from .core_store import CoreStore
from .resurfacing import ResurfacingService


class Scheduler:
    def __init__(self, store: CoreStore, resurfacing: ResurfacingService, *, interval_seconds: int = 60) -> None:
        self.store, self.resurfacing, self.interval_seconds, self._last = store, resurfacing, interval_seconds, time.time()

    def tick(self, now: float) -> dict[str, int]:
        if now - self._last < self.interval_seconds: return {"ran": 0}
        self._last = now
        stamp = datetime.fromtimestamp(now, timezone.utc).isoformat()
        self.store.record_event(WorkspaceEvent(type="schedule.tick", payload={"at": stamp}, source="scheduler"))
        active_project = (self.store.get_state("project.current") or {}).get("project_id")
        results = self.resurfacing.run(stamp, active_project=active_project)
        return {"ran": 1, "resurfaced": sum(item["eligible"] for item in results)}
