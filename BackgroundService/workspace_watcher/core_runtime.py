"""The operational v2 backend: sensor -> reconcile -> rules -> actions.

Raw watchdog details terminate at ``Settled``.  A settled callback asks the
idempotent reconciler for the small set of domain events that actually
changed, so a burst, dropped callback, or restart has the same meaning.
"""

from __future__ import annotations

from datetime import datetime, timedelta

import os
import signal
import threading
import time
from collections import Counter
from pathlib import Path
from typing import Any

from .actions_v2 import ActionDispatcher
from .coalescer import Coalescer, Settled
from .core_config import CoreConfig
from .core_engine import IntentIndexer, utc_now
from .core_events import EventTypes, WorkspaceEvent
from .core_store import CoreStore
from .delivery import MessageDeliveryService, NotificationDeliveryService
from .filesystem import FilesystemWatcher
from .hammerspoon_inbox import HammerspoonInbox
from .item_records import ITEM_FILENAME
from .ideas_v2 import ideas_notion_sync_enabled
from .session_automation import apply_classification
from .intents import INTENT_FILENAME, NEXT_CONFIG_NAMES, IntentFolderDetector
from .noise import NoiseFilter
from .notion_cache_v2 import NotionProjectCache
from .notion_ideas_v2 import IdeasNotionSync
from .projects_v2 import ProjectRef, ProjectRegistry
from .rules_v2 import RuleEvaluator, load_rules
from .resurfacing import ResurfacingService
from .scheduler import Scheduler
from .sessions_v2 import Session, Sessionizer
from .work_logs_v2 import WorkLogGenerator
from .widget_snapshot import WidgetSnapshotPublisher


from .project_graph_poll import ProjectGraphPoller

class CoreRuntime:
    """Long-lived single-writer v2 runtime used by ``workspace-watcher run``."""

    def __init__(self, config: CoreConfig) -> None:
        self.config = config
        self.project_graph_poller = ProjectGraphPoller()
        self.store = CoreStore(config.database_path)
        self.detector = IntentFolderDetector(config.intent_settings)
        self.indexer = IntentIndexer(self.detector, self.store)
        self.rules = ()
        self.evaluator = RuleEvaluator()
        self.dispatcher = ActionDispatcher(self.store)
        self.notifications = NotificationDeliveryService(self.store)
        self.messages = MessageDeliveryService(self.store)
        self.resurfacing = ResurfacingService(self.store, self.dispatcher, minimum_days=config.ideas.resurfacing_minimum_days, max_results=config.ideas.resurfacing_max_results)
        self.scheduler = Scheduler(self.store, self.resurfacing)
        self.hammerspoon_inbox = HammerspoonInbox(self.store, config.hammerspoon_inbox)
        self.projects = ProjectRegistry(self.store, config.workspace_root, config.projects.root, write_documents=config.projects.write_documents) if config.projects.enabled else None
        self.sessions = Sessionizer(self.store, config.sessions, config.workspace_root) if config.sessions.enabled else None
        # Always constructed (unlike `projects`/`sessions` above) -- both
        # gate their own behavior internally off `config.notion`/
        # `config.work_logs`, only checking `settings.enabled` inside their
        # own methods. That makes `notion_sync=False` (the default) a
        # property of what these objects *do*, not of whether they exist --
        # so `preview_pending()` keeps working for a dry run even when live
        # sync is off.
        self.notion_projects = NotionProjectCache(self.store, config.workspace_root, config.notion)
        self.work_logs = WorkLogGenerator(self.store, config.work_logs, config.notion, config.workspace_root, lm_settings=config.lm_studio)
        self.ideas_notion = IdeasNotionSync(self.store, config.workspace_root, config.notion)
        self.widgets = WidgetSnapshotPublisher(
            database_path=config.database_path,
            max_duration_minutes=config.sessions.max_duration_minutes,
        )
        self.noise = NoiseFilter(config.ignore_patterns, config.self_exclude_relpath)
        self._ignored_counts: Counter[str] = Counter()
        # A filesystem reconcile deferred because more events were queued
        # behind the one that asked for it (see `_on_settled`).
        self._reconcile_pending: str | None = None
        self._listed_cache: frozenset[str] | None = None
        self._widget_marker: tuple[int, int] | None = None
        self._widget_published_at = 0.0
        self._lock = threading.RLock()
        self._stop = threading.Event()
        self._stopped = threading.Event()
        self.coalescer = Coalescer(self._on_settled, debounce_seconds=config.debounce_seconds, on_error=self._on_settled_failed)
        self.sensor = FilesystemWatcher(config.workspace_root, self.coalescer, watch_roots=list(self.detector.settings.search_roots),
                                        self_exclude=config.self_exclude_relpath)

    def start(self) -> None:
        with self._lock:
            self.reload_rules()
            self.store.set_state("watcher.health", {"state": "starting", "watch_roots": [str(root) for root in self.detector.settings.search_roots]}, utc_now())
            # An unclean prior exit (crash, force-quit, `kill -9`) leaves a
            # session "open" in the database forever unless something closes
            # it -- do that before anything else touches sessions, exactly
            # mirroring the clean-shutdown path in `stop()` below, just with
            # a distinct reason so it's diagnosable which happened.
            self._close_all_sessions("recovered_after_restart")
            self._reconcile("startup")
            self.coalescer.start()
            self.sensor.start()
            self.store.set_state("watcher.health", {"state": "running", "watch_roots": [str(root) for root in self.detector.settings.search_roots]}, utc_now())
            self.publish_widget_snapshot()

    def run_forever(self) -> None:
        self.start()
        try:
            self.tick_loop()
        finally:
            self.stop()

    def tick_loop(self) -> None:
        """The periodic side of this runtime: Hammerspoon inbox ingestion,
        notification/message retry, and scheduled resurfacing. Filesystem
        sensing itself is independent of this loop (driven by the coalescer's
        own thread via `_on_settled`); ``cmd_run`` runs this in a background
        thread since its main thread blocks on the HTTP server instead."""
        while not self._stop.wait(1.0):
            self._tick_once()

    def _tick_once(self) -> None:
        with self._lock:
            # Every step below used to be able to take down the whole thread
            # forever on a single bad tick (observed in production: a
            # transient sqlite3.InterfaceError from publish_widget_snapshot's
            # per-project scan killed core-runtime-tick permanently, silently
            # disabling idle session close, Notion/work-log/ideas sync, and
            # notification delivery for the rest of the process's life, with
            # the HTTP server still up and `watcher.health` frozen on its
            # last good value -- indistinguishable from "fine" without
            # reading this log). One failing step must never stop the next
            # second's tick from still attempting everything.
            try:
                if not self.coalescer.has_queued_work():
                    self._run_pending_reconcile()
                self._ingest_hammerspoon()
                self._close_idle_session()
                self._classify_automated_sessions()
                self.project_graph_poller.tick()
                self._sync_notion_projects()
                self._sync_work_logs()
                self._enrich_work_logs()
                self._sync_ideas()
                self.notifications.tick()
                self.messages.tick()
                self.scheduler.tick(__import__("time").time())
                self._publish_widget_snapshot_if_stale()
                self._publish_noise_stats()
            except Exception as error:
                self.store.set_state("tick_loop.health", {"state": "error", "error": str(error)[:300]}, utc_now())
                return
            self.store.set_state("tick_loop.health", {"state": "ok"}, utc_now())

    def _publish_noise_stats(self) -> None:
        """Make "what is being ignored, and by which rule" inspectable.

        An ignore rule that silently matches too much is otherwise invisible:
        the activity it suppresses simply never appears. Cumulative per-rule
        counts let a bad pattern be spotted without re-reading a log file."""
        if not self._ignored_counts:
            return
        self.store.set_state(
            "noise.ignored_counts",
            {"total": sum(self._ignored_counts.values()), "by_rule": dict(self._ignored_counts.most_common(20))},
            utc_now(),
        )

    def request_stop(self) -> None:
        self._stop.set()

    def stop(self) -> None:
        self.project_graph_poller.stop()
        if self._stopped.is_set():
            return
        # Do not hold the SQLite lock while joining the coalescer: its final
        # flush may be waiting to acquire that same lock.
        self._stopped.set()
        self.sensor.stop()
        self.coalescer.stop()
        with self._lock:
            self._close_all_sessions("watcher_stopped")
            self.store.set_state("watcher.health", {"state": "stopped"}, utc_now())
            self.publish_widget_snapshot()
            self.store.close()

    def reload_rules(self) -> None:
        # Also reachable from an HTTP request thread, so it shares the
        # pipeline lock for the same reason `publish_widget_snapshot` does.
        with self._lock:
            try:
                self.rules = load_rules(self.config.rules_path)
                self.store.set_state("rules.health", {"state": "valid", "path": str(self.config.rules_path), "count": len(self.rules)}, utc_now())
            except ValueError as error:
                # Retain last-known-good rules; malformed configuration must not
                # take down filesystem sensing.
                self.store.set_state("rules.health", {"state": "invalid", "path": str(self.config.rules_path), "error": str(error), "active_count": len(self.rules)}, utc_now())

    def reconcile_now(self) -> dict[str, int]:
        with self._lock:
            return self._reconcile("manual")

    def create_project(self, name: str) -> dict[str, Any]:
        """Create a project-local document and its explicitly requested Notion page.

        The local directory/document is created first because it is the
        project source of truth. A transient Notion error therefore leaves a
        usable local project rather than silently discarding user work.
        """
        cleaned = name.strip()
        if not cleaned or cleaned in {".", ".."} or "/" in cleaned or "\\" in cleaned:
            raise ValueError("Project name must be a single, non-empty folder name.")
        if self.projects is None:
            raise ValueError("Project creation is disabled in this Workspace Watcher configuration.")
        with self._lock:
            directory = self.config.workspace_root / self.config.projects.root / cleaned
            if directory.exists():
                raise ValueError(f"A project directory already exists at {directory}.")
            directory.mkdir(parents=True)
            ref = self.projects.ensure_project(
                f"{self.config.projects.root.strip('/')}/{cleaned}", directory, utc_now()
            )
            notion_page_id = self.notion_projects.create_project(
                name=cleaned, local_directory=directory, now=utc_now()
            )
            # The refresh above has the new mapping; write it into the
            # already-created document immediately rather than waiting for a
            # later filesystem reconciliation pass.
            self.projects._ensure_document(directory, ref)
            self.publish_widget_snapshot()
            return {
                "project_id": ref.project_id,
                "name": ref.name,
                "project_directory": str(directory),
                "project_document": str(directory / "Project.betterproject") if self.projects.write_documents else None,
                "notion_project_id": notion_page_id,
            }

    def refresh_notion_projects(self) -> dict[str, Any]:
        """Refresh the Projects cache on an explicit user request.

        Periodic refresh remains deliberately rate-limited; this is the
        narrow action used after a project is created independently in Better
        Projects and should appear in Workspace Watcher immediately.
        """
        with self._lock:
            result = self.notion_projects.refresh(utc_now())
            if result.get("ok") and self.projects is not None:
                self.projects.rebuild()
            return result

    def end_current_session(self, reason: str = "user_ended") -> dict[str, Any] | None:
        """Explicit "wrap up now" from the GUI/menu bar/widget/App Intent --
        the same close path a project switch or inactivity timeout uses
        (`_close_all_sessions`), so Work Log preparation, event recording,
        and rule evaluation all happen identically regardless of what
        triggered the close. Returns the closed session's own record (via a
        fresh read, since `_close_all_sessions` doesn't hand one back), or
        None if nothing was open."""
        with self._lock:
            row = self.store.open_session()
            if row is None:
                return None
            session_id = row["id"]
            self._close_all_sessions(reason)
            closed = self.store.session_by_id(session_id)
            self.publish_widget_snapshot()
            return dict(closed) if closed is not None else None

    # How long the tick lets the snapshot's clock-derived fields (today's
    # totals, days since a project's last session) age when nothing changed.
    WIDGET_SNAPSHOT_MAX_AGE_SECONDS = 60.0

    def _publish_widget_snapshot_if_stale(self) -> None:
        """The tick's snapshot refresh, skipped while nothing it reads changed.

        Building the projection queries every project (~50 ms for 388 of
        them), and the tick used to do it every second -- the service's whole
        idle CPU once reconciles stopped. Its inputs are the database, written
        by this connection (`total_changes`) or another (`data_version`), and
        the clock, which no widget needs per second: the live timer counts
        from `started_at` on its own. Explicit publishes after a reconcile, a
        session close or an API action are unaffected.
        """
        marker = (self.store.conn.total_changes, self.store.conn.execute("PRAGMA data_version").fetchone()[0])
        now = time.monotonic()
        if marker == self._widget_marker and now - self._widget_published_at < self.WIDGET_SNAPSHOT_MAX_AGE_SECONDS:
            return
        self._widget_marker, self._widget_published_at = marker, now
        self.publish_widget_snapshot()

    def publish_widget_snapshot(self) -> bool:
        """Publish the widget projection without exposing SQLite to Swift.

        Takes the pipeline lock because the HTTP server calls this straight
        from a request thread. Without it, building the snapshot (a
        per-project scan -- hundreds of queries on this runtime's single
        shared connection) ran concurrently with the coalescer and the tick
        loop. `check_same_thread=False` disables Python's own guard, so that
        raised `sqlite3.InterfaceError: bad parameter or other API misuse`
        from whichever thread lost the race -- observed in production killing
        the coalescer thread outright, which silently ended all filesystem
        sensing while `watcher.health` still read "running".
        """
        with self._lock:
            return self.widgets.publish(self.store)

    def _ingest_hammerspoon(self) -> None:
        # A producer-side glitch (malformed config, a stalled file) must not
        # take down filesystem sensing -- same failure boundary as every
        # other downstream consumer in this runtime. Health is recorded the
        # same way `reload_rules` records `rules.health`, so a failure is
        # diagnosable without a log file.
        try:
            for event in self.hammerspoon_inbox.ingest():
                self._evaluate(event)
        except Exception as error:
            self.store.set_state("hammerspoon_inbox.health", {"state": "error", "error": str(error)}, utc_now())
        else:
            self.store.set_state("hammerspoon_inbox.health", {"state": "ok"}, utc_now())

    def _on_settled(self, settled: Settled) -> None:
        # A raw event need not be an item itself (metadata changes and intent
        # folder moves are common), so reconciliation is the one semantic
        # adapter instead of leaking filesystem-specific branches downstream.
        if self._stopped.is_set():
            return
        with self._lock:
            if self._stopped.is_set():
                return
            ref = self.projects.resolve_for_relpath(settled.path) if self.projects is not None else None
            if ref is not None and self._is_meaningful(settled):
                self._activate_project(ref)
                if self.sessions is not None:
                    for event in self.sessions.touch(ref, settled.path, settled.is_directory, utc_now()):
                        self.store.record_event(event)
                        self._evaluate(event)
            # Reconciliation is not gated by the noise filter: "what exists"
            # must remain accurate even for paths that are not activity.
            # Only activity conclusions -- which project is current, and what
            # counts as a work session -- are gated by it.
            #
            # It is, however, once per burst rather than once per event. A
            # reconcile costs seconds (the intent indexer walks the tree) on
            # this single consumer thread, while an idle workspace settles
            # several events a second; reconciling each one let the queue
            # grow without bound, so activation and sessions fell days
            # behind while health read "running". The last message of a
            # burst always reconciles, and the tick loop is the backstop.
            #
            # The watcher's own data directory never asks for one: every
            # reconcile writes core.db and the widget snapshot there, which
            # settled as new events and re-triggered reconcile forever.
            #
            # Nor does anything a reconcile cannot see (`_can_change_index`).
            # A reconcile walks the whole Workspace -- 45 seconds here, holding
            # the runtime lock -- and a Git client polling a project repo
            # touches `.git` every few seconds. Each of those started the next
            # walk, so one core stayed busy for good and the tick loop and API
            # threads queued behind the lock.
            if self._can_change_index(settled):
                self._reconcile_pending = f"filesystem:{settled.kind}"
            if self._reconcile_pending is not None and not self.coalescer.has_queued_work():
                self._run_pending_reconcile()

    def _is_self_generated(self, settled: Settled) -> bool:
        paths = [settled.path] + ([settled.prev_path] if settled.prev_path else [])
        return all(
            self.noise.classify(path).matched_rule == "self_exclude:watcher_data_dir"
            for path in paths
        )

    # The only files a reconcile reads: intent configuration, legacy item
    # metadata, and the markers that make a directory a Next.js project.
    _INDEX_FILENAMES = frozenset({INTENT_FILENAME, ITEM_FILENAME, "package.json"}) | NEXT_CONFIG_NAMES

    def _can_change_index(self, settled: Settled) -> bool:
        """Whether this change could alter what a reconcile finds.

        A reconcile records which directories are intent folders, the item
        directories directly inside them, and the top level of Projects. It
        never looks inside a pruned directory (`.git`, `node_modules`, ...),
        never reads an ordinary file, and a directory's own "modified" event
        only accompanies a create/delete/move of a child, which arrives as
        its own event. Anything else cannot change its result.
        """
        if self._is_self_generated(settled):
            return False
        paths = [settled.path] + ([settled.prev_path] if settled.prev_path else [])
        if not any(self._is_indexed_path(path) for path in paths):
            return False
        if settled.kind == "bulk_change":
            return True
        if settled.is_directory:
            return settled.kind != "modified"
        if self.detector.settings.follow_symlinks and settled.kind != "modified":
            return True  # a file event may be a symlink to a directory
        return any(path.rsplit("/", 1)[-1] in self._INDEX_FILENAMES for path in paths)

    def _is_indexed_path(self, relpath: str) -> bool:
        """False when `relpath` lies in a directory the reconcile never enters.

        A pruned name is still listed where the reconcile lists a directory's
        entries outright: an item folder called `build` in an intent folder,
        or a project called `dist` at the top of Projects.
        """
        parts = relpath.split("/")
        excluded = self.detector.settings.excluded_names
        for index, part in enumerate(parts):
            if part not in excluded:
                continue
            parent = "/".join(parts[:index])
            if index > 0 and (parent in self._listed_directories()):
                continue
            return False
        return True

    def _listed_directories(self) -> frozenset[str]:
        """Workspace-relative directories whose entries a reconcile lists."""
        if self._listed_cache is None:
            root = self.config.workspace_root.resolve()
            listed = {self.projects.prefix} if self.projects is not None else set()
            for path in [row["path"] for row in self.store.folders()] + [str(path) for path, _ in self.detector.settings.declared]:
                relative = os.path.relpath(path, root).replace(os.sep, "/")
                if not relative.startswith(".."):
                    listed.add(relative)
            self._listed_cache = frozenset(listed)
        return self._listed_cache

    def _run_pending_reconcile(self) -> None:
        reason, self._reconcile_pending = self._reconcile_pending, None
        if reason is not None:
            self._reconcile(reason)

    def _on_settled_failed(self, payload: Any, error: Exception) -> None:
        """Surface a dropped filesystem event where the app can see it.

        Sensing continues (see `Coalescer._run`), so without this the only
        trace of a failing consumer would be stderr -- and "nothing is being
        observed" is indistinguishable from "nothing is happening" to every
        other surface. Writing through a short-lived connection of its own
        avoids reusing the very connection that may have just failed.
        """
        try:
            with CoreStore(self.config.database_path) as store:
                store.set_state("sensing.health", {
                    "state": "degraded",
                    "dropped_events": self.coalescer.dropped_events,
                    "last_error": self.coalescer.last_error,
                    "last_path": getattr(payload, "src_path", None) or getattr(payload, "path", None),
                }, utc_now())
        except Exception:
            pass  # reporting a drop must never itself stop sensing

    def _is_meaningful(self, settled: Settled) -> bool:
        """Whether a settled event may drive activity conclusions.

        Restores the v1 sensing contract that the v2 cutover dropped. Without
        it, generated and background writes (`.DS_Store` from a Finder
        browse, a dev server's `.sites-runtime` registry, `.git` bookkeeping)
        were indistinguishable from real editing: they accrued observed
        session hours and, because any touch re-activates its project, a
        single background writer repeatedly stole "active project" from
        whatever was genuinely being worked on.
        """
        # A directory's own mtime bump is implied by the child event that
        # caused it, so counting it again is double-counting one change.
        # `bulk_change` is exempt: it is a real summary of many child writes
        # that were deliberately collapsed into one directory-shaped event.
        if settled.is_directory and settled.kind == "modified":
            self._ignored_counts["directory_modified_redundant"] += 1
            return False
        verdict = self.noise.classify(settled.path)
        if verdict.ignored:
            self._ignored_counts[verdict.matched_rule or "unknown"] += 1
            return False
        return True

    def _activate_project(self, ref: ProjectRef) -> None:
        # "What exists?" is a full-tree reconciliation question (handled in
        # _reconcile via ProjectRegistry.rebuild()). "What is active right
        # now?" needs the one path that actually just changed -- only
        # available in _on_settled, before _reconcile's global re-walk
        # discards it.
        current = self.store.get_state("project.current")
        same_project = current is not None and current.get("project_id") == ref.project_id
        if same_project and current.get("name") == ref.name and current.get("path") == ref.path:
            return
        now = utc_now()
        self.store.set_state("project.current", {"project_id": ref.project_id, "name": ref.name, "path": ref.path, "activated_at": now}, now)
        if same_project:
            # Same project, but its name/path changed since it became
            # current (e.g. renamed while it stayed the active one, with no
            # intervening switch away and back) -- refresh the cached state
            # so diagnostics/status never show a stale name, but this is not
            # a new activation, so no event fires for it.
            return
        event = WorkspaceEvent(type=EventTypes.PROJECT_ACTIVATED, entity_id=ref.project_id, payload={"name": ref.name, "path": ref.path}, source="filesystem")
        if self.store.record_event(event):
            self._evaluate(event)

    def _close_idle_session(self) -> None:
        if self.sessions is None:
            return
        for event in self.sessions.close_expired(utc_now()):
            self.store.record_event(event)
            self._evaluate(event)

    def _classify_automated_sessions(self) -> None:
        """Once a minute, judge sessions from the last six hours whose activations have
        settled (each burst's whole window has passed). Bulk filesystem runs are marked,
        never deleted -- see session_automation.py."""
        if self.sessions is None:
            return
        now = datetime.now().astimezone()
        last = getattr(self, "_automation_checked_at", None)
        if last is not None and (now - last).total_seconds() < 60:
            return
        self._automation_checked_at = now
        try:
            report = apply_classification(self.store, since=(now - timedelta(hours=6)).isoformat(),
                                          settled_before=(now - timedelta(seconds=180)).isoformat(), apply=True)
        except Exception as error:  # never let classification stop sensing
            self.store.set_state("sessions.automation", {"state": "error", "error": str(error)[:300]}, utc_now())
            return
        if report["automated_sessions"]:
            previous = self.store.get_state("sessions.automation") or {}
            total = int(previous.get("automated_sessions_total") or 0) + report["automated_sessions"]
            self.store.set_state("sessions.automation", {"state": "ok", "last": report, "automated_sessions_total": total}, utc_now())

    def _close_all_sessions(self, reason: str) -> None:
        if self.sessions is None:
            return
        for event in self.sessions.close_all(utc_now(), reason):
            self.store.record_event(event)
            self._evaluate(event)

    def _prepare_work_log(self, session_id: str) -> None:
        row = self.store.session_by_id(session_id)
        if row is None:
            return
        self.work_logs.prepare(Session.from_row(row))

    def _sync_notion_projects(self) -> None:
        # A producer-side glitch (bad token, unreachable Notion, moved
        # sibling project) must not take down filesystem sensing or session
        # inference -- same failure boundary as every other downstream
        # consumer in this runtime. `refresh()` itself already catches the
        # expected failure mode (NotionCacheError) and returns {"ok": False,
        # ...} rather than raising; this also guards against an unexpected
        # one.
        try:
            result = self.notion_projects.refresh_if_due(utc_now())
            if result is None or result.get("ok", True):
                self.store.set_state("notion_projects.health", {"state": "ok"}, utc_now())
            else:
                self.store.set_state("notion_projects.health", {"state": "error", "error": str(result.get("error"))[:300]}, utc_now())
        except Exception as error:
            self.store.set_state("notion_projects.health", {"state": "error", "error": str(error)[:300]}, utc_now())

    def _sync_work_logs(self) -> None:
        if (self.store.get_state("project_graph.writer") or {}).get("owner") == "better-workspace":
            return
        try:
            results = self.work_logs.sync_pending()
            self.store.set_state("work_logs.health", {"state": "ok", "synced": sum(1 for r in results if r["status"] == "synced")}, utc_now())
        except Exception as error:
            self.store.set_state("work_logs.health", {"state": "error", "error": str(error)[:300]}, utc_now())

    def _ideas_folder_path(self) -> Path | None:
        row = next((row for row in self.store.folders() if row["name"].casefold() == "ideas"), None)
        return Path(row["path"]) if row else None

    def sync_ideas_now(self) -> dict[str, Any]:
        """Explicit, on-demand push+pull -- the same underlying calls the
        tick loop makes periodically, exposed for a "Sync Now" button so a
        person doesn't have to wait for the next tick to see the result."""
        with self._lock:
            return self._sync_ideas(explicit=True)

    def _sync_ideas(self, *, explicit: bool = False) -> dict[str, Any]:
        if (self.store.get_state("project_graph.writer") or {}).get("owner") == "better-workspace":
            if explicit:
                raise ValueError("Use Better Workspace's reviewed Send to Notion; the project graph owns Notion writes.")
            return {"skipped": True, "reason": "project graph owns Notion writes"}
        if not (ideas_notion_sync_enabled(self.store, self.config.ideas.notion_sync) and self.config.notion.enabled):
            if explicit:
                raise ValueError("Idea Notion sync is disabled (see Settings, or [workspace_watcher.ideas].notion_sync / [workspace_watcher.notion].enabled in config.toml).")
            return {"skipped": True}
        # After the configured Ideas database vanished, retry rarely rather than on
        # every pass; an explicit sync (or toggling sync in the app) tries at once.
        paused_until = (self.store.get_state("ideas_notion.paused_until") or {}).get("until")
        if paused_until and not explicit and utc_now() < paused_until:
            return {"skipped": True, "reason": "Notion Ideas database missing; retrying later"}
        folder_path = self._ideas_folder_path()
        if folder_path is None:
            return {"skipped": True, "reason": "no [[Ideas]] folder discovered yet"}
        results: list[dict[str, Any]] = []
        errors = 0
        try:
            now = utc_now()
            folder_row = next(row for row in self.store.folders() if row["name"].casefold() == "ideas")
            for item in self.store.items(folder_id=folder_row["id"]):
                outcome = self.ideas_notion.sync_item(item, Path(item["path"]), now)
                results.append(outcome)
                if outcome.get("action") == "error":
                    errors += 1
            results.extend(self.ideas_notion.pull_new_ideas(folder_path, now))
            self.store.set_state("ideas_notion.health", {"state": "ok" if not errors else "error", "synced": len(results), "errors": errors}, now)
        except Exception as error:
            errors += 1
            now = utc_now()
            if _database_is_gone(error):
                # Local ideas are untouched; only the mirror stops, loudly but rarely.
                until = (datetime.fromisoformat(now) + timedelta(hours=IDEAS_SYNC_MISSING_DATABASE_BACKOFF_HOURS)).isoformat()
                self.store.set_state("ideas_notion.health", {"state": "database_missing", "error": str(error)[:300]}, now)
                self.store.set_state("ideas_notion.paused_until", {"until": until}, now)
            else:
                self.store.set_state("ideas_notion.health", {"state": "error", "error": str(error)[:300]}, now)
            if explicit:
                raise
        if errors == 0 and paused_until:
            self.store.set_state("ideas_notion.paused_until", {"until": None}, utc_now())
        return {"results": results, "errors": errors}

    def _enrich_work_logs(self) -> None:
        # A slow or unreachable LM Studio must never delay filesystem
        # sensing, session inference, or Notion sync -- same failure
        # boundary as everything else on this loop. `enrich_pending` itself
        # already never raises per-pass, so this try/except only guards
        # against something unexpected in the surrounding bookkeeping.
        try:
            results = self.work_logs.enrich_pending()
            self.store.set_state("lm_studio.health", {"state": "ok", "enriched": len(results)}, utc_now())
        except Exception as error:
            self.store.set_state("lm_studio.health", {"state": "error", "error": str(error)[:300]}, utc_now())

    def _reconcile(self, reason: str) -> dict[str, int]:
        before = {row["id"] for row in self.store.recent_events(1000)}
        summary = self.indexer.rebuild(initialize_missing_metadata=True)
        if self.projects is not None:
            summary.update({f"projects_{key}": value for key, value in self.projects.rebuild().items()})
        for row in reversed(self.store.recent_events(1000)):
            if row["id"] in before:
                continue
            event = WorkspaceEvent(
                id=row["id"], schema_version=row["schema_version"], type=row["type"], entity_id=row["entity_id"], source=row["source"], occurred_at=row["occurred_at"],
                payload=__import__("json").loads(row["payload_json"]), causation_id=row["causation_id"], correlation_id=row["correlation_id"],
            )
            self._evaluate(event)
        self._listed_cache = None
        self.store.set_state("watcher.last_reconcile", {"reason": reason, "summary": summary}, utc_now())
        self.publish_widget_snapshot()
        return summary

    def _evaluate(self, event: WorkspaceEvent) -> None:
        # A single hook, regardless of which of the three call sites
        # (_on_settled's switch-close, the idle tick, start/stop's
        # close_all) produced this session.closed -- every one of them
        # already funnels through here.
        if event.type == EventTypes.SESSION_CLOSED and event.payload.get("status") == "completed":
            self._prepare_work_log(event.entity_id)
        item = self.store.item_by_id(event.entity_id) if event.entity_id else None
        context: dict[str, object] = {"event": event.type}
        if item:
            folder = next((row for row in self.store.folders() if row["id"] == item["intent_folder_id"]), None)
            context.update({"intent": folder["name"] if folder else None, "status": item["status"], "item_id": item["id"]})
            context["tags"] = __import__("json").loads(item["metadata_json"]).get("tags", [])
        for rule in self.rules:
            if not rule.enabled:
                continue
            explanation = self.evaluator.evaluate_and_record(self.store, rule, event, context)
            if explanation.passed:
                for action in rule.actions:
                    configured = dict(action)
                    configured["rule_id"] = rule.id
                    try:
                        self.dispatcher.dispatch(configured, event)
                    except Exception:
                        # The durable result is recorded by ActionDispatcher;
                        # a delivery/configuration fault cannot stop sensing.
                        continue


def run(config: CoreConfig) -> int:
    runtime = CoreRuntime(config)
    signal.signal(signal.SIGTERM, lambda *_: runtime.request_stop())
    signal.signal(signal.SIGINT, lambda *_: runtime.request_stop())
    runtime.run_forever()
    return 0


IDEAS_SYNC_MISSING_DATABASE_BACKOFF_HOURS = 6


def _database_is_gone(error: Exception) -> bool:
    """The configured Ideas database (not one page) no longer resolves: deleted,
    or no longer shared with the integration. Notion answers 404 for both."""
    text = str(error)
    return "HTTP 404" in text or "Could not find database" in text or "object_not_found" in text
