"""Lightweight native menu bar UI.

Deliberately thin: this module reads the watcher's SQLite database
read-only (never runs alongside the watcher's own write connection in the
same process) and shells out to ``python -m workspace_watcher ...`` for
every mutation -- Open, Useful, Not Related, Defer, Archive. The CLI is the
single place those actions are implemented; the menu bar is presentation
only, and can be killed/restarted independently of both the watcher daemon
and the CLI.

``rumps`` (a small PyObjC wrapper purpose-built for exactly this kind of
status-bar app) is an optional dependency -- only imported inside
``run_menubar_app``, so ``build_status`` can be unit-tested without it
installed, and the rest of Workspace Watcher never requires it.
"""

from __future__ import annotations

import json
import subprocess
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from ..client import WorkspaceWatcherClient
from ..config import Config
from ..lm_studio import LMStudioClient
from ..notion_cache import NotionProjectCache
from ..reminders import ReminderEngine
from ..store import WorkspaceStore

REFRESH_SECONDS = 60

# A radio/sensing glyph -- deliberately not an eye, since watching a
# workspace's files is not the same idea as watching a person. Template mode
# (set on the image itself, see `_status_bar_symbol_image`) makes it adapt
# automatically to light/dark menu bars and the highlighted-menu-open state.
_STATUS_SYMBOL_NAME = "dot.radiowaves.left.and.right"


@dataclass
class Suggestion:
    candidate_id: str
    item_id: str | None
    title: str
    folder: str


@dataclass
class ProjectDecision:
    project_id: str
    project_name: str
    existing_matches: list[dict[str, Any]]


@dataclass
class MenuBarStatus:
    active_project_name: str | None
    recent_projects: list[str]
    due_by_folder: dict[str, int]
    suggestions_by_folder: dict[str, list[Suggestion]]
    watcher_running: bool
    lm_studio_ok: bool
    notion_status: dict[str, Any]
    watcher_state: str = "unknown"
    folder_counts: dict[str, int] = field(default_factory=dict)
    project_decisions: list[ProjectDecision] = field(default_factory=list)
    work_log_status: dict[str, Any] = field(default_factory=dict)
    error: str | None = None


def build_status(config: Config) -> MenuBarStatus:
    if not config.db_path.exists():
        return MenuBarStatus(None, [], {}, {}, False, False, {}, error="No database yet -- start the watcher first.")
    with WorkspaceWatcherClient(config.db_path) as client:
        active = client.active_project()
        recent = [p.name for p in client.recently_active_projects(limit=5)]
    store = WorkspaceStore(config.db_path, read_only=True)
    try:
        now = time.time()
        project_decisions = [
            ProjectDecision(
                row["project_id"], row["project_name"],
                [item for item in json.loads(row["options_json"] or "[]") if item.get("kind") == "existing_notion_project"],
            )
            for row in store.project_detection_decisions("pending", due_at=now)
        ]
        due = ReminderEngine(store, config).due_items()
        due_counts = {folder: len(items) for folder, items in due.items()}
        suggestions: dict[str, list[Suggestion]] = {}
        if active:
            for run in store.relevance_runs(1):
                if run["project_id"] != active.project_id:
                    continue
                for candidate in store.relevance_candidates(run["run_id"]):
                    if candidate["decision"] != "surface" or not str(candidate["source"]).startswith("intent:"):
                        continue
                    folder = str(candidate["source"]).split(":", 1)[1]
                    item = store.get_item_by_path(str(candidate["candidate_id"]).split(":", 2)[-1])
                    suggestions.setdefault(folder, []).append(
                        Suggestion(candidate["candidate_id"], item["item_id"] if item else None, item["title"] if item else candidate["candidate_id"], folder)
                    )
        notion_status = NotionProjectCache(store, config.workspace_root, config.notion).status()
        health = store.get_state("watcher.health") or {}
        pause = store.get_state("watcher.pause") or {}
        folder_counts: dict[str, int] = {}
        for row in store.folder_statuses():
            folder_counts[row["status"]] = folder_counts.get(row["status"], 0) + 1
        # The Hammerspoon inbox lives in the v2 core's database (core.db via
        # `HammerspoonInbox`/`CoreStore`), not this legacy events.db this menu
        # bar reads -- see `workspace_watcher/hammerspoon_inbox.py`. Surface
        # its health here once this UI reads v2 state too.
        work_log_status = {
            "notion_sync_enabled": config.work_logs.notion_sync,
            "prepared": len([row for row in store.work_log_drafts() if row["status"] == "prepared"]),
            "sync_failed": len([row for row in store.work_log_drafts() if row["status"] == "sync_failed"]),
        }
    finally:
        store.close()
    watcher_running = _watcher_pid_running(config)
    lm_studio_ok = LMStudioClient(config.work_logs.llm_endpoint, timeout_seconds=2.0).health().ok
    return MenuBarStatus(
        active.project_name if active else None, recent, due_counts, suggestions,
        watcher_running, lm_studio_ok, notion_status,
        "paused" if pause.get("paused") else str(health.get("state", "unknown")), folder_counts,
        project_decisions, work_log_status,
    )


def _watcher_pid_running(config: Config) -> bool:
    result = subprocess.run(["pgrep", "-f", "workspace_watcher.*run"], capture_output=True, text=True)
    return result.returncode == 0


def _cli(config: Config, *args: str) -> subprocess.CompletedProcess:
    cmd = [sys.executable, "-m", "workspace_watcher", "--workspace-root", str(config.workspace_root)]
    cmd += list(args)
    return subprocess.run(cmd, capture_output=True, text=True, cwd=str(Path(__file__).resolve().parents[2]))


def _status_bar_symbol_image() -> Any | None:
    """The menu bar's icon as a native SF Symbol (template mode, so AppKit
    handles light/dark and highlight adaptation itself). Returns ``None`` if
    AppKit or the symbol can't be loaded, so callers can fall back to a plain
    text title instead -- this must never be the reason the menu bar fails
    to start.
    """
    try:
        from AppKit import NSImage
    except ImportError:
        return None
    image = NSImage.imageWithSystemSymbolName_accessibilityDescription_(_STATUS_SYMBOL_NAME, "Workspace Watcher")
    if image is not None:
        image.setTemplate_(True)
    return image


def run_menubar_app(config: Config) -> None:
    import rumps

    ABOUT_TEXT = (
        "Workspace Watcher passively senses activity in your workspace folder -- file "
        "changes, which project you're touching, intent-folder items due for a look -- "
        "and surfaces it here. It never asks you interactive questions; it just watches "
        "and reports.\n\n"
        "Status line: whether the background watcher process is running and its health.\n"
        "Current project: the project it currently believes you're active in, from recent "
        "file activity.\n"
        "Due / Suggested / New: items and projects it noticed that may need your attention.\n\n"
        "Pause suspends the watcher's own detection: no new file-activity sensing, no "
        "active-project updates, no due/suggested surfacing, and no nudges, for the "
        "duration you choose. It does not quit the app or affect any other automation "
        "(e.g. Hammerspoon) -- Resume turns detection back on immediately. Restart "
        "restarts the background watcher process itself, which does not require this."
    )

    class WorkspaceWatcherMenuBarApp(rumps.App):
        def __init__(self) -> None:
            super().__init__("Workspace Watcher", quit_button="Quit")
            self._icon_nsimage = _status_bar_symbol_image()
            if self._icon_nsimage is None:
                self.title = "WW"
            self._rebuild_menu(MenuBarStatus(None, [], {}, {}, False, False, {}))
            self.refresh(None)

        @rumps.timer(REFRESH_SECONDS)
        def refresh(self, _sender: Any) -> None:
            try:
                status = build_status(config)
            except Exception as exc:  # noqa: BLE001 - the menu bar must never crash the app
                status = MenuBarStatus(None, [], {}, {}, False, False, {}, error=str(exc)[:200])
            self._rebuild_menu(status)

        def _rebuild_menu(self, status: MenuBarStatus) -> None:
            due_total = sum(status.due_by_folder.values())
            suggestion_total = sum(len(items) for items in status.suggestions_by_folder.values())
            decision_total = len(status.project_decisions)
            badge_total = due_total + suggestion_total + decision_total
            badge = f" {badge_total}" if badge_total else ""
            self.title = badge if self._icon_nsimage is not None else ("WW" + badge)
            self.menu.clear()
            self.menu.add(rumps.MenuItem(f"Status: {status.watcher_state.title()}"))
            self.menu.add(rumps.MenuItem(f"Project: {status.active_project_name or 'None'}"))
            if status.recent_projects:
                self.menu.add(rumps.MenuItem("Recent: " + ", ".join(status.recent_projects[:3])))
            self.menu.add(rumps.separator)
            if status.error:
                self.menu.add(rumps.MenuItem(f"Error: {status.error}"))
            attention = rumps.MenuItem(f"Due ({due_total})")
            for folder, count in status.due_by_folder.items():
                attention.add(rumps.MenuItem(f"{count} {folder}", callback=self._make_open_folder(folder)))
            self.menu.add(attention)
            suggestions_menu = rumps.MenuItem(f"Suggested ({suggestion_total})")
            for folder, items in status.suggestions_by_folder.items():
                folder_menu = rumps.MenuItem(f"{folder} ({len(items)})")
                for item in items:
                    item_menu = rumps.MenuItem(item.title)
                    if item.item_id:
                        item_menu.add(rumps.MenuItem("Open", callback=self._make_action(item.item_id, "open")))
                        item_menu.add(rumps.MenuItem("Useful", callback=self._make_action(item.item_id, "useful")))
                        item_menu.add(rumps.MenuItem("Not Related", callback=self._make_action(item.item_id, "not-related")))
                        item_menu.add(rumps.MenuItem("Defer", callback=self._make_defer(item.item_id)))
                    folder_menu.add(item_menu)
                suggestions_menu.add(folder_menu)
            self.menu.add(suggestions_menu)
            new_projects_menu = rumps.MenuItem(f"New ({decision_total})")
            for decision in status.project_decisions:
                decision_menu = rumps.MenuItem(decision.project_name)
                for match in decision.existing_matches:
                    decision_menu.add(rumps.MenuItem(
                        f"Link to \"{match['name']}\"",
                        callback=self._make_resolve(decision.project_id, "existing_notion_project", match["notion_project_id"]),
                    ))
                if decision.existing_matches:
                    decision_menu.add(rumps.separator)
                decision_menu.add(rumps.MenuItem("New Project", callback=self._make_resolve(decision.project_id, "create_notion_project")))
                decision_menu.add(rumps.MenuItem("Local Only", callback=self._make_resolve(decision.project_id, "local_only")))
                decision_menu.add(rumps.MenuItem("Ignore", callback=self._make_resolve(decision.project_id, "ignored")))
                decision_menu.add(rumps.separator)
                decision_menu.add(rumps.MenuItem("Snooze 1h", callback=self._make_snooze(decision.project_id, 60)))
                decision_menu.add(rumps.MenuItem("Snooze 1d", callback=self._make_snooze(decision.project_id, 24 * 60)))
                new_projects_menu.add(decision_menu)
            self.menu.add(new_projects_menu)
            self.menu.add(rumps.separator)
            self.menu.add(rumps.MenuItem(f"Daemon: {'On' if status.watcher_running else 'Off'}"))
            if status.folder_counts:
                important = [f"{count} {state}" for state, count in status.folder_counts.items() if state in {"error", "attention", "unknown"}]
                self.menu.add(rumps.MenuItem("Folders: " + (", ".join(important) if important else "Healthy")))
            self.menu.add(rumps.MenuItem(f"LM Studio: {'OK' if status.lm_studio_ok else 'Off'}"))
            notion_desc = "Off" if not status.notion_status.get("enabled") else ("OK" if not status.notion_status.get("last_error") else "Error")
            self.menu.add(rumps.MenuItem(f"Notion: {notion_desc}"))
            wl = status.work_log_status
            sync_desc = "Notion sync on" if wl.get("notion_sync_enabled") else "Notion sync off"
            failed = wl.get("sync_failed", 0)
            work_log_desc = f"{wl.get('prepared', 0)} pending, {sync_desc}" + (f", {failed} failed" if failed else "")
            self.menu.add(rumps.MenuItem(f"Work Log: {work_log_desc}"))
            self.menu.add(rumps.separator)
            pause = rumps.MenuItem("Pause")
            pause.add(rumps.MenuItem("30m", callback=self._pause_30))
            pause.add(rumps.MenuItem("1h", callback=self._pause_60))
            pause.add(rumps.MenuItem("Tomorrow", callback=self._pause_tomorrow))
            pause.add(rumps.MenuItem("Indefinitely", callback=self._pause_indefinitely))
            self.menu.add(pause)
            self.menu.add(rumps.MenuItem("Resume", callback=self._resume))
            self.menu.add(rumps.MenuItem("Restart", callback=self._restart))
            self.menu.add(rumps.MenuItem("Open Folder", callback=self._open_workspace))
            self.menu.add(rumps.separator)
            self.menu.add(rumps.MenuItem("What is this? / About", callback=self._show_about))

        def _show_about(self, _sender: Any) -> None:
            rumps.alert(title="Workspace Watcher", message=ABOUT_TEXT, ok="Got it")

        def _make_open_folder(self, folder: str):
            def _handler(_sender: Any) -> None:
                subprocess.run(["open", str(config.workspace_root / folder)], check=False)
            return _handler

        def _make_action(self, item_id: str, action: str):
            def _handler(_sender: Any) -> None:
                _cli(config, "items", action, item_id)
                self.refresh(None)
            return _handler

        def _make_defer(self, item_id: str):
            def _handler(_sender: Any) -> None:
                _cli(config, "items", "defer", item_id, "--next-session")
                self.refresh(None)
            return _handler

        def _make_resolve(self, project_id: str, status: str, notion_project_id: str | None = None):
            def _handler(_sender: Any) -> None:
                args = ["automation", "resolve", project_id, status]
                if notion_project_id:
                    args += ["--notion-project-id", notion_project_id]
                _cli(config, *args)
                self.refresh(None)
            return _handler

        def _make_snooze(self, project_id: str, minutes: int):
            def _handler(_sender: Any) -> None:
                _cli(config, "automation", "snooze", project_id, "--minutes", str(minutes))
                self.refresh(None)
            return _handler

        def _open_workspace(self, _sender: Any) -> None:
            subprocess.run(["open", str(config.workspace_root)], check=False)

        def _pause_30(self, _sender: Any) -> None:
            _cli(config, "pause", "--minutes", "30"); self.refresh(None)

        def _pause_60(self, _sender: Any) -> None:
            _cli(config, "pause", "--minutes", "60"); self.refresh(None)

        def _pause_tomorrow(self, _sender: Any) -> None:
            _cli(config, "pause", "--until-tomorrow"); self.refresh(None)

        def _pause_indefinitely(self, _sender: Any) -> None:
            _cli(config, "pause"); self.refresh(None)

        def _resume(self, _sender: Any) -> None:
            _cli(config, "resume"); self.refresh(None)

        def _restart(self, _sender: Any) -> None:
            _cli(config, "startup", "restart"); self.refresh(None)

    WorkspaceWatcherMenuBarApp().run()
