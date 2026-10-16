from __future__ import annotations

import json
from datetime import datetime, timezone

from workspace_watcher.core_config import CoreConfig
from workspace_watcher.core_store import CoreStore
from workspace_watcher.intents import IntentFolderSettings
from workspace_watcher.widget_snapshot import WidgetSnapshotPublisher, build_widget_snapshot


def _config(root):
    return CoreConfig(root, root / "Logs/workspace-watcher/core.db", IntentFolderSettings.for_workspace(root), root / "config.toml", root / "rules.toml")


def test_widget_projection_uses_authoritative_models_and_is_compact(tmp_path):
    config = _config(tmp_path)
    with CoreStore(config.database_path) as store:
        store.create_project(project_id="project-1", path="Projects/Alpha", root_path="Projects", name="Alpha", device=1, inode=1, timestamp="2026-01-01T00:00:00+00:00")
        store.set_project_domain("project-1", "Software", "2026-01-01T00:00:00+00:00")
        store.replace_project_goals("project-1", ["Ship widgets"], session_id=None, source="test", timestamp="2026-01-01T00:00:00+00:00")
        store.set_state("watcher.health", {"state": "running"}, "2026-01-01T00:00:00+00:00")
        snapshot = build_widget_snapshot(store, now=datetime(2026, 1, 2, tzinfo=timezone.utc))

    assert snapshot["schema_version"] == 1
    assert snapshot["projects"][0]["name"] == "Alpha"
    assert snapshot["projects"][0]["next_action"] == "Ship widgets"
    assert snapshot["health"]["watcher_state"] == "running"
    assert "path" in snapshot["projects"][0]  # deep-link identity remains available
    assert "metadata_json" not in json.dumps(snapshot)  # no raw SQLite payload leaks into widgets


def test_widget_snapshot_write_is_atomic_and_coalesces_unchanged_state(tmp_path):
    config = _config(tmp_path)
    destination = tmp_path / "group" / "widget-snapshot.json"
    with CoreStore(config.database_path) as store:
        publisher = WidgetSnapshotPublisher(destination)
        assert publisher.publish(store, now=datetime(2026, 1, 1, tzinfo=timezone.utc))
        assert destination.exists()
        assert not destination.with_suffix(".tmp").exists()
        assert not publisher.publish(store, now=datetime(2026, 1, 1, 0, 1, tzinfo=timezone.utc))
    payload = json.loads(destination.read_text())
    assert payload["schema_version"] == 1


def test_projects_are_ordered_by_recent_activity_before_truncation(tmp_path):
    """Every widget reads the front of this list, so an unordered list is not
    cosmetic: truncating a real 383-project portfolio to 50 without sorting
    made "what should I work on?" answer with whatever came alphabetically
    first -- `_Articles`, `_Closed` -- none of which had ever been worked on."""
    from workspace_watcher.widget_snapshot import _by_recent_activity

    projects = [
        {"name": "_Articles", "days_since_last_session": None},
        {"name": "Zulu", "days_since_last_session": 0.5},
        {"name": "Mike", "days_since_last_session": 12.0},
        {"name": "_Closed", "days_since_last_session": None},
        {"name": "Alpha", "days_since_last_session": 3.0},
    ]
    assert [p["name"] for p in _by_recent_activity(projects)] == ["Zulu", "Alpha", "Mike", "_Articles", "_Closed"]


def test_never_worked_on_projects_sort_last_and_tie_by_name():
    """"Never touched" must never outrank real work, whichever direction the
    list is read, and must stay stably ordered between refreshes."""
    from workspace_watcher.widget_snapshot import _by_recent_activity

    projects = [
        {"name": "Beta", "days_since_last_session": None},
        {"name": "alpha", "days_since_last_session": None},
        {"name": "Worked", "days_since_last_session": 400.0},
    ]
    assert [p["name"] for p in _by_recent_activity(projects)] == ["Worked", "alpha", "Beta"]
