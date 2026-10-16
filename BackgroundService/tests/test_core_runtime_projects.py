"""v2 project detection wired into the live runtime: existence reconciliation
(_reconcile -> ProjectRegistry.rebuild) and live activation (_on_settled ->
_detect_active_project), including a rule firing off project.activated."""

from __future__ import annotations

import time
from pathlib import Path

from workspace_watcher.coalescer import Settled
from workspace_watcher.core_config import CoreConfig, HammerspoonInboxSettings, ProjectsSettings
from workspace_watcher.core_runtime import CoreRuntime
from workspace_watcher.intents import IntentFolderSettings


def _runtime(root: Path, *, projects_enabled: bool = True) -> CoreRuntime:
    config = CoreConfig(
        root, root / "Logs/workspace-watcher/core.db", IntentFolderSettings.for_workspace(root),
        root / "config.toml", root / "rules.toml", 0.1,
        HammerspoonInboxSettings(enabled=False, path=root / "inbox.jsonl"),
        ProjectsSettings(enabled=projects_enabled, root="Projects"),
    )
    return CoreRuntime(config)


def _settled(path: str) -> Settled:
    return Settled(kind="created", path=path, prev_path=None, is_directory=False, raw_event_count=1, ts=time.time())


def test_on_settled_activates_the_touched_project_and_fires_a_rule(tmp_path):
    root = tmp_path / "workspace"
    (root / "Projects" / "Foo").mkdir(parents=True)
    rules_path = root / "rules.toml"
    rules_path.write_text(
        """
[[rules]]
id = "project-activated"
enabled = true
[rules.when]
event = "project.activated"
[[rules.actions]]
type = "notification"
notification_type = "information"
title = "Now working on a project"
""".strip()
    )
    runtime = _runtime(root)
    runtime.reload_rules()

    runtime._on_settled(_settled("Projects/Foo/main.py"))

    current = runtime.store.get_state("project.current")
    assert current is not None and current["name"] == "Foo" and current["path"] == "Projects/Foo"
    assert [row["name"] for row in runtime.store.projects()] == ["Foo"]
    notifications = runtime.store.notifications()
    assert len(notifications) == 1 and notifications[0]["title"] == "Now working on a project"


def test_second_change_in_the_same_project_does_not_re_fire(tmp_path):
    root = tmp_path / "workspace"
    (root / "Projects" / "Foo").mkdir(parents=True)
    runtime = _runtime(root)
    runtime.reload_rules()

    runtime._on_settled(_settled("Projects/Foo/main.py"))
    activated_events = [row for row in runtime.store.recent_events(50) if row["type"] == "project.activated"]
    assert len(activated_events) == 1

    runtime._on_settled(_settled("Projects/Foo/other.py"))
    activated_events_after = [row for row in runtime.store.recent_events(50) if row["type"] == "project.activated"]
    assert len(activated_events_after) == 1  # still the same project -- no duplicate activation


def test_switching_to_a_different_project_activates_the_new_one(tmp_path):
    root = tmp_path / "workspace"
    (root / "Projects" / "Foo").mkdir(parents=True)
    (root / "Projects" / "Bar").mkdir(parents=True)
    runtime = _runtime(root)
    runtime.reload_rules()

    runtime._on_settled(_settled("Projects/Foo/main.py"))
    assert runtime.store.get_state("project.current")["name"] == "Foo"

    runtime._on_settled(_settled("Projects/Bar/main.py"))
    assert runtime.store.get_state("project.current")["name"] == "Bar"
    activated_events = [row for row in runtime.store.recent_events(50) if row["type"] == "project.activated"]
    assert len(activated_events) == 2


def test_restart_after_a_rename_reconciles_identity_without_duplicating(tmp_path):
    # The directory is renamed while nothing is running (no runtime
    # instance alive to see it happen live) -- a fresh CoreRuntime built
    # against the same on-disk store must still recognize it as the SAME
    # project via startup reconciliation (_reconcile("startup"), called
    # from start()), not discover a duplicate.
    root = tmp_path / "workspace"
    (root / "Projects" / "Foo").mkdir(parents=True)
    runtime1 = _runtime(root)
    runtime1.reload_rules()
    runtime1._on_settled(_settled("Projects/Foo/main.py"))
    original_id = runtime1.store.projects()[0]["id"]
    assert runtime1.store.get_state("project.current")["name"] == "Foo"

    (root / "Projects" / "Foo").rename(root / "Projects" / "Renamed")

    runtime2 = _runtime(root)
    runtime2._reconcile("startup")  # what start() calls before spinning up real watcher threads

    rows = runtime2.store.projects()
    assert len(rows) == 1
    assert rows[0]["id"] == original_id
    assert rows[0]["name"] == "Renamed"

    # Touching the renamed directory re-activates the same identity, not a new one.
    runtime2._on_settled(_settled("Projects/Renamed/main.py"))
    current = runtime2.store.get_state("project.current")
    assert current["project_id"] == original_id and current["name"] == "Renamed"


def test_a_rename_while_the_project_stays_current_refreshes_the_name_without_a_new_activation(tmp_path):
    root = tmp_path / "workspace"
    (root / "Projects" / "Foo").mkdir(parents=True)
    runtime = _runtime(root)
    runtime.reload_rules()
    runtime._on_settled(_settled("Projects/Foo/main.py"))
    project_id = runtime.store.get_state("project.current")["project_id"]

    (root / "Projects" / "Foo").rename(root / "Projects" / "Renamed")
    runtime._on_settled(_settled("Projects/Renamed/other.py"))

    current = runtime.store.get_state("project.current")
    assert current["project_id"] == project_id
    assert current["name"] == "Renamed" and current["path"] == "Projects/Renamed"
    activated_events = [row for row in runtime.store.recent_events(50) if row["type"] == "project.activated"]
    assert len(activated_events) == 1  # a name refresh is not a new activation


def test_disabled_projects_settings_is_a_complete_noop(tmp_path):
    root = tmp_path / "workspace"
    (root / "Projects" / "Foo").mkdir(parents=True)
    runtime = _runtime(root, projects_enabled=False)
    runtime.reload_rules()

    runtime._on_settled(_settled("Projects/Foo/main.py"))

    assert runtime.projects is None
    assert runtime.store.get_state("project.current") is None
    assert runtime.store.projects() == []
