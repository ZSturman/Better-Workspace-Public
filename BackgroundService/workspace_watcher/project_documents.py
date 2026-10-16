"""Project-local Better Projects document manifests.

``Project.betterproject`` is deliberately a small, human-inspectable JSON
document that lives beside a project's source.  It is the durable bridge from
the workspace-level index to Better Projects: a Finder double-click or native
open operation goes to this file, not through a global project-list URL.
"""

from __future__ import annotations

import json
import os
import tempfile
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

DOCUMENT_FILENAME = "Project.betterproject"
FORMAT_VERSION = 1


def document_path(directory: Path) -> Path:
    return directory / DOCUMENT_FILENAME


def read_document(directory: Path) -> dict[str, Any] | None:
    """Return a valid document manifest, never treating malformed JSON as a
    record we can safely overwrite.  The caller can surface it as a local
    repair issue while continuing to index the containing directory.
    """
    path = document_path(directory)
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None
    if not isinstance(value, dict) or value.get("formatVersion") != FORMAT_VERSION:
        return None
    # Better Projects can create a document before Workspace Watcher has ever
    # seen its directory. In that legitimate standalone state the workspace
    # identity is JSON `null`; the watcher must adopt it on the next scan
    # rather than mistaking it for corruption and refusing to reconcile.
    workspace_project_id = value.get("workspaceProjectID")
    if not isinstance(value.get("documentID"), str) or (workspace_project_id is not None and not isinstance(workspace_project_id, str)):
        return None
    return value


def ensure_document(
    directory: Path,
    *,
    workspace_project_id: str,
    title: str,
    notion_project_id: str | None,
) -> Path:
    """Create or conservatively refresh a manifest without touching its
    document identity or user-selected section.  A rename updates only the
    directory association; a missing Notion cache never clears a known link.
    """
    path = document_path(directory)
    existing = read_document(directory)
    now = _now()
    if existing is None and path.exists():
        # A corrupt file is still the user's project document. Do not replace
        # it with a fresh identity and silently sever its recovery path.
        return path

    record: dict[str, Any] = existing or {
        "formatVersion": FORMAT_VERSION,
        "documentID": str(uuid.uuid4()),
        "workspaceProjectID": workspace_project_id,
        "notionProjectID": notion_project_id,
        "title": title,
        "projectDirectoryPath": str(directory.resolve()),
        "selectedSection": "project",
        "createdAt": now,
        "updatedAt": now,
    }
    changed = existing is None
    if existing is not None:
        if record.get("workspaceProjectID") != workspace_project_id:
            # The index generated this document and owns its filesystem ID;
            # retain the document ID/other local state while reconciling it.
            record["workspaceProjectID"] = workspace_project_id
            changed = True
        resolved_path = str(directory.resolve())
        if record.get("projectDirectoryPath") != resolved_path:
            record["projectDirectoryPath"] = resolved_path
            changed = True
        if notion_project_id and record.get("notionProjectID") != notion_project_id:
            record["notionProjectID"] = notion_project_id
            changed = True
        if not str(record.get("title") or "").strip():
            record["title"] = title
            changed = True
    if changed:
        record["updatedAt"] = now
        _atomic_write(path, record)
    return path


def _atomic_write(path: Path, record: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", suffix=".tmp", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(record, handle, indent=2, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary_name, path)
    finally:
        try:
            os.unlink(temporary_name)
        except FileNotFoundError:
            pass


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()
