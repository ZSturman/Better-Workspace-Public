"""Read-only comparison between local Work Log state and the real Notion
Work Log database, plus a small set of *local-only*, safe repair actions.

This never deletes or mutates a Notion page. The only "repair" actions
available touch local SQLite state alone (reset a draft's status so
`sync_pending` retries it, or correct a locally-cached `notion_page_id` to
match what Notion's own event_hash-tagged page actually is) -- both are
fully reversible and never risk creating or destroying Notion content.

Safe to run at any time, independent of `notion_sync` -- it only ever reads
from Notion (`data_source`, `query`), even when reconciliation finds
something to report.
"""

from __future__ import annotations

from pathlib import Path
from typing import Any

from .core_config import NotionSettings
from .core_engine import utc_now
from .core_store import CoreStore
from .notion_client_v2 import NotionCacheError, _property_value
from .work_logs_v2 import NotionWorkLogSync


def reconcile_work_logs(store: CoreStore, workspace_root: Path, settings: NotionSettings, *, sync: NotionWorkLogSync | None = None, query_limit: int = 500) -> dict[str, Any]:
    """Compares local ``work_log_drafts`` against the live Notion Work Log
    database via each page's ``event_hash`` property (the same dedup key
    ``NotionWorkLogSync`` already writes and self-heals against -- see
    ``work_logs_v2.py``'s ``_find_existing_page_by_hash``).

    ``query_limit`` bounds a single, unpaginated query -- a best-effort
    reconciliation pass, not a guarantee of seeing every page in a very
    large database. Good enough for "does anything look wrong," not a
    substitute for Notion's own UI for a full audit.
    """
    sync = sync or NotionWorkLogSync(store, workspace_root, settings)
    report: dict[str, Any] = {
        "local_pending": [], "local_sync_failed": [], "local_synced_missing_in_notion": [],
        "local_page_id_mismatch": [], "notion_duplicate_hashes": [], "notion_orphan_pages": [],
        "queried_pages": 0, "error": None,
    }
    try:
        client = sync.adapter._client()
        source_id = client.data_source_id(settings.work_log_database_id)
        source = client.data_source(source_id)
        try:
            from .notion_api import SchemaMap
        except Exception as exc:  # pragma: no cover - covered through adapter failure in normal use
            raise NotionCacheError(f"Existing Work Log schema helpers unavailable: {exc}") from exc
        schema = SchemaMap(source)
    except NotionCacheError as exc:
        report["error"] = str(exc)
        return report

    event_hash_ref = schema.find(("event_hash", "event hash"), ("rich_text",))
    if event_hash_ref is None:
        report["error"] = "Work Log schema has no event_hash-like field to reconcile against"
        return report

    local_drafts = {row["id"]: dict(row) for row in store.work_log_drafts(limit=10000)}
    for draft_id, draft in local_drafts.items():
        if draft["status"] == "prepared":
            report["local_pending"].append(draft_id)
        elif draft["status"] == "sync_failed":
            report["local_sync_failed"].append(draft_id)

    try:
        pages = client.query(source_id, limit=query_limit)
    except Exception as exc:  # noqa: BLE001 - reconciliation must report, never crash the caller
        report["error"] = f"Could not query the Work Log database: {exc}"
        return report
    report["queried_pages"] = len(pages)

    by_hash: dict[str, list[str]] = {}
    for page in pages:
        properties = page.get("properties") if isinstance(page.get("properties"), dict) else {}
        raw = properties.get(event_hash_ref.name)
        hash_value = _property_value(raw) if raw else None
        if isinstance(hash_value, str) and hash_value.startswith("worklog-"):
            by_hash.setdefault(hash_value, []).append(str(page.get("id") or ""))

    for hash_value, page_ids in by_hash.items():
        if len(page_ids) > 1:
            report["notion_duplicate_hashes"].append({"event_hash": hash_value, "page_ids": page_ids})
        if hash_value not in local_drafts:
            report["notion_orphan_pages"].append({"event_hash": hash_value, "page_ids": page_ids})

    for draft_id, draft in local_drafts.items():
        if draft["status"] != "synced":
            continue
        pages_for_hash = by_hash.get(draft_id, [])
        if not pages_for_hash:
            report["local_synced_missing_in_notion"].append(draft_id)
        elif draft["notion_page_id"] not in pages_for_hash:
            report["local_page_id_mismatch"].append({"draft_id": draft_id, "local_page_id": draft["notion_page_id"], "notion_page_ids": pages_for_hash})

    return report


def repair_local_state(store: CoreStore, report: dict[str, Any], *, dry_run: bool = True) -> dict[str, Any]:
    """The only two repair actions available, both local-only and fully
    reversible:

    - ``local_synced_missing_in_notion``: the local draft thinks it's
      synced, but no matching page exists in Notion (e.g. the page was
      deleted, or a write never actually landed). Reset to ``prepared`` so
      the ordinary `sync_pending` retry path creates it fresh next tick.
    - ``local_page_id_mismatch``: a matching page *does* exist by hash, just
      under a different id than the one cached locally (e.g. the crash
      window `NotionWorkLogSync` already guards against, caught after the
      fact instead of at sync time). Correct the local id to match.

    Never touches Notion itself. ``dry_run=True`` (the default) only
    reports what *would* change."""
    actions: list[dict[str, Any]] = []
    now = utc_now()
    for draft_id in report.get("local_synced_missing_in_notion", []):
        actions.append({"action": "reset_to_prepared", "draft_id": draft_id})
        if not dry_run:
            store.reset_work_log_draft_page(draft_id, notion_page_id=None, status="prepared", timestamp=now)
    for item in report.get("local_page_id_mismatch", []):
        corrected = item["notion_page_ids"][0]
        actions.append({"action": "correct_local_page_id", "draft_id": item["draft_id"], "from": item["local_page_id"], "to": corrected})
        if not dry_run:
            store.reset_work_log_draft_page(item["draft_id"], notion_page_id=corrected, status="synced", timestamp=now)
    return {"dry_run": dry_run, "actions": actions}
