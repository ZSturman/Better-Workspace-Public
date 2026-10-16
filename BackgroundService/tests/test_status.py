from __future__ import annotations

import logging
import time

from workspace_watcher.config import default_config
from workspace_watcher.finder_tags import PREFIX, apply_status_tag, read_tags
from workspace_watcher.status import StatusEngine
from workspace_watcher.store import WorkspaceStore


def test_status_precedence_reasons_and_failure_recovery(tmp_path):
    (tmp_path / "Projects" / "Alpha").mkdir(parents=True)
    config = default_config(tmp_path)
    config.status.apply_finder_tags = False
    config.status.error_failure_threshold = 3
    store = WorkspaceStore(config.db_path)
    now = time.time()
    store.create_project("alpha", "Projects/Alpha", "Alpha", None, None, now)
    store.set_state("active_project", {"project_id": "alpha", "project_name": "Alpha", "since": now})
    for number in range(3):
        store.record_project_signal(f"failure-{number}", "alpha", "failure", "error", "pytest failed", {}, now)

    StatusEngine(store, config, logging.getLogger("test")).tick(now)
    row = store.folder_statuses(project_id="alpha")[0]
    assert row["status"] == "error"
    assert "3 unresolved failure" in row["reasons_json"]

    store.resolve_project_signals("alpha", "failure", now)
    StatusEngine(store, config, logging.getLogger("test")).tick(now + 1)
    assert store.folder_statuses(project_id="alpha")[0]["status"] == "active"
    store.close()


def test_finder_tags_preserve_manual_tags_and_replace_only_owned_tag(tmp_path, monkeypatch):
    # These xattr APIs work in-memory under test, avoiding filesystem support
    # differences while exercising the exact Finder plist representation.
    import plistlib
    import workspace_watcher.finder_tags as finder_tags

    target = tmp_path / "Folder"
    target.mkdir()
    values: dict[str, bytes] = {}
    monkeypatch.setattr(finder_tags, "_read_xattr", lambda _path: values["com.apple.metadata:_kMDItemUserTags"])
    monkeypatch.setattr(finder_tags, "_write_xattr", lambda _path, value: values.__setitem__("com.apple.metadata:_kMDItemUserTags", value))
    values["com.apple.metadata:_kMDItemUserTags"] = plistlib.dumps(["Manual Tag\n4", "WW: Stale\n1"], fmt=plistlib.FMT_BINARY)

    assert apply_status_tag(target, "error")
    tags = read_tags(target)
    assert "Manual Tag\n4" in tags
    assert [tag for tag in tags if tag.startswith(PREFIX)] == ["WW: Error\n6"]


def test_projects_rollup_does_not_treat_its_own_previous_error_as_project_error(tmp_path):
    (tmp_path / "Projects").mkdir()
    config = default_config(tmp_path)
    config.status.apply_finder_tags = False
    store = WorkspaceStore(config.db_path)
    now = time.time()
    store.upsert_folder_status("Projects", None, "error", [{"message": "old rollup"}], now)
    StatusEngine(store, config, logging.getLogger("test")).tick(now + 1)
    root = next(row for row in store.folder_statuses() if row["path"] == "Projects")
    assert root["status"] == "normal"
    store.close()
