"""GO/NO-GO preflight for making v2 the sole active Work Log writer -- see
the cutover section in docs/v2-work-log-system.md.

This never changes any setting and never writes to Notion. It answers one
question with specific, actionable blockers: "if a human flipped
`authoritative_writer = 'v2'` and `notion_sync = true` right now, is v2's
OWN state ready for that?" It checks v2's operational readiness going
forward -- can it reach and write the real Notion schema, and is its own
local state already internally consistent -- not whether historical Notion
pages from other systems have been accounted for. v2 does not need to know
about, import, or reconcile against any other system's past output to
safely start writing its own new Work Logs; it only needs its own
identity/dedup scheme (deterministic `_draft_id`, self-healing
`notion_page_id` reuse -- see `work_logs_v2.py`) to be sound, which
`reconciliation_v2.py` already verifies against live Notion.
"""

from __future__ import annotations

from pathlib import Path
from typing import Any

from .core_config import NotionSettings, WorkLogsSettings
from .core_store import CoreStore
from .reconciliation_v2 import reconcile_work_logs
from .work_logs_v2 import NotionWorkLogSync


def cutover_preflight(
    store: CoreStore,
    workspace_root: Path,
    notion_settings: NotionSettings,
    work_logs_settings: WorkLogsSettings,
    *,
    sync: NotionWorkLogSync | None = None,
    query_limit: int = 500,
) -> dict[str, Any]:
    sync = sync or NotionWorkLogSync(store, workspace_root, notion_settings)
    report: dict[str, Any] = {"go": False, "blockers": [], "warnings": [], "checks": {}}

    if not notion_settings.enabled:
        report["blockers"].append("[workspace_watcher.notion].enabled is false -- v2 cannot even read the live Work Log schema/pages.")
        report["checks"]["notion_enabled"] = False
        return report
    report["checks"]["notion_enabled"] = True

    if not work_logs_settings.enabled:
        report["blockers"].append("[workspace_watcher.work_logs].enabled is false -- v2 Work Log generation itself is off.")
    report["checks"]["work_logs_enabled"] = work_logs_settings.enabled

    if work_logs_settings.notion_sync:
        report["warnings"].append("notion_sync is already true -- this preflight is meant to be run BEFORE that flip.")
    if work_logs_settings.authoritative_writer == "v2":
        report["warnings"].append("authoritative_writer is already 'v2' -- this preflight is meant to be run BEFORE that flip.")

    reconcile_report = reconcile_work_logs(store, workspace_root, notion_settings, sync=sync, query_limit=query_limit)
    report["checks"]["reconciliation"] = reconcile_report
    if reconcile_report["error"]:
        report["blockers"].append(f"Could not reach/read the live Work Log schema: {reconcile_report['error']}")
    else:
        if reconcile_report["local_synced_missing_in_notion"]:
            report["blockers"].append(f"{len(reconcile_report['local_synced_missing_in_notion'])} local draft(s) claim a synced Notion page that no longer exists.")
        if reconcile_report["local_page_id_mismatch"]:
            report["blockers"].append(f"{len(reconcile_report['local_page_id_mismatch'])} local draft(s) point at the wrong Notion page id.")
        if reconcile_report["notion_duplicate_hashes"]:
            report["blockers"].append(f"{len(reconcile_report['notion_duplicate_hashes'])} v2 event_hash value(s) already have duplicate Notion pages.")
        if reconcile_report["notion_orphan_pages"]:
            report["warnings"].append(f"{len(reconcile_report['notion_orphan_pages'])} Notion page(s) carry a v2-shaped event_hash with no matching local draft.")
        if reconcile_report["local_sync_failed"]:
            report["warnings"].append(f"{len(reconcile_report['local_sync_failed'])} local draft(s) are in sync_failed state already.")

    report["go"] = not report["blockers"]
    return report
