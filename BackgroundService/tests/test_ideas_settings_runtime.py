"""CoreRuntime._sync_ideas honors the live Settings override (SQLite) over
the config.toml default, and stays a safe no-op whenever Notion sync is off
-- Ideas must never require Notion to function."""

from __future__ import annotations

from pathlib import Path

from workspace_watcher.core_config import CoreConfig, IdeasSettings, NotionSettings
from workspace_watcher.core_runtime import CoreRuntime
from workspace_watcher.ideas_v2 import set_ideas_notion_sync_enabled
from workspace_watcher.intents import IntentFolderSettings


def _runtime(tmp_path: Path, **overrides) -> CoreRuntime:
    config = CoreConfig(
        tmp_path, tmp_path / "Logs/workspace-watcher/core.db", IntentFolderSettings.for_workspace(tmp_path),
        tmp_path / "config.toml", tmp_path / "rules.toml", 0.1,
        notion=overrides.pop("notion", NotionSettings()), ideas=overrides.pop("ideas", IdeasSettings()),
    )
    return CoreRuntime(config)


class _CountingFakeAdapter:
    def __init__(self) -> None:
        self.sync_calls = 0

    def _client(self):  # pragma: no cover - never reached when there are no ideas to sync
        raise AssertionError("should not need a real client when there is nothing to sync")


def test_sync_ideas_is_a_no_op_when_notion_is_disabled_by_default(tmp_path):
    (tmp_path / "Temporary" / "[[Ideas]]").mkdir(parents=True)
    runtime = _runtime(tmp_path)
    result = runtime._sync_ideas()
    assert result == {"skipped": True}


def test_sync_ideas_is_a_no_op_when_notion_enabled_but_ideas_sync_is_not(tmp_path):
    (tmp_path / "Temporary" / "[[Ideas]]").mkdir(parents=True)
    runtime = _runtime(tmp_path, notion=NotionSettings(enabled=True), ideas=IdeasSettings(notion_sync=False))
    result = runtime._sync_ideas()
    assert result == {"skipped": True}


def test_explicit_sync_raises_a_clear_error_when_disabled(tmp_path):
    (tmp_path / "Temporary" / "[[Ideas]]").mkdir(parents=True)
    runtime = _runtime(tmp_path)
    try:
        runtime.sync_ideas_now()
        assert False, "expected a ValueError explaining why sync is unavailable"
    except ValueError as error:
        assert "disabled" in str(error)


def test_settings_override_enables_sync_without_touching_config_toml(tmp_path):
    (tmp_path / "Temporary" / "[[Ideas]]").mkdir(parents=True)
    runtime = _runtime(tmp_path, notion=NotionSettings(enabled=True), ideas=IdeasSettings(notion_sync=False))
    assert runtime._sync_ideas() == {"skipped": True}

    set_ideas_notion_sync_enabled(runtime.store, True, "2026-01-01T00:00:00+00:00")
    runtime.ideas_notion.adapter = _CountingFakeAdapter()
    result = runtime._sync_ideas()
    assert result != {"skipped": True}  # actually attempted (nothing to sync yet, but it tried)

    set_ideas_notion_sync_enabled(runtime.store, False, "2026-01-01T00:01:00+00:00")
    assert runtime._sync_ideas() == {"skipped": True}
