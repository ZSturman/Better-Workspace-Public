"""When the configured Notion Ideas database disappears (deleted, or unshared from
the integration), local ideas are untouched, the app is told plainly, and the
service stops asking Notion on every pass."""

from __future__ import annotations

from pathlib import Path

from workspace_watcher.core_config import CoreConfig, IdeasSettings, NotionSettings
from workspace_watcher.core_runtime import CoreRuntime
from workspace_watcher.intents import IntentFolderSettings
from workspace_watcher.item_records import initialize_idea_record
from workspace_watcher.notion_client_v2 import NotionCacheError


class _GoneSync:
    """Stands in for IdeasNotionSync against a database Notion no longer finds."""

    def __init__(self) -> None:
        self.calls = 0

    def sync_item(self, *_args, **_kwargs):
        self.calls += 1
        raise NotionCacheError("Notion HTTP 404: Could not find database with ID: 304aec94.")

    def pull_new_ideas(self, *_args, **_kwargs):
        return []


def _runtime(tmp_path: Path) -> CoreRuntime:
    idea = tmp_path / "Temporary" / "[[Ideas]]" / "An idea"
    idea.mkdir(parents=True)
    initialize_idea_record(idea)
    config = CoreConfig(
        tmp_path, tmp_path / "Logs/workspace-watcher/core.db", IntentFolderSettings.for_workspace(tmp_path),
        tmp_path / "config.toml", tmp_path / "rules.toml", 0.1,
        notion=NotionSettings(enabled=True), ideas=IdeasSettings(notion_sync=True),
    )
    runtime = CoreRuntime(config)
    runtime.indexer.rebuild(initialize_missing_metadata=True)
    return runtime


def test_a_missing_database_is_reported_and_retried_rarely(tmp_path):
    runtime = _runtime(tmp_path)
    runtime.ideas_notion = _GoneSync()

    runtime._sync_ideas()
    health = runtime.store.get_state("ideas_notion.health")
    assert health["state"] == "database_missing"
    assert runtime.store.get_state("ideas_notion.paused_until")["until"]
    assert (tmp_path / "Temporary" / "[[Ideas]]" / "An idea" / "watcher.item.toml").exists(), "local idea untouched"

    calls = runtime.ideas_notion.calls
    assert runtime._sync_ideas() == {"skipped": True, "reason": "Notion Ideas database missing; retrying later"}
    assert runtime.ideas_notion.calls == calls, "no request while backing off"


def test_an_ordinary_failure_is_not_mistaken_for_a_missing_database(tmp_path):
    runtime = _runtime(tmp_path)

    class _Flaky(_GoneSync):
        def sync_item(self, *_args, **_kwargs):
            raise NotionCacheError("Notion HTTP 502: bad gateway")

    runtime.ideas_notion = _Flaky()
    runtime._sync_ideas()
    assert runtime.store.get_state("ideas_notion.health")["state"] == "error"
    assert not (runtime.store.get_state("ideas_notion.paused_until") or {}).get("until")
