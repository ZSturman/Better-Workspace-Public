"""Operational CLI for the replacement core."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any

from .core_config import load_core_config
from .core_engine import IntentIndexer
from .core_store import CoreStore
from .intents import IntentFolderDetector
from .private_items import initialize_record


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="workspace-watcher")
    parser.add_argument("--config", type=Path)
    parser.add_argument("--workspace-root", type=Path)
    sub = parser.add_subparsers(dest="command", required=True)
    intents = sub.add_parser("intents"); intent_sub = intents.add_subparsers(dest="intent_command", required=True)
    intent_sub.add_parser("scan").add_argument("--initialize-items", action="store_true")
    explain = intent_sub.add_parser("explain"); explain.add_argument("path", type=Path)
    items = sub.add_parser("items"); item_sub = items.add_subparsers(dest="item_command", required=True)
    init = item_sub.add_parser("init"); init.add_argument("path", type=Path); init.add_argument("--title")
    item_sub.add_parser("list")
    retire = item_sub.add_parser("retire-sidecars", help="Archive legacy item sidecars in SQLite, then remove them (dry run by default; stop the service first)")
    retire.add_argument("--apply", action="store_true")
    retire.add_argument("--include-unindexed", action="store_true", help="also inventory former item sidecars throughout configured roots, pruning dependencies and foreign stores")
    events = sub.add_parser("events"); events.add_argument("--limit", type=int, default=30)
    sub.add_parser("doctor")
    sessions = sub.add_parser("sessions"); session_sub = sessions.add_subparsers(dest="session_command", required=True)
    automation = session_sub.add_parser("classify-automation", help="Mark sessions made only of bulk filesystem runs across many projects (dry run unless --apply; backs up first)")
    automation.add_argument("--apply", action="store_true")
    automation.add_argument("--since", help="only sessions activated at or after this ISO time (default: all history)")
    automation.add_argument("--backup-dir", type=Path, help="default: a backups folder beside the database")
    backfill = sub.add_parser("worklog-backfill", help="Rebuild missed Work Log history from surviving local journals (dry run unless --apply)")
    backfill.add_argument("--from", dest="start", required=True, help="first local day, YYYY-MM-DD")
    backfill.add_argument("--to", dest="end", required=True, help="last local day, YYYY-MM-DD (inclusive)")
    backfill.add_argument("--apply", action="store_true", help="write the reconstructed sessions and drafts")
    backfill.add_argument("--filesystem-journal", type=Path, action="append", help="default: Hammerspoon's journals")
    backfill.add_argument("--terminal-journal", type=Path, action="append", help="default: the zsh hook's journals")
    backfill.add_argument("--timezone", help="IANA zone for day boundaries (default: this Mac's)")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    config = load_core_config(args.config, args.workspace_root)
    detector = IntentFolderDetector(config.intent_settings)
    if args.command == "intents" and args.intent_command == "explain":
        print(json.dumps(detector.explain(args.path).to_dict(), indent=2)); return 0
    if args.command == "items" and args.item_command == "init":
        directory = args.path.expanduser()
        if not directory.is_dir() or directory.is_symlink():
            raise ValueError("item init requires an existing directory")
        directory = directory.resolve()
        with CoreStore(config.database_path) as store:
            record = initialize_record(store, directory, title=args.title)
        print(record.id); return 0
    if args.command == "doctor":
        print(json.dumps({"workspace_root": str(config.workspace_root), "database": str(config.database_path), "search_roots": [str(root) for root in detector.settings.search_roots], "found_intents": len(list(detector.discover()))}, indent=2)); return 0
    if args.command == "worklog-backfill":
        return _worklog_backfill(args, config)
    if args.command == "sessions" and args.session_command == "classify-automation":
        return _classify_automation(args, config)
    with CoreStore(config.database_path) as store:
        if args.command == "intents":
            print(json.dumps(IntentIndexer(detector, store).rebuild(initialize_missing_metadata=args.initialize_items), indent=2)); return 0
        if args.command == "items" and args.item_command == "retire-sidecars":
            from .sidecar_retirement import retire_sidecars
            print(json.dumps(retire_sidecars(store, detector, apply=args.apply, include_unindexed=args.include_unindexed), indent=2)); return 0
        if args.command == "items":
            print(json.dumps([dict(row) for row in store.items()], indent=2)); return 0
        if args.command == "events":
            print(json.dumps([dict(row) for row in store.recent_events(args.limit)], indent=2)); return 0
    return 1


def _classify_automation(args: argparse.Namespace, config: Any) -> int:
    import sqlite3
    from datetime import datetime, timedelta, timezone
    from .session_automation import apply_classification
    with CoreStore(config.database_path) as store:
        backup = None
        if args.apply:
            # A verified copy of every session and draft before anything changes.
            directory = (args.backup_dir or Path(config.database_path).parent / "backups").expanduser()
            directory.mkdir(parents=True, exist_ok=True)
            backup = directory / f"core-before-automation-{datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')}.db"
            with sqlite3.connect(backup) as target:
                store.conn.backup(target)
                if target.execute("PRAGMA integrity_check").fetchone()[0] != "ok":
                    raise RuntimeError(f"backup {backup} failed its integrity check; nothing was changed")
        settled = (datetime.now(timezone.utc) - timedelta(seconds=180)).isoformat()
        report = apply_classification(store, since=args.since, settled_before=settled, apply=args.apply)
        report["backup"] = str(backup) if backup else None
        print(json.dumps(report, indent=2))
    return 0


def _worklog_backfill(args: argparse.Namespace, config: Any) -> int:
    from datetime import date
    from .work_logs_v2 import WorkLogGenerator
    from .worklog_backfill import WorkLogBackfill, default_journals
    fs_default, terminal_default = default_journals()
    with CoreStore(config.database_path) as store:
        backfill = WorkLogBackfill(
            store, config,
            filesystem_journals=args.filesystem_journal or fs_default,
            terminal_journals=args.terminal_journal or terminal_default,
            timezone_name=args.timezone,
        )
        result = backfill.plan(date.fromisoformat(args.start), date.fromisoformat(args.end))
        if args.apply:
            backfill.apply(result, WorkLogGenerator(store, config.work_logs, config.notion, config.workspace_root))
        print(json.dumps(result.summary(), indent=2))
    return 0
