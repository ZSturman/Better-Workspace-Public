"""Command-line entry point.

    python -m workspace_watcher run              # start watching (foreground)
    python -m workspace_watcher status            # active project + recent activity
    python -m workspace_watcher recent [--area X] [--all]
    python -m workspace_watcher projects
    python -m workspace_watcher inbox
    python -m workspace_watcher errors

See README.md for details.
"""

from __future__ import annotations

import argparse
import json
import logging
import signal
import sys
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path

import subprocess
import shutil
import uuid

from .client import WorkspaceWatcherClient
from .config import load_config
from .context_engine import ContextEngine
from .intent import IntentItemIndex
from .item_metadata import metadata_path_for, upsert_item_toml_fields
from .notion_cache import NotionProjectCache
from .nudges import snooze_until
from .lm_studio import LMStudioClient
from .relevance import RelevanceEngine
from .reminders import ReminderEngine
from .store import WorkspaceStore
from .projects import ProjectRegistry
from .project_index import ProjectIndex
from .startup import MENUBAR_LABEL, WATCHER_LABEL, install as install_launch_agents, restart as restart_launch_agents, status as launch_agent_status, stop as stop_launch_agents


def _fmt_ts(ts: float | None) -> str:
    if ts is None:
        return "-"
    return datetime.fromtimestamp(ts, tz=timezone.utc).astimezone().strftime("%Y-%m-%d %H:%M:%S")


def cmd_run(args: argparse.Namespace) -> int:
    # v2 is the only live filesystem runtime.  The historical Watcher class
    # remains available to old read-only/reporting commands during migration,
    # but it is never constructed by the production launcher.
    from .core_api import serve
    from .core_config import load_core_config
    from .core_runtime import CoreRuntime

    import socket
    import threading
    config = load_core_config(args.config, Path(args.workspace_root).expanduser() if args.workspace_root else None)
    with socket.socket() as probe:
        if probe.connect_ex(("127.0.0.1", 8765)) == 0:
            print("The background service is already running on http://127.0.0.1:8765. Restart it from Better Workspace (Settings, or `BetterWorkspace --service install`).", file=sys.stderr)
            return 1
    runtime = CoreRuntime(config)
    server = serve(config, runtime=runtime)
    runtime.start()
    # The HTTP server owns the main thread below (server_forever blocks it),
    # so the Hammerspoon inbox / notification / message / scheduler ticking
    # in CoreRuntime.tick_loop runs on its own background thread instead.
    ticker = threading.Thread(target=runtime.tick_loop, name="core-runtime-tick", daemon=True)
    ticker.start()

    def _handle_shutdown_signal(_signum, _frame) -> None:
        # Never call server.shutdown() directly from here: it blocks until
        # serve_forever()'s own loop notices and exits, which cannot happen
        # while that very loop -- on this same thread -- is paused running
        # this handler. Hand it to its own thread instead, so an intentional
        # stop (SIGTERM from `launchctl bootout`/`./run.sh restart`, SIGINT
        # from Ctrl-C) reaches runtime.stop() below and is recorded as
        # `watcher_stopped` rather than being treated as a crash to recover
        # from on the next start.
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, _handle_shutdown_signal)
    signal.signal(signal.SIGINT, _handle_shutdown_signal)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
        runtime.request_stop()
        ticker.join(timeout=5)
        runtime.stop()
    return 0


def cmd_status(args: argparse.Namespace) -> int:
    from .core_config import load_core_config
    from .core_store import CoreStore
    config = load_core_config(args.config, Path(args.workspace_root).expanduser() if args.workspace_root else None)
    if not config.database_path.exists():
        print("No v2 database yet -- start Workspace Watcher with `./run.sh run`.")
        return 1
    with CoreStore(config.database_path, read_only=True) as store:
        health = store.get_state("watcher.health") or {"state": "stopped"}
        print(f"Watcher: {health.get('state', 'unknown')}")
        print(f"Database: {config.database_path}")
        print(f"Intent folders: {len(store.folders())}; items: {len(store.items())}; events: {len(store.recent_events(1000))}")
        print("Watch roots: " + ", ".join(health.get("watch_roots", [str(root) for root in config.intent_settings.search_roots])))
        current = store.get_state("project.current")
        print(f"Current project: {current['name']} ({current['project_id']})" if current else "Current project: none yet")
        print(f"Projects: {len(store.projects())}")
        open_session = store.open_session()
        if open_session:
            started = _fmt_ts(datetime.fromisoformat(open_session["started_at"]).timestamp())
            print(f"Current session: {open_session['project_name']} -- started {started}, "
                  f"~{round(float(open_session['active_seconds']) / 60)}m active, {open_session['meaningful_event_count']} changes")
        else:
            print("Current session: none")
        recent = store.recent_sessions(limit=200)
        completed = [row for row in recent if row["status"] == "completed"]
        print(f"Sessions: {len(completed)} completed, {len(recent) - len(completed) - (1 if open_session else 0)} discarded (most recent {len(recent)})")
        drafts = store.work_log_drafts(limit=500)
        by_status: dict[str, int] = {}
        for row in drafts:
            by_status[row["status"]] = by_status.get(row["status"], 0) + 1
        sync_desc = "Notion sync ON" if config.work_logs.notion_sync else "Notion sync off (dry-run only)"
        print(f"Work Logs: {by_status.get('prepared', 0)} prepared, {by_status.get('synced', 0)} synced, "
              f"{by_status.get('sync_failed', 0)} failed -- {sync_desc}")
        notion_status = store.get_state("notion_projects.health") or {"state": "unknown"}
        print(f"Notion: {'enabled' if config.notion.enabled else 'disabled'}, "
              f"{len(store.cached_notion_projects())} cached projects, health={notion_status.get('state')}")
        lm_status = store.get_state("lm_studio.health") or {"state": "unknown"}
        print(f"LM Studio: {'enabled' if config.lm_studio.enabled else 'disabled'}, health={lm_status.get('state')}")
    return 0


def _v2_config_and_store(args: argparse.Namespace):
    from .core_config import load_core_config
    from .core_store import CoreStore
    config = load_core_config(args.config, Path(args.workspace_root).expanduser() if args.workspace_root else None)
    if not config.database_path.exists():
        print("No v2 database yet -- start Workspace Watcher with `./run.sh run`.")
        return None, None
    return config, CoreStore(config.database_path, read_only=True)


def cmd_work_logs(args: argparse.Namespace) -> int:
    config, store = _v2_config_and_store(args)
    if store is None:
        return 1
    with store:
        for row in store.work_log_drafts(limit=200):
            print(f"{row['id'][:20]:<20} {row['project_name']:<28} {row['date_key']:<12} {row['status']:<12} page={row['notion_page_id'] or '-'}")
    return 0


def cmd_work_logs_preview(args: argparse.Namespace) -> int:
    from .core_store import CoreStore
    from .work_logs_v2 import WorkLogGenerator
    config, store = _v2_config_and_store(args)
    if store is None:
        return 1
    with store:
        # A fresh read-write store, not the read-only one above -- preview
        # never writes to Notion, but it does need a real (writable-mode)
        # CoreStore to construct a WorkLogGenerator the same way the live
        # runtime would; still zero database mutation happens here.
        rw_store = CoreStore(config.database_path)
        try:
            generator = WorkLogGenerator(rw_store, config.work_logs, config.notion, config.workspace_root, lm_settings=config.lm_studio)
            for preview in generator.preview_pending(limit=args.limit):
                print(json.dumps(preview, indent=2, default=str))
        finally:
            rw_store.close()
    return 0


def cmd_work_logs_sync(args: argparse.Namespace) -> int:
    from .core_store import CoreStore
    from .work_logs_v2 import WorkLogGenerator
    config, _ = _v2_config_and_store(args)
    if config is None:
        return 1
    if not config.work_logs.notion_sync:
        print("[workspace_watcher.work_logs].notion_sync is false -- nothing will be written. "
              "This is a safety default; see docs/v2-work-log-system.md before changing it.")
        return 1
    if config.work_logs.authoritative_writer != "v2":
        print(f"[workspace_watcher.work_logs].authoritative_writer is {config.work_logs.authoritative_writer!r}, not 'v2' -- "
              "nothing will be written. Legacy systems (Hammerspoon/workspace_telemetry) are still presumed the writer of "
              "record; see the cutover procedure in docs/v2-work-log-system.md before changing this.")
        return 1
    store = CoreStore(config.database_path)
    try:
        generator = WorkLogGenerator(store, config.work_logs, config.notion, config.workspace_root, lm_settings=config.lm_studio)
        for result in generator.sync_pending(limit=args.limit):
            print(json.dumps(result, default=str))
    finally:
        store.close()
    return 0


def cmd_work_logs_enrich(args: argparse.Namespace) -> int:
    from .core_store import CoreStore
    from .work_logs_v2 import WorkLogGenerator
    config, _ = _v2_config_and_store(args)
    if config is None:
        return 1
    if not config.lm_studio.enabled:
        print("[workspace_watcher.lm_studio].enabled is false -- enable it first (see config.toml).")
        return 1
    store = CoreStore(config.database_path)
    try:
        generator = WorkLogGenerator(store, config.work_logs, config.notion, config.workspace_root, lm_settings=config.lm_studio)
        if args.draft_id:
            result = generator.enrich_draft(args.draft_id, force=True)
            print(json.dumps(result, default=str) if result else f"No draft found with id {args.draft_id}")
        else:
            for result in generator.enrich_pending(limit=args.limit, force=args.force):
                print(json.dumps(result, default=str))
    finally:
        store.close()
    return 0


def cmd_notion_cutover_check(args: argparse.Namespace) -> int:
    from .core_store import CoreStore
    from .cutover_preflight_v2 import cutover_preflight
    config, _ = _v2_config_and_store(args)
    if config is None:
        return 1
    store = CoreStore(config.database_path)
    try:
        report = cutover_preflight(store, config.workspace_root, config.notion, config.work_logs, query_limit=args.limit)
        print(json.dumps(report, indent=2, default=str))
        print()
        print("GO" if report["go"] else "NO-GO", f"-- {len(report['blockers'])} blocker(s), {len(report['warnings'])} warning(s)")
    finally:
        store.close()
    return 0


def cmd_notion_status(args: argparse.Namespace) -> int:
    config, store = _v2_config_and_store(args)
    if store is None:
        return 1
    with store:
        cached = store.cached_notion_projects()
        matched = sum(1 for row in cached if row["project_id"] is not None)
        print(f"Notion projects cache: {'enabled' if config.notion.enabled else 'disabled'}")
        print(f"Cached pages: {len(cached)}; matched to a local project: {matched}; unmatched: {len(cached) - matched}")
        reasons: dict[str, int] = {}
        for row in cached:
            reason = json.loads(row["metadata_json"] or "{}").get("mapping_reason") or "none"
            reasons[reason] = reasons.get(reason, 0) + 1
        for reason, count in sorted(reasons.items()):
            print(f"  {reason}: {count}")
        for key in ("notion_projects.last_attempt", "notion_projects.last_success", "notion_projects.last_error"):
            print(f"{key}: {store.get_state(key)}")
    return 0


def cmd_notion_reconcile(args: argparse.Namespace) -> int:
    from .core_store import CoreStore
    from .reconciliation_v2 import reconcile_work_logs, repair_local_state
    config, _ = _v2_config_and_store(args)
    if config is None:
        return 1
    store = CoreStore(config.database_path)
    try:
        report = reconcile_work_logs(store, config.workspace_root, config.notion)
        print(json.dumps(report, indent=2, default=str))
        if args.apply:
            print("--- applying safe local-only repairs ---")
            outcome = repair_local_state(store, report, dry_run=False)
            print(json.dumps(outcome, indent=2, default=str))
        elif any(report.get(key) for key in ("local_synced_missing_in_notion", "local_page_id_mismatch")):
            preview = repair_local_state(store, report, dry_run=True)
            print("--- would repair (pass --apply to actually do this; local-only, never touches Notion) ---")
            print(json.dumps(preview, indent=2, default=str))
    finally:
        store.close()
    return 0


def cmd_diagnostics(args: argparse.Namespace) -> int:
    from .core_api import _diagnostics
    config, store = _v2_config_and_store(args)
    if store is None:
        return 1
    with store:
        print(json.dumps(_diagnostics(store, config), indent=2, default=str))
    return 0


def cmd_pause(args: argparse.Namespace) -> int:
    config = load_config(args.config, Path(args.workspace_root).expanduser() if args.workspace_root else None)
    until = None
    if args.minutes is not None:
        until = time.time() + args.minutes * 60
    elif args.until_tomorrow:
        local = datetime.now().astimezone()
        tomorrow = (local + timedelta(days=1)).replace(hour=0, minute=0, second=0, microsecond=0)
        until = tomorrow.timestamp()
    store = WorkspaceStore(config.db_path)
    try:
        store.set_state("watcher.pause", {"paused": True, "until": until, "requested_at": time.time()})
    finally:
        store.close()
    print("Watcher paused" + (f" until {_fmt_ts(until)}." if until else " indefinitely."))
    return 0


def cmd_resume(args: argparse.Namespace) -> int:
    config = load_config(args.config, Path(args.workspace_root).expanduser() if args.workspace_root else None)
    store = WorkspaceStore(config.db_path)
    try:
        store.set_state("watcher.pause", {"paused": False, "resumed_at": time.time()})
    finally:
        store.close()
    print("Watcher will resume and reconcile within 30 seconds.")
    return 0


def cmd_activity_feed(args: argparse.Namespace) -> int:
    config = load_config(args.config, Path(args.workspace_root).expanduser() if args.workspace_root else None)
    store = WorkspaceStore(config.db_path, read_only=True)
    try:
        rows = store.recent_activity_feed(args.limit, project_id=args.project_id, kind=args.kind)
    finally:
        store.close()
    for row in rows:
        print(f"{_fmt_ts(row['ts'])}  {row['summary']}")
    return 0


def cmd_folder_status(args: argparse.Namespace) -> int:
    config = load_config(args.config, Path(args.workspace_root).expanduser() if args.workspace_root else None)
    store = WorkspaceStore(config.db_path, read_only=True)
    try:
        rows = [row for row in store.folder_statuses() if row["path"] == args.path or row["project_id"] == args.path]
    finally:
        store.close()
    if not rows:
        print("No derived status yet. Start the watcher or run index rebuild.")
        return 1
    for row in rows:
        print(f"{row['path']}: {row['status']} (updated {_fmt_ts(row['updated_at'])})")
        for reason in json.loads(row["reasons_json"]):
            print("  - " + reason.get("message", reason.get("kind", "")))
    return 0


def cmd_health_failure(args: argparse.Namespace) -> int:
    config = load_config(args.config, Path(args.workspace_root).expanduser() if args.workspace_root else None)
    store = WorkspaceStore(config.db_path)
    try:
        if store.get_project(args.project_id) is None:
            raise ValueError(f"Unknown watcher project ID: {args.project_id}")
        store.record_project_signal(str(uuid.uuid4()), args.project_id, "failure", "error", args.summary, {"command": args.command or "", "source": "explicit_report"}, time.time())
    finally:
        store.close()
    print("Recorded failure evidence. The running watcher will recalculate status within 30 seconds.")
    return 0


def cmd_health_resolve(args: argparse.Namespace) -> int:
    config = load_config(args.config, Path(args.workspace_root).expanduser() if args.workspace_root else None)
    store = WorkspaceStore(config.db_path)
    try:
        count = store.resolve_project_signals(args.project_id, "failure", time.time())
    finally:
        store.close()
    print(f"Resolved {count} failure signal(s).")
    return 0


def cmd_startup(args: argparse.Namespace) -> int:
    config = load_config(args.config, Path(args.workspace_root).expanduser() if args.workspace_root else None)
    if args.startup_command == "install":
        paths = install_launch_agents(config, include_menubar=args.with_menubar)
        print("Installed and started:")
        for path in paths:
            print("  " + str(path))
    elif args.startup_command == "stop":
        stop_launch_agents(include_menubar=not args.watcher_only)
        print("Stopped Workspace Watcher LaunchAgent(s).")
    elif args.startup_command == "disable":
        stop_launch_agents(include_menubar=not args.watcher_only, remove=True)
        print("Disabled automatic startup and removed LaunchAgent file(s).")
    elif args.startup_command == "restart":
        restart_launch_agents(config)
        print("Restarted the background service LaunchAgent(s).")
    elif args.startup_command == "status":
        for label, item in launch_agent_status(config)["agents"].items():
            print(f"{label}: {'running' if item['running'] else 'not running'}; {'installed' if item['installed'] else 'not installed'}")
            if item["detail"] and not item["running"]:
                print("  " + item["detail"])
    return 0


def cmd_doctor(args: argparse.Namespace) -> int:
    """Small, no-network diagnostic suitable for a support report."""
    config = load_config(args.config, Path(args.workspace_root).expanduser() if args.workspace_root else None)
    print(f"Workspace: {config.workspace_root} ({'ok' if config.workspace_root.is_dir() else 'missing'})")
    print(f"Database: {config.db_path} ({'ok' if config.db_path.exists() else 'not created'})")
    agents = launch_agent_status(config)["agents"]
    print("Watcher agent: " + ("running" if agents[WATCHER_LABEL]["running"] else "not running"))
    print("Menu-bar agent: " + ("running" if agents[MENUBAR_LABEL]["running"] else "not running"))
    if config.db_path.exists():
        store = WorkspaceStore(config.db_path, read_only=True)
        try:
            health = store.get_state("watcher.health") or {"state": "unknown"}
            print("Watcher health: " + str(health.get("state", "unknown")))
            print(f"Open reconciliation issues: {len(store.reconciliation_issues('open'))}")
            print(f"Recent handler errors: {len(store.recent_handler_errors(20))}")
        finally:
            store.close()
    print("Log: " + str(config.log_path))
    return 0


def cmd_recent(args: argparse.Namespace) -> int:
    config = load_config(args.config, Path(args.workspace_root).expanduser() if args.workspace_root else None)
    with WorkspaceWatcherClient(config.db_path) as client:
        events = client.recent_events(limit=args.limit, area_kind=args.area, meaningful_only=not args.all)
        for e in events:
            arrow = f" -> {e['prev_path']}" if e["prev_path"] else ""
            print(f"{_fmt_ts(e['ts'])}  {e['type']:<22} {e['area']:<14} {e['path']}{arrow}")
    return 0


def cmd_projects(args: argparse.Namespace) -> int:
    config = load_config(args.config, Path(args.workspace_root).expanduser() if args.workspace_root else None)
    with WorkspaceWatcherClient(config.db_path) as client:
        for p in client.all_projects(status=None):
            print(f"{p.name:<30} {p.status:<8} last_activity={_fmt_ts(p.last_activity_at)} events={p.meaningful_event_count}  ({p.project_id})")
    return 0


def cmd_inbox(args: argparse.Namespace) -> int:
    config = load_config(args.config, Path(args.workspace_root).expanduser() if args.workspace_root else None)
    with WorkspaceWatcherClient(config.db_path) as client:
        for entry in client.inbox_snapshot():
            print(f"{_fmt_ts(entry['first_seen_at'])}  {entry['path']}")
    return 0


def cmd_errors(args: argparse.Namespace) -> int:
    config = load_config(args.config, Path(args.workspace_root).expanduser() if args.workspace_root else None)
    with WorkspaceWatcherClient(config.db_path) as client:
        for e in client.recent_handler_errors(args.limit):
            print(f"{_fmt_ts(e['ts'])}  {e['handler']}  event={e['event_id']}  {e['error']}")
    return 0


def _local_day_range(date_value: str | None) -> tuple[float, float, str]:
    zone = datetime.now().astimezone().tzinfo
    if date_value:
        try:
            day = datetime.fromisoformat(date_value).date()
        except ValueError as exc:
            raise ValueError("--date must use YYYY-MM-DD") from exc
    else:
        day = datetime.now().astimezone().date()
    start = datetime(day.year, day.month, day.day, tzinfo=zone)
    return start.timestamp(), (start + timedelta(days=1)).timestamp(), day.isoformat()


def _fmt_minutes(seconds: float | int | None) -> str:
    return f"{float(seconds or 0) / 60:.1f}m"


def _ensure_activity_schema(config) -> None:
    """Apply additive SQLite tables before a read-only activity query.

    Existing watcher databases predate the intelligence tables.  This cheap
    local migration keeps inspection commands usable before the daemon has
    next been restarted.
    """

    if config.db_path.exists():
        store = WorkspaceStore(config.db_path)
        store.close()


def cmd_activity_today(args: argparse.Namespace) -> int:
    config = load_config(args.config, Path(args.workspace_root).expanduser() if args.workspace_root else None)
    _ensure_activity_schema(config)
    start, end, day = _local_day_range(args.date)
    with WorkspaceWatcherClient(config.db_path) as client:
        summary = client.daily_activity_summary(start, end)
    print(f"Activity summary — {day}")
    print(f"Meaningful sessions: {summary['meaningful_sessions']}  |  Project switches: {summary['project_switches']}")
    if summary["projects"]:
        print("Projects:")
        for item in summary["projects"]:
            print(f"  {item['project_name']:<30} {_fmt_minutes(item['active_seconds']):>7}  {item['sessions']} session(s), {item['event_count']} events")
    if summary["longest_focused_session"]:
        session = summary["longest_focused_session"]
        print(f"Longest session: {session['project_name']} ({_fmt_minutes(session['active_seconds'])}, confidence {session['confidence']:.2f})")
    if summary["fragmentation"]:
        metric = summary["fragmentation"][0]
        print(f"Latest fragmentation: {metric['project_count']} projects, {metric['switch_count']} switches in {metric['window_minutes']:.0f}m")
    if summary["priority_alignment"]:
        alignment = summary["priority_alignment"][0]["details"]
        print(f"Priority alignment: {alignment.get('aligned')}")
    nudge_counts: dict[str, int] = {}
    for item in summary["nudges"]:
        nudge_counts[item["decision"]] = nudge_counts.get(item["decision"], 0) + 1
    print(
        f"Work Logs: {len(summary['work_logs'])}  |  Nudges: "
        f"{nudge_counts.get('delivered', 0)} delivered, {nudge_counts.get('suppressed', 0)} suppressed "
        f"({len(summary['nudges'])} considered)"
    )
    return 0


def cmd_activity_sessions(args: argparse.Namespace) -> int:
    config = load_config(args.config, Path(args.workspace_root).expanduser() if args.workspace_root else None)
    _ensure_activity_schema(config)
    start, _, _ = _local_day_range(args.date) if args.date else (None, None, None)
    with WorkspaceWatcherClient(config.db_path) as client:
        sessions = client.activity_sessions(start, include_discarded=args.all, limit=args.limit)
    for item in sessions:
        print(f"{_fmt_ts(item['started_at'])}  {item['status']:<10} {item['project_name']:<28} {_fmt_minutes(item['active_seconds']):>7}  events={item['meaningful_event_count']} files={len(item['files'])} confidence={item['confidence']:.2f}")
    return 0


def cmd_activity_priorities(args: argparse.Namespace) -> int:
    config = load_config(args.config, Path(args.workspace_root).expanduser() if args.workspace_root else None)
    _ensure_activity_schema(config)
    with WorkspaceWatcherClient(config.db_path) as client:
        snapshots = client.priority_alignment(1)
    if not snapshots:
        print("No priority snapshot yet. Enable [notion], run activity notion-refresh, then let the watcher observe activity.")
        return 0
    details = snapshots[0]["details"]
    print(f"Priority alignment: {details.get('aligned')}")
    print("Ranked projects:")
    for item in details.get("ranked_projects", [])[:10]:
        print(f"  {item['priority']:>6.2f}  {item['project_name']}  current={', '.join(item.get('current_work') or []) or '-'}")
    if details.get("dominant_low_priority"):
        item = details["dominant_low_priority"]
        print(f"Priority drift evidence: {item['project_name']} has {item['event_count']} recent event(s), activity ratio {item['activity_ratio']:.0%}.")
    if details.get("ignored_high_priority"):
        print("High-priority projects without recent activity: " + ", ".join(item["project_name"] for item in details["ignored_high_priority"]))
    return 0


def cmd_activity_switches(args: argparse.Namespace) -> int:
    config = load_config(args.config, Path(args.workspace_root).expanduser() if args.workspace_root else None)
    _ensure_activity_schema(config)
    with WorkspaceWatcherClient(config.db_path) as client:
        metrics = client.fragmentation_metrics(args.limit)
    for item in metrics:
        print(f"{_fmt_ts(item['evaluated_at'])}  {item['project_count']} projects  {item['switch_count']} switches  recurring={item['recurring_project_count']} short_stints={item['short_stint_count']} ({item['window_minutes']:.0f}m window)")
    return 0


def cmd_activity_nudges(args: argparse.Namespace) -> int:
    config = load_config(args.config, Path(args.workspace_root).expanduser() if args.workspace_root else None)
    _ensure_activity_schema(config)
    with WorkspaceWatcherClient(config.db_path) as client:
        decisions = client.nudge_decisions(args.limit)
    for item in decisions:
        reason = f" ({item['suppression_reason']})" if item["suppression_reason"] else ""
        print(f"{_fmt_ts(item['evaluated_at'])}  {item['rule']:<24} {item['decision']}{reason}  {item['message']}")
    return 0


def cmd_activity_notion_refresh(args: argparse.Namespace) -> int:
    config = load_config(args.config, Path(args.workspace_root).expanduser() if args.workspace_root else None)
    store = WorkspaceStore(config.db_path)
    try:
        result = NotionProjectCache(store, config.workspace_root, config.notion).refresh()
    finally:
        store.close()
    if result.get("ok"):
        print(f"Refreshed {result['projects']} Notion project record(s).")
        return 0
    print(result.get("error") or result.get("reason") or "Notion refresh did not run.")
    return 1 if result.get("error") else 0


def cmd_activity_snooze(args: argparse.Namespace) -> int:
    config = load_config(args.config, Path(args.workspace_root).expanduser() if args.workspace_root else None)
    store = WorkspaceStore(config.db_path)
    try:
        until = snooze_until(datetime.now().astimezone().timestamp(), args.minutes)
        store.set_state("intelligence.nudges.snooze_until", until)
    finally:
        store.close()
    print(f"Nudges snoozed until {_fmt_ts(until)}.")
    return 0


def cmd_lm_studio(args: argparse.Namespace) -> int:
    config = load_config(args.config, Path(args.workspace_root).expanduser() if args.workspace_root else None)
    health = LMStudioClient(config.work_logs.llm_endpoint, config.work_logs.llm_timeout_seconds).health()
    if health.ok:
        print("LM Studio reachable. Models: " + (", ".join(health.models) or "server did not report any"))
        return 0
    print(f"LM Studio unavailable: {health.error}")
    return 1


def _relevance_context(config, project_id: str | None):
    if not config.db_path.exists():
        raise ValueError("No database yet -- start the watcher first.")
    with WorkspaceWatcherClient(config.db_path) as client:
        target = project_id or (client.active_project().project_id if client.active_project() else None)
        if not target:
            raise ValueError("No active project; pass a project ID from `projects`.")
        context = client.project_activity(target)
    if not context:
        raise ValueError(f"Unknown project: {target}")
    return context


def cmd_relevance_run(args: argparse.Namespace) -> int:
    config = load_config(args.config, Path(args.workspace_root).expanduser() if args.workspace_root else None)
    _ensure_activity_schema(config)
    context = _relevance_context(config, args.project_id)
    store = WorkspaceStore(config.db_path)
    try:
        result = RelevanceEngine(store, config.relevance).run(context, dry_run=args.dry_run)
    finally:
        store.close()
    print(f"Relevance for {result.project_name} ({'dry run' if args.dry_run else result.run_id}):")
    for item in result.candidates:
        why = item["suppression_reason"] or ",".join(item["explanation"].get("concept_overlap", [])[:4]) or "no overlap"
        print(f"  {item['score']:.3f}  {item['decision']:<10} {item['source']:<24} {item['title']} [{why}]")
    return 0


def cmd_relevance_refresh(args: argparse.Namespace) -> int:
    config = load_config(args.config, Path(args.workspace_root).expanduser() if args.workspace_root else None)
    store = WorkspaceStore(config.db_path)
    try:
        count = RelevanceEngine(store, config.relevance).refresh_sources()
    finally:
        store.close()
    print(f"Indexed {count} local/cached relevance source document(s).")
    return 0


def cmd_relevance_history(args: argparse.Namespace) -> int:
    config = load_config(args.config, Path(args.workspace_root).expanduser() if args.workspace_root else None)
    store = WorkspaceStore(config.db_path, read_only=True)
    try:
        for row in store.relevance_runs(args.limit):
            print(f"{_fmt_ts(row['completed_at'])}  {row['project_name']:<28} {row['status']:<10} {row['run_id']}")
    finally:
        store.close()
    return 0


def _describe_project_detection_option(item: dict) -> str:
    kind = item.get("kind")
    if kind == "existing_notion_project":
        return f"existing_notion_project: link to \"{item['name']}\" (--notion-project-id {item['notion_project_id']}, match {item['score']:.2f})"
    if kind == "create_notion_project":
        return "create_notion_project: create a brand-new project"
    if kind == "local_only":
        return "local_only: keep it local, don't link any existing project"
    if kind == "ignore_for_now":
        return "ignored: dismiss, this folder isn't a project"
    return kind or "unknown"


def cmd_automation_pending(args: argparse.Namespace) -> int:
    config = load_config(args.config, Path(args.workspace_root).expanduser() if args.workspace_root else None)
    _ensure_activity_schema(config)
    now = time.time()
    store = WorkspaceStore(config.db_path, read_only=True)
    try:
        due_at = None if args.include_snoozed else now
        rows = store.project_detection_decisions("pending", due_at=due_at)
        for row in rows:
            options = json.loads(row["options_json"] or "[]")
            print(f"{row['project_id']}  {row['project_name']}")
            for item in options:
                print(f"  - {_describe_project_detection_option(item)}")
            if row["snoozed_until"] and row["snoozed_until"] > now:
                snoozed_at = datetime.fromtimestamp(row["snoozed_until"]).astimezone().strftime("%Y-%m-%d %H:%M")
                print(f"  (snoozed until {snoozed_at})")
        if not rows:
            print("No pending project decisions.")
    finally:
        store.close()
    return 0


def cmd_automation_resolve(args: argparse.Namespace) -> int:
    config = load_config(args.config, Path(args.workspace_root).expanduser() if args.workspace_root else None)
    store = WorkspaceStore(config.db_path)
    try:
        resolution = {"chosen_by": "cli", "note": args.note or ""}
        if args.notion_project_id:
            resolution["notion_project_id"] = args.notion_project_id
        found = store.resolve_project_detection(args.project_id, args.status, resolution, time.time())
    finally:
        store.close()
    if not found:
        print(f"No pending project decision for {args.project_id}.")
        return 1
    print(f"Recorded {args.status} for {args.project_id}; no Notion project was created.")
    return 0


def cmd_automation_snooze(args: argparse.Namespace) -> int:
    config = load_config(args.config, Path(args.workspace_root).expanduser() if args.workspace_root else None)
    now = time.time()
    until = (datetime.fromtimestamp(now).astimezone() + timedelta(minutes=args.minutes)).timestamp()
    store = WorkspaceStore(config.db_path)
    try:
        found = store.snooze_project_detection(args.project_id, until, now)
    finally:
        store.close()
    if not found:
        print(f"No pending project decision for {args.project_id}.")
        return 1
    snoozed_at = datetime.fromtimestamp(until).astimezone().strftime("%Y-%m-%d %H:%M")
    print(f"Will ask again about {args.project_id} at {snoozed_at}.")
    return 0


def cmd_index_rebuild(args: argparse.Namespace) -> int:
    config = load_config(args.config, Path(args.workspace_root).expanduser() if args.workspace_root else None)
    projects_area = next((area for area in config.areas if area.kind == "projects"), None)
    store = WorkspaceStore(config.db_path)
    try:
        registry = ProjectRegistry(store, config.workspace_root, projects_area.path if projects_area else "Projects")
        summary = ProjectIndex(store, registry, config.workspace_root, projects_area.path if projects_area else "Projects", __import__("logging").getLogger("workspace_watcher.index")).rebuild(reason="manual_rebuild")
    finally:
        store.close()
    print(f"Rebuilt local index generation {summary['generation']}: {summary['projects']} project(s), {summary['unknown']} unknown folder(s).")
    return 0


def cmd_index_issues(args: argparse.Namespace) -> int:
    config = load_config(args.config, Path(args.workspace_root).expanduser() if args.workspace_root else None)
    store = WorkspaceStore(config.db_path, read_only=True)
    try:
        rows = store.reconciliation_issues(args.state)
    finally:
        store.close()
    for row in rows:
        print(f"{row['severity']:<8} {row['state']:<9} {row['kind']:<24} {row['path'] or '-'} ({row['issue_id']})")
    return 0


def _cli_logger() -> logging.Logger:
    logger = logging.getLogger("workspace_watcher.cli")
    if not logger.handlers:
        logger.addHandler(logging.NullHandler())
    return logger


def _resolve_project_id(config, project_id: str | None) -> str:
    if project_id:
        return project_id
    with WorkspaceWatcherClient(config.db_path) as client:
        active = client.active_project()
    if not active:
        raise ValueError("No active project; pass --project explicitly.")
    return active.project_id


def cmd_intent_rebuild(args: argparse.Namespace) -> int:
    config = load_config(args.config, Path(args.workspace_root).expanduser() if args.workspace_root else None)
    store = WorkspaceStore(config.db_path)
    try:
        summary = IntentItemIndex(store, config.workspace_root).rebuild(config, reason="manual_rebuild")
    finally:
        store.close()
    print(f"Indexed {summary['folders']} intent folder(s), {summary['items']} item(s).")
    return 0


def cmd_intent_folders(args: argparse.Namespace) -> int:
    config = load_config(args.config, Path(args.workspace_root).expanduser() if args.workspace_root else None)
    store = WorkspaceStore(config.db_path, read_only=True) if config.db_path.exists() else None
    counts: dict[str, int] = {}
    try:
        if store:
            for row in store.all_items(only_existing=True):
                counts[row["intent_folder"]] = counts.get(row["intent_folder"], 0) + 1
    finally:
        if store:
            store.close()
    for folder in config.intent_folders:
        print(f"{folder.name:<16} {folder.category:<11} items={counts.get(folder.name, 0):<4} actions=[{', '.join(folder.actions)}]")
    return 0


def cmd_items_list(args: argparse.Namespace) -> int:
    config = load_config(args.config, Path(args.workspace_root).expanduser() if args.workspace_root else None)
    store = WorkspaceStore(config.db_path, read_only=True)
    try:
        rows = store.all_items(intent_folder=args.folder, only_existing=not args.all)
    finally:
        store.close()
    for row in rows:
        print(f"{row['item_id']}  {row['intent_folder']:<16} {row['title'] or row['name']}  ({row['path']})")
    return 0


def cmd_items_show(args: argparse.Namespace) -> int:
    config = load_config(args.config, Path(args.workspace_root).expanduser() if args.workspace_root else None)
    store = WorkspaceStore(config.db_path, read_only=True)
    try:
        item = store.get_item(args.item_id)
        if item is None:
            print(f"Unknown item: {args.item_id}")
            return 1
        tags = store.tags_for_item(item["item_id"])
        lm_state = json.loads(item["lm_state_json"] or "{}")
    finally:
        store.close()
    print(f"{item['title'] or item['name']}  ({item['path']})")
    print(f"Folder: {item['intent_folder']}   Priority: {item['priority']}   Archive state: {item['archive_state']}")
    if item["description"]:
        print(f"Description: {item['description']}")
    print("Tags: " + (", ".join(f"{t['display']} [{t['provenance']}]" for t in tags) or "(none)"))
    if lm_state.get("summary"):
        print(f"LM Studio summary: {lm_state['summary']}")
    return 0


def cmd_items_tag(args: argparse.Namespace) -> int:
    config = load_config(args.config, Path(args.workspace_root).expanduser() if args.workspace_root else None)
    store = WorkspaceStore(config.db_path)
    try:
        item = store.get_item(args.item_id)
        if item is None:
            print(f"Unknown item: {args.item_id}")
            return 1
        for tag in args.add:
            store.add_item_tag(item["item_id"], tag, provenance="user")
        current_tags = [t["display"] for t in store.tags_for_item(item["item_id"]) if t["provenance"] == "user"]
    finally:
        store.close()
    meta_path = metadata_path_for(config.workspace_root / item["path"], bool(item["is_directory"]))
    upsert_item_toml_fields(meta_path, {"tags": current_tags})
    print(f"Tags for {item['path']}: {', '.join(current_tags)}")
    return 0


def cmd_items_open(args: argparse.Namespace) -> int:
    config = load_config(args.config, Path(args.workspace_root).expanduser() if args.workspace_root else None)
    store = WorkspaceStore(config.db_path)
    try:
        item = store.get_item(args.item_id)
        if item is None:
            print(f"Unknown item: {args.item_id}")
            return 1
        store.mark_item_reviewed(item["item_id"], time.time())
    finally:
        store.close()
    subprocess.run(["open", str(config.workspace_root / item["path"])], check=False)
    print(f"Opened {item['path']}")
    return 0


def cmd_items_useful(args: argparse.Namespace) -> int:
    config = load_config(args.config, Path(args.workspace_root).expanduser() if args.workspace_root else None)
    store = WorkspaceStore(config.db_path)
    try:
        project_id = _resolve_project_id(config, args.project)
        item = store.get_item(args.item_id)
        if item is None:
            print(f"Unknown item: {args.item_id}")
            return 1
        ContextEngine(store, config, _cli_logger()).record_relationship(item["item_id"], project_id, "useful")
    finally:
        store.close()
    print(f"Marked \"{item['title'] or item['name']}\" useful for project {project_id}.")
    return 0


def cmd_items_not_related(args: argparse.Namespace) -> int:
    config = load_config(args.config, Path(args.workspace_root).expanduser() if args.workspace_root else None)
    store = WorkspaceStore(config.db_path)
    try:
        project_id = _resolve_project_id(config, args.project)
        item = store.get_item(args.item_id)
        if item is None:
            print(f"Unknown item: {args.item_id}")
            return 1
        ContextEngine(store, config, _cli_logger()).record_relationship(item["item_id"], project_id, "not_related", log_work_log=False)
    finally:
        store.close()
    print(f"\"{item['title'] or item['name']}\" will not be suggested again for this project.")
    return 0


def cmd_items_defer(args: argparse.Namespace) -> int:
    config = load_config(args.config, Path(args.workspace_root).expanduser() if args.workspace_root else None)
    now = time.time()
    defer_until = None
    defer_next_session = False
    if args.next_session:
        defer_next_session = True
    elif args.tomorrow:
        defer_until = now + 86400
    elif args.days is not None:
        defer_until = now + args.days * 86400
    elif args.until:
        defer_until = datetime.fromisoformat(args.until).astimezone().timestamp()
    else:
        raise ValueError("Specify one of --next-session, --tomorrow, --days N, or --until YYYY-MM-DD")
    store = WorkspaceStore(config.db_path)
    try:
        project_id = _resolve_project_id(config, args.project)
        item = store.get_item(args.item_id)
        if item is None:
            print(f"Unknown item: {args.item_id}")
            return 1
        ContextEngine(store, config, _cli_logger()).record_relationship(
            item["item_id"], project_id, "deferred", defer_until=defer_until, defer_next_session=defer_next_session,
        )
    finally:
        store.close()
    when = "next session" if defer_next_session else _fmt_ts(defer_until)
    print(f"Deferred \"{item['title'] or item['name']}\" until {when} for project {project_id}.")
    return 0


def cmd_items_archive(args: argparse.Namespace) -> int:
    config = load_config(args.config, Path(args.workspace_root).expanduser() if args.workspace_root else None)
    store = WorkspaceStore(config.db_path)
    try:
        item = store.get_item(args.item_id)
        if item is None:
            print(f"Unknown item: {args.item_id}")
            return 1
        folder_cfg = next((f for f in config.intent_folders if f.name == item["intent_folder"]), None)
        requires_confirmation = folder_cfg.requires_confirmation if folder_cfg else True
        destination_rel = args.destination or (folder_cfg.archive_destination if folder_cfg else "")
        if not destination_rel:
            print("No archive destination configured for this folder; pass --destination.")
            return 1
        if requires_confirmation and not args.confirm:
            print(f'This will move "{item["path"]}" to "{destination_rel}/{item["name"]}". Re-run with --confirm to proceed.')
            return 2
        source_abs = config.workspace_root / item["path"]
        dest_dir = config.workspace_root / destination_rel
        dest_dir.mkdir(parents=True, exist_ok=True)
        dest_abs = dest_dir / item["name"]
        shutil.move(str(source_abs), str(dest_abs))
        store.mark_item_archive_state(item["item_id"], "archived")
        # The destination is outside any configured intent folder (that's the
        # point of archiving), so nothing else will ever mark this item gone
        # from its old location -- a move event's new path doesn't match an
        # intent folder, so the watcher's own incremental refresh can't do it.
        store.mark_item_deleted(item["path"], time.time())
        project_id = args.project or item["source_project"]
        if project_id:
            ContextEngine(store, config, _cli_logger()).record_relationship(item["item_id"], project_id, "archived")
        else:
            store.add_work_log_manual_entry({
                "entry_id": str(uuid.uuid4()), "project_id": None, "project_name": None, "ts": time.time(),
                "kind": "item_archived", "summary": f'Archived "{item["title"] or item["name"]}" after review.',
                "metadata": {"item_id": item["item_id"], "item_path": item["path"]},
            })
    finally:
        store.close()
    print(f"Archived to {destination_rel}/{item['name']}.")
    return 0


def cmd_tags_search(args: argparse.Namespace) -> int:
    config = load_config(args.config, Path(args.workspace_root).expanduser() if args.workspace_root else None)
    store = WorkspaceStore(config.db_path, read_only=True)
    try:
        rows = store.search_tags(args.query)
    finally:
        store.close()
    for row in rows:
        print(row["display"])
    return 0


def cmd_tags_related(args: argparse.Namespace) -> int:
    config = load_config(args.config, Path(args.workspace_root).expanduser() if args.workspace_root else None)
    store = WorkspaceStore(config.db_path, read_only=True)
    try:
        matches = store.search_tags(args.tag, limit=1)
        if not matches:
            print(f"No such tag: {args.tag}")
            return 1
        rows = store.related_tags(matches[0]["tag_id"])
    finally:
        store.close()
    for row in rows:
        print(f"{row['display']}  (shared on {row['shared_items']} item(s))")
    return 0


def cmd_context_current(args: argparse.Namespace) -> int:
    config = load_config(args.config, Path(args.workspace_root).expanduser() if args.workspace_root else None)
    with WorkspaceWatcherClient(config.db_path) as client:
        active = client.active_project()
    store = WorkspaceStore(config.db_path, read_only=True)
    try:
        due = ReminderEngine(store, config).due_items()
    finally:
        store.close()
    print(f"Active project: {active.project_name if active else 'none'}")
    if due:
        print("Due for review:")
        for folder, items in due.items():
            print(f"  {folder}: {len(items)}")
    else:
        print("Nothing due for review.")
    return 0


def cmd_context_project(args: argparse.Namespace) -> int:
    config = load_config(args.config, Path(args.workspace_root).expanduser() if args.workspace_root else None)
    with WorkspaceWatcherClient(config.db_path) as client:
        context = client.project_activity(args.project_id)
    if context is None:
        print(f"Unknown project: {args.project_id}")
        return 1
    print(f"{context.project.name}: {len(context.files_touched)} file(s) touched in the last {context.window_hours:.0f}h")
    store = WorkspaceStore(config.db_path, read_only=True)
    try:
        entries = store.recent_work_log_manual_entries(args.project_id, 10)
    finally:
        store.close()
    if entries:
        print("Recent decisions:")
        for e in entries:
            print(f"  {_fmt_ts(e['ts'])}  {e['summary']}")
    return 0


def cmd_inspiration_suggest(args: argparse.Namespace) -> int:
    config = load_config(args.config, Path(args.workspace_root).expanduser() if args.workspace_root else None)
    _ensure_activity_schema(config)
    context = _relevance_context(config, args.project_id)
    store = WorkspaceStore(config.db_path)
    try:
        result = RelevanceEngine(store, config.relevance).run(context, dry_run=args.dry_run)
    finally:
        store.close()
    surfaced = [c for c in result.candidates if c["decision"] == "surface" and str(c["source"]).startswith("intent:")]
    if not surfaced:
        print(f"No contextual matches right now for {result.project_name}.")
        return 0
    for c in surfaced:
        why = ", ".join(c["explanation"].get("concept_overlap", [])[:4]) or "tag overlap"
        print(f"{c['score']:.3f}  {str(c['source']).split(':', 1)[1]:<18} {c['title']}  [{why}]  ({c['candidate_id']})")
    return 0


def cmd_reminders_due(args: argparse.Namespace) -> int:
    config = load_config(args.config, Path(args.workspace_root).expanduser() if args.workspace_root else None)
    store = WorkspaceStore(config.db_path, read_only=True)
    try:
        due = ReminderEngine(store, config).due_items()
    finally:
        store.close()
    if not due:
        print("Nothing due.")
        return 0
    for folder, items in due.items():
        print(f"{folder}:")
        for item in items:
            print(f"  {item['title']}  ({item['path']})")
    return 0


def cmd_worklog_add(args: argparse.Namespace) -> int:
    config = load_config(args.config, Path(args.workspace_root).expanduser() if args.workspace_root else None)
    store = WorkspaceStore(config.db_path)
    try:
        store.add_work_log_manual_entry({
            "entry_id": str(uuid.uuid4()), "project_id": args.project_id, "project_name": None,
            "ts": time.time(), "kind": "manual", "summary": args.summary, "metadata": {},
        })
    finally:
        store.close()
    print("Added manual Work Log entry.")
    return 0


def cmd_worklog_recent(args: argparse.Namespace) -> int:
    config = load_config(args.config, Path(args.workspace_root).expanduser() if args.workspace_root else None)
    with WorkspaceWatcherClient(config.db_path) as client:
        drafts = client.work_log_drafts(limit=200)
    store = WorkspaceStore(config.db_path, read_only=True)
    try:
        manual = store.recent_work_log_manual_entries(args.project_id, args.limit)
    finally:
        store.close()
    for draft in [d for d in drafts if d["project_id"] == args.project_id][: args.limit]:
        print(f"{draft['date_key']}  session-draft  {draft['payload'].get('summary', '')}")
    for entry in manual:
        print(f"{_fmt_ts(entry['ts'])}  {entry['kind']:<16} {entry['summary']}")
    return 0


def cmd_menubar(args: argparse.Namespace) -> int:
    from .ui.menubar import run_menubar_app  # module itself has no hard rumps dependency

    config = load_config(args.config, Path(args.workspace_root).expanduser() if args.workspace_root else None)
    try:
        run_menubar_app(config)
    except ImportError as exc:
        print(f"Menu bar UI requires the optional 'rumps' dependency: {exc}\nInstall it with: .venv/bin/pip install -r requirements-ui.txt")
        return 1
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="workspace_watcher")
    parser.add_argument("--config", type=Path, default=None, help="Path to config.toml")
    parser.add_argument("--workspace-root", type=str, default=None, help="Override workspace root")
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("run", help="Start watching in the foreground").set_defaults(func=cmd_run)

    p_status = sub.add_parser("status", help="Show active project and recent activity")
    p_status.set_defaults(func=cmd_status)

    sub.add_parser("diagnostics", help="v2: one consolidated health/state dump (why did it do that?)").set_defaults(func=cmd_diagnostics)

    work_logs = sub.add_parser("work-logs", help="v2 Work Log drafts (see also the legacy 'worklog' command)")
    work_logs_sub = work_logs.add_subparsers(dest="work_logs_command", required=False)
    work_logs.set_defaults(func=cmd_work_logs)  # `work-logs` alone lists drafts
    p_wl_preview = work_logs_sub.add_parser("preview", help="Dry-run: exactly what would be written to Notion, never writes")
    p_wl_preview.add_argument("--limit", type=int, default=20)
    p_wl_preview.set_defaults(func=cmd_work_logs_preview)
    p_wl_sync = work_logs_sub.add_parser("sync", help="Sync pending drafts to Notion (refuses unless notion_sync=true)")
    p_wl_sync.add_argument("--limit", type=int, default=3)
    p_wl_sync.set_defaults(func=cmd_work_logs_sync)
    p_wl_enrich = work_logs_sub.add_parser("enrich", help="Run (or force-rerun) the optional LM Studio enrichment pass")
    p_wl_enrich.add_argument("--draft-id", default=None, help="Force-regenerate one specific draft")
    p_wl_enrich.add_argument("--limit", type=int, default=2)
    p_wl_enrich.add_argument("--force", action="store_true", help="Regenerate even if evidence hasn't changed")
    p_wl_enrich.set_defaults(func=cmd_work_logs_enrich)

    notion = sub.add_parser("notion", help="v2 Notion Projects cache status and reconciliation")
    notion_sub = notion.add_subparsers(dest="notion_command", required=True)
    notion_sub.add_parser("status", help="Cached-project matching breakdown and last refresh state").set_defaults(func=cmd_notion_status)
    p_notion_reconcile = notion_sub.add_parser("reconcile", help="Compare local Work Log state against real Notion pages (read-only unless --apply)")
    p_notion_reconcile.add_argument("--apply", action="store_true", help="Actually perform the safe, local-only repairs (never touches Notion itself)")
    p_notion_reconcile.set_defaults(func=cmd_notion_reconcile)
    p_notion_cutover = notion_sub.add_parser("cutover-check", help="GO/NO-GO preflight for making v2 the authoritative Work Log writer (read-only)")
    p_notion_cutover.add_argument("--limit", type=int, default=2000, help="Max Work Log pages to query from Notion (default 2000)")
    p_notion_cutover.set_defaults(func=cmd_notion_cutover_check)

    pause = sub.add_parser("pause", help="Pause activity interpretation while retaining filesystem state")
    pause_group = pause.add_mutually_exclusive_group()
    pause_group.add_argument("--minutes", type=float, default=None)
    pause_group.add_argument("--until-tomorrow", action="store_true")
    pause.set_defaults(func=cmd_pause)
    sub.add_parser("resume", help="Resume watching and reconcile local indexes").set_defaults(func=cmd_resume)

    p_recent = sub.add_parser("recent", help="List recent normalized events")
    p_recent.add_argument("--limit", type=int, default=30)
    p_recent.add_argument("--area", type=str, default=None, help="Filter by area_kind, e.g. projects")
    p_recent.add_argument("--all", action="store_true", help="Include non-meaningful (filtered) events")
    p_recent.set_defaults(func=cmd_recent)

    feed = sub.add_parser("feed", help="Read the human-readable Workspace activity timeline")
    feed.add_argument("--limit", type=int, default=50)
    feed.add_argument("--project-id")
    feed.add_argument("--kind")
    feed.set_defaults(func=cmd_activity_feed)
    folder_status = sub.add_parser("folder-status", help="Explain a derived folder status by path or watcher project ID")
    folder_status.add_argument("path")
    folder_status.set_defaults(func=cmd_folder_status)

    sub.add_parser("projects", help="List known projects").set_defaults(func=cmd_projects)
    index = sub.add_parser("index", help="Manage the local Finder project index")
    index_sub = index.add_subparsers(dest="index_command", required=True)
    index_sub.add_parser("rebuild", help="Rebuild from local folders and .project metadata").set_defaults(func=cmd_index_rebuild)
    p_issues = index_sub.add_parser("issues", help="List durable reconciliation findings")
    p_issues.add_argument("--state", default="open", choices=("open", "resolved", "ignored"))
    p_issues.set_defaults(func=cmd_index_issues)
    sub.add_parser("inbox", help="Show current Inbox/Unsorted snapshot").set_defaults(func=cmd_inbox)

    p_errors = sub.add_parser("errors", help="Show recent handler errors")
    p_errors.add_argument("--limit", type=int, default=20)
    p_errors.set_defaults(func=cmd_errors)
    sub.add_parser("doctor", help="Print a compact local installation/health diagnostic").set_defaults(func=cmd_doctor)

    health = sub.add_parser("health", help="Record/resolve explicit reliable build or test failure evidence")
    health_sub = health.add_subparsers(dest="health_command", required=True)
    failure = health_sub.add_parser("failure", help="Record a failed build/test command for a watcher project")
    failure.add_argument("project_id")
    failure.add_argument("summary")
    failure.add_argument("--command")
    failure.set_defaults(func=cmd_health_failure)
    resolved = health_sub.add_parser("resolve", help="Resolve explicit failure evidence for a watcher project")
    resolved.add_argument("project_id")
    resolved.set_defaults(func=cmd_health_resolve)

    startup = sub.add_parser("startup", help="Install and manage the native macOS login agents")
    startup_sub = startup.add_subparsers(dest="startup_command", required=True)
    install = startup_sub.add_parser("install", help="Enable login startup and start the background service")
    install.add_argument("--with-menubar", action="store_true", help="Also install the legacy rumps menu bar")
    install.add_argument("--no-menubar", action="store_true", help=argparse.SUPPRESS)  # the default now
    install.set_defaults(func=cmd_startup)
    restart = startup_sub.add_parser("restart", help="Restart installed agents")
    restart.set_defaults(func=cmd_startup)
    start_status = startup_sub.add_parser("status", help="Show LaunchAgent status")
    start_status.set_defaults(func=cmd_startup)
    stop = startup_sub.add_parser("stop", help="Stop agents but keep login startup installed")
    stop.add_argument("--watcher-only", action="store_true")
    stop.set_defaults(func=cmd_startup)
    disable = startup_sub.add_parser("disable", help="Stop agents and disable future login startup")
    disable.add_argument("--watcher-only", action="store_true")
    disable.set_defaults(func=cmd_startup)

    activity = sub.add_parser("activity", help="Inspect downstream activity intelligence")
    activity_sub = activity.add_subparsers(dest="activity_command", required=True)

    p_today = activity_sub.add_parser("today", help="Show deterministic daily activity summary")
    p_today.add_argument("--date", help="Local date, YYYY-MM-DD (default: today)")
    p_today.set_defaults(func=cmd_activity_today)

    p_sessions = activity_sub.add_parser("sessions", help="List inferred work sessions")
    p_sessions.add_argument("--date", help="Limit to sessions ending on/after local YYYY-MM-DD")
    p_sessions.add_argument("--all", action="store_true", help="Include short/discarded sessions")
    p_sessions.add_argument("--limit", type=int, default=50)
    p_sessions.set_defaults(func=cmd_activity_sessions)

    p_priorities = activity_sub.add_parser("priorities", help="Show cached Notion priority alignment")
    p_priorities.set_defaults(func=cmd_activity_priorities)

    p_switches = activity_sub.add_parser("switches", help="Show recorded fragmentation windows")
    p_switches.add_argument("--limit", type=int, default=20)
    p_switches.set_defaults(func=cmd_activity_switches)

    p_nudges = activity_sub.add_parser("nudges", help="Show fired and suppressed nudge decisions")
    p_nudges.add_argument("--limit", type=int, default=50)
    p_nudges.set_defaults(func=cmd_activity_nudges)

    p_refresh = activity_sub.add_parser("notion-refresh", help="Refresh the optional Notion Projects cache")
    p_refresh.set_defaults(func=cmd_activity_notion_refresh)

    p_snooze = activity_sub.add_parser("snooze", help="Temporarily suppress delivery while retaining telemetry")
    p_snooze.add_argument("--minutes", type=float, default=60.0)
    p_snooze.set_defaults(func=cmd_activity_snooze)

    sub.add_parser("lm-studio", help="Check the optional local LM Studio endpoint").set_defaults(func=cmd_lm_studio)

    relevance = sub.add_parser("relevance", help="Run/inspect downstream deterministic relevance")
    relevance_sub = relevance.add_subparsers(dest="relevance_command", required=True)
    p_project = relevance_sub.add_parser("project", help="Rank local/cached candidates for a project")
    p_project.add_argument("project_id", nargs="?", help="Project ID (defaults to active project)")
    p_project.add_argument("--dry-run", action="store_true", help="Do not persist the run or memory")
    p_project.set_defaults(func=cmd_relevance_run)
    p_active = relevance_sub.add_parser("active", help="Rank candidates for the active project")
    p_active.add_argument("--dry-run", action="store_true", help="Do not persist the run or memory")
    p_active.set_defaults(func=cmd_relevance_run, project_id=None)
    p_source = relevance_sub.add_parser("source-refresh", help="Refresh local/cached source index")
    p_source.set_defaults(func=cmd_relevance_refresh)
    p_history = relevance_sub.add_parser("history", help="List persisted relevance runs")
    p_history.add_argument("--limit", type=int, default=20)
    p_history.set_defaults(func=cmd_relevance_history)

    automation = sub.add_parser("automation", help="Inspect non-mutating project-detection decisions")
    automation_sub = automation.add_subparsers(dest="automation_command", required=True)
    p_pending = automation_sub.add_parser("pending", help="List pending project-detection decisions")
    p_pending.add_argument("--include-snoozed", action="store_true", help="Also show decisions snoozed for later")
    p_pending.set_defaults(func=cmd_automation_pending)
    p_resolve = automation_sub.add_parser("resolve", help="Record a local project-detection choice")
    p_resolve.add_argument("project_id")
    p_resolve.add_argument("status", choices=("existing_notion_project", "create_notion_project", "local_only", "ignored"))
    p_resolve.add_argument("--notion-project-id", help="Which existing project to link, for status=existing_notion_project")
    p_resolve.add_argument("--note")
    p_resolve.set_defaults(func=cmd_automation_resolve)
    p_snooze = automation_sub.add_parser("snooze", help="Ask again later instead of deciding now")
    p_snooze.add_argument("project_id")
    p_snooze.add_argument("--minutes", type=float, default=60.0, help="How long to wait before asking again (default: 60)")
    p_snooze.set_defaults(func=cmd_automation_snooze)

    intent = sub.add_parser("intent", help="Inspect/rebuild the intent-folder item index")
    intent_sub = intent.add_subparsers(dest="intent_command", required=True)
    intent_sub.add_parser("rebuild", help="Rebuild items from configured intent folders").set_defaults(func=cmd_intent_rebuild)
    intent_sub.add_parser("folders", help="List configured intent folders and item counts").set_defaults(func=cmd_intent_folders)

    items = sub.add_parser("items", help="Inspect and act on intent-folder items")
    items_sub = items.add_subparsers(dest="items_command", required=True)
    p_items_list = items_sub.add_parser("list", help="List indexed items")
    p_items_list.add_argument("--folder", default=None, help="Filter by intent folder name, e.g. 'For Inspiration'")
    p_items_list.add_argument("--all", action="store_true", help="Include items no longer present on disk")
    p_items_list.set_defaults(func=cmd_items_list)
    p_items_show = items_sub.add_parser("show", help="Show one item's metadata and tags")
    p_items_show.add_argument("item_id")
    p_items_show.set_defaults(func=cmd_items_show)
    p_items_tag = items_sub.add_parser("tag", help="Add user tags to an item (writes .item.toml)")
    p_items_tag.add_argument("item_id")
    p_items_tag.add_argument("--add", action="append", required=True, help="Tag to add; repeatable")
    p_items_tag.set_defaults(func=cmd_items_tag)
    p_items_open = items_sub.add_parser("open", help="Open an item in Finder and mark it reviewed")
    p_items_open.add_argument("item_id")
    p_items_open.set_defaults(func=cmd_items_open)
    p_items_useful = items_sub.add_parser("useful", help="Record that an item was useful for a project")
    p_items_useful.add_argument("item_id")
    p_items_useful.add_argument("--project", default=None, help="Project ID (defaults to the active project)")
    p_items_useful.set_defaults(func=cmd_items_useful)
    p_items_not_related = items_sub.add_parser("not-related", help="Stop suggesting an item for one project")
    p_items_not_related.add_argument("item_id")
    p_items_not_related.add_argument("--project", default=None)
    p_items_not_related.set_defaults(func=cmd_items_not_related)
    p_items_defer = items_sub.add_parser("defer", help="Defer an item for one project")
    p_items_defer.add_argument("item_id")
    p_items_defer.add_argument("--project", default=None)
    defer_group = p_items_defer.add_mutually_exclusive_group(required=True)
    defer_group.add_argument("--next-session", action="store_true", help="Show again once this project has a new work session")
    defer_group.add_argument("--tomorrow", action="store_true")
    defer_group.add_argument("--days", type=float, default=None)
    defer_group.add_argument("--until", help="Absolute date/time, e.g. 2027-10-10")
    p_items_defer.set_defaults(func=cmd_items_defer)
    p_items_archive = items_sub.add_parser("archive", help="Move an item to its configured archive destination")
    p_items_archive.add_argument("item_id")
    p_items_archive.add_argument("--project", default=None, help="Project to log the decision against, if any")
    p_items_archive.add_argument("--destination", default=None, help="Override the folder's configured archive_destination")
    p_items_archive.add_argument("--confirm", action="store_true", help="Required for folders with requires_confirmation=true")
    p_items_archive.set_defaults(func=cmd_items_archive)

    tags = sub.add_parser("tags", help="Query the tag registry")
    tags_sub = tags.add_subparsers(dest="tags_command", required=True)
    p_tags_search = tags_sub.add_parser("search", help="Search tags by substring")
    p_tags_search.add_argument("query")
    p_tags_search.set_defaults(func=cmd_tags_search)
    p_tags_related = tags_sub.add_parser("related", help="Tags that co-occur with the given tag")
    p_tags_related.add_argument("tag")
    p_tags_related.set_defaults(func=cmd_tags_related)

    context = sub.add_parser("context", help="Stable local context API for agents")
    context_sub = context.add_subparsers(dest="context_command", required=True)
    context_sub.add_parser("current", help="Active project and items due for review").set_defaults(func=cmd_context_current)
    p_context_project = context_sub.add_parser("project", help="Recent activity and decisions for one project")
    p_context_project.add_argument("project_id")
    p_context_project.set_defaults(func=cmd_context_project)

    p_inspiration = sub.add_parser("inspiration", help="Contextual resurfacing shortcuts")
    inspiration_sub = p_inspiration.add_subparsers(dest="inspiration_command", required=True)
    p_inspiration_suggest = inspiration_sub.add_parser("suggest", help="Show contextual intent-folder matches for a project")
    p_inspiration_suggest.add_argument("project_id", nargs="?", help="Defaults to the active project")
    p_inspiration_suggest.add_argument("--dry-run", action="store_true")
    p_inspiration_suggest.set_defaults(func=cmd_inspiration_suggest)

    reminders = sub.add_parser("reminders", help="Deterministic reminder/condition engine")
    reminders_sub = reminders.add_subparsers(dest="reminders_command", required=True)
    reminders_sub.add_parser("due", help="List items whose after/defer/inactivity condition is due").set_defaults(func=cmd_reminders_due)

    worklog = sub.add_parser("worklog", help="Work Log drafts and manual entries")
    worklog_sub = worklog.add_subparsers(dest="worklog_command", required=True)
    p_worklog_add = worklog_sub.add_parser("add", help="Append a manual Work Log entry")
    p_worklog_add.add_argument("project_id")
    p_worklog_add.add_argument("summary")
    p_worklog_add.set_defaults(func=cmd_worklog_add)
    p_worklog_recent = worklog_sub.add_parser("recent", help="Recent Work Log drafts and manual entries for a project")
    p_worklog_recent.add_argument("project_id")
    p_worklog_recent.add_argument("--limit", type=int, default=20)
    p_worklog_recent.set_defaults(func=cmd_worklog_recent)

    sub.add_parser("menubar", help="Launch the optional menu bar UI (requires the 'rumps' extra)").set_defaults(func=cmd_menubar)

    return parser


def main(argv: list[str] | None = None) -> int:
    # ``core`` is retained as a short-lived CLI spelling; the live command is
    # now the ordinary ``run`` entry point above.
    effective_argv = sys.argv[1:] if argv is None else argv
    if effective_argv and effective_argv[0] == "core":
        from .core_cli import main as core_main
        return core_main(effective_argv[1:])
    if effective_argv and effective_argv[0] == "core-api":
        from .core_api import serve
        from .core_config import load_core_config
        api_parser = argparse.ArgumentParser(prog="workspace-watcher core-api")
        api_parser.add_argument("--config", type=Path)
        api_parser.add_argument("--workspace-root", type=Path)
        api_parser.add_argument("--port", type=int, default=8765)
        api_args = api_parser.parse_args(effective_argv[1:])
        server = serve(load_core_config(api_args.config, api_args.workspace_root), port=api_args.port)
        server.serve_forever()
        return 0
    parser = build_parser()
    args = parser.parse_args(effective_argv)
    try:
        return args.func(args)
    except ValueError as exc:
        parser.error(str(exc))
        return 2  # pragma: no cover - argparse exits


if __name__ == "__main__":
    sys.exit(main())
