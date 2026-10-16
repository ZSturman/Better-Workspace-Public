"""Work Log generation wired into the live runtime: a completed session
automatically prepares a draft (via the session.closed hook in _evaluate),
a discarded one does not, drafts survive a restart without duplicating, and
sync_pending on the tick loop is idempotent -- all against a fake Notion
sync object injected into runtime.work_logs, so nothing here ever touches
real Notion."""

from __future__ import annotations

import time
from pathlib import Path

from workspace_watcher.coalescer import Settled
from workspace_watcher.core_config import CoreConfig, HammerspoonInboxSettings, LMStudioSettings, NotionSettings, ProjectsSettings, SessionsSettings, WorkLogsSettings
from workspace_watcher.core_runtime import CoreRuntime
from workspace_watcher.intents import IntentFolderSettings
from workspace_watcher.lm_enrichment_v2 import LMEnrichmentService
from workspace_watcher.work_logs_v2 import WorkLogGenerator


class FakeSync:
    def __init__(self) -> None:
        self.synced: list[dict] = []

    def sync(self, draft: dict) -> str:
        self.synced.append(draft)
        return "fake-page-1"

    def preview(self, draft: dict) -> dict:
        return {"action": "create", "properties": {}}


def _runtime(root: Path, *, notion_sync: bool = False, minimum_session_confidence: float = 0.0, fake_sync: FakeSync | None = None, merge_nearby_minutes: float = 45.0) -> CoreRuntime:
    config = CoreConfig(
        root, root / "Logs/workspace-watcher/core.db", IntentFolderSettings.for_workspace(root),
        root / "config.toml", root / "rules.toml", 0.1,
        HammerspoonInboxSettings(enabled=False, path=root / "inbox.jsonl"),
        ProjectsSettings(enabled=True, root="Projects"),
        # Low thresholds so a couple of quick synthetic touches legitimately
        # close as "completed" without needing to simulate real elapsed time.
        SessionsSettings(enabled=True, minimum_events=1, minimum_active_seconds=1.0, minimum_confidence=0.0, merge_nearby_minutes=merge_nearby_minutes),
        NotionSettings(enabled=True),
        WorkLogsSettings(enabled=True, minimum_session_confidence=minimum_session_confidence, notion_sync=notion_sync, authoritative_writer="v2" if notion_sync else "legacy"),
    )
    runtime = CoreRuntime(config)
    if fake_sync is not None:
        runtime.work_logs = WorkLogGenerator(runtime.store, config.work_logs, config.notion, config.workspace_root, sync=fake_sync)
    return runtime


def _settled(path: str) -> Settled:
    return Settled(kind="created", path=path, prev_path=None, is_directory=False, raw_event_count=1, ts=time.time())


def test_a_completed_session_automatically_prepares_a_work_log_draft(tmp_path):
    root = tmp_path / "workspace"
    (root / "Projects" / "Foo").mkdir(parents=True)
    (root / "Projects" / "Bar").mkdir(parents=True)
    runtime = _runtime(root)

    runtime._on_settled(_settled("Projects/Foo/main.py"))
    # Switching to Bar closes Foo's session as "completed" (thresholds are
    # deliberately trivial here), which should prepare a draft automatically.
    runtime._on_settled(_settled("Projects/Bar/main.py"))

    drafts = runtime.store.work_log_drafts()
    assert len(drafts) == 1
    assert drafts[0]["project_name"] == "Foo"
    assert drafts[0]["status"] == "prepared"


def test_a_discarded_session_never_prepares_a_draft(tmp_path):
    root = tmp_path / "workspace"
    (root / "Projects" / "Foo").mkdir(parents=True)
    (root / "Projects" / "Bar").mkdir(parents=True)
    # High confidence bar this quick synthetic touch can never clear ->
    # Foo's session discards on switch, not completes.
    runtime = _runtime(root, minimum_session_confidence=0.99)

    runtime._on_settled(_settled("Projects/Foo/main.py"))
    runtime._on_settled(_settled("Projects/Bar/main.py"))

    closed = [row for row in runtime.store.recent_sessions() if row["project_name"] == "Foo"]
    assert closed[0]["status"] == "completed"  # Sessionizer itself is permissive here
    assert runtime.store.work_log_drafts() == []  # but work-log-level confidence gate rejected it


def test_repeated_completed_sessions_same_project_same_day_merge_one_draft(tmp_path):
    root = tmp_path / "workspace"
    (root / "Projects" / "Foo").mkdir(parents=True)
    (root / "Projects" / "Bar").mkdir(parents=True)
    # merge_nearby_minutes=0 forces two genuinely separate Foo sessions
    # rather than the Sessionizer's own (separately tested) resume-within-
    # window behavior reopening the same one -- this test is specifically
    # about the Work Log level merging two *distinct* sessions, which
    # test_work_logs_v2.py's unit tests already cover directly; this proves
    # the same thing end-to-end through the real session.closed hook.
    runtime = _runtime(root, merge_nearby_minutes=0.0)

    # Foo -> Bar -> Foo -> Bar: two separate completed Foo sessions the same day.
    runtime._on_settled(_settled("Projects/Foo/a.py"))
    runtime._on_settled(_settled("Projects/Bar/a.py"))
    runtime._on_settled(_settled("Projects/Foo/b.py"))
    runtime._on_settled(_settled("Projects/Bar/b.py"))

    foo_drafts = [row for row in runtime.store.work_log_drafts() if row["project_name"] == "Foo"]
    assert len(foo_drafts) == 1  # merged, not two drafts for the same project/day
    import json
    assert json.loads(foo_drafts[0]["payload_json"])["session_count"] == 2


def test_drafts_survive_a_restart_without_duplicating(tmp_path):
    root = tmp_path / "workspace"
    (root / "Projects" / "Foo").mkdir(parents=True)
    (root / "Projects" / "Bar").mkdir(parents=True)
    runtime = _runtime(root)
    runtime._on_settled(_settled("Projects/Foo/main.py"))
    runtime._on_settled(_settled("Projects/Bar/main.py"))
    assert len(runtime.store.work_log_drafts()) == 1
    runtime.store.close()

    restarted = _runtime(root)
    try:
        assert len(restarted.store.work_log_drafts()) == 1  # still exactly one, not duplicated by reconciliation
    finally:
        restarted.store.close()


def test_sync_pending_on_the_tick_loop_syncs_with_the_injected_fake(tmp_path):
    root = tmp_path / "workspace"
    (root / "Projects" / "Foo").mkdir(parents=True)
    (root / "Projects" / "Bar").mkdir(parents=True)
    fake = FakeSync()
    runtime = _runtime(root, notion_sync=True, fake_sync=fake)

    runtime._on_settled(_settled("Projects/Foo/main.py"))
    runtime._on_settled(_settled("Projects/Bar/main.py"))
    assert runtime.store.work_log_drafts()[0]["status"] == "prepared"

    runtime._sync_work_logs()

    assert len(fake.synced) == 1
    assert runtime.store.work_log_drafts()[0]["status"] == "synced"
    health = runtime.store.get_state("work_logs.health")
    assert health == {"state": "ok", "synced": 1}


def test_sync_pending_stays_off_by_default_even_with_completed_sessions(tmp_path):
    root = tmp_path / "workspace"
    (root / "Projects" / "Foo").mkdir(parents=True)
    (root / "Projects" / "Bar").mkdir(parents=True)
    fake = FakeSync()
    # notion_sync defaults to False in WorkLogsSettings -- confirm the tick
    # loop's sync step is a true no-op without it, even with a fake
    # injected and a real completed draft sitting there ready to go.
    runtime = _runtime(root, notion_sync=False, fake_sync=fake)

    runtime._on_settled(_settled("Projects/Foo/main.py"))
    runtime._on_settled(_settled("Projects/Bar/main.py"))
    runtime._sync_work_logs()

    assert fake.synced == []
    assert runtime.store.work_log_drafts()[0]["status"] == "prepared"


class FakeLMClient:
    def chat_completion(self, messages, *, model="", max_tokens=180):
        return "Fake enrichment.", "fake-model"


def test_enrich_work_logs_on_the_tick_loop_is_off_by_default(tmp_path):
    root = tmp_path / "workspace"
    (root / "Projects" / "Foo").mkdir(parents=True)
    (root / "Projects" / "Bar").mkdir(parents=True)
    runtime = _runtime(root)

    runtime._on_settled(_settled("Projects/Foo/main.py"))
    runtime._on_settled(_settled("Projects/Bar/main.py"))
    runtime._enrich_work_logs()

    import json
    assert "llm" not in json.loads(runtime.store.work_log_drafts()[0]["payload_json"])
    assert runtime.store.get_state("lm_studio.health") == {"state": "ok", "enriched": 0}


def test_enrich_work_logs_on_the_tick_loop_enriches_when_enabled(tmp_path):
    root = tmp_path / "workspace"
    (root / "Projects" / "Foo").mkdir(parents=True)
    (root / "Projects" / "Bar").mkdir(parents=True)
    runtime = _runtime(root)
    runtime.work_logs.lm_service = LMEnrichmentService(LMStudioSettings(enabled=True), client=FakeLMClient())

    runtime._on_settled(_settled("Projects/Foo/main.py"))
    runtime._on_settled(_settled("Projects/Bar/main.py"))
    runtime._enrich_work_logs()

    import json
    payload = json.loads(runtime.store.work_log_drafts()[0]["payload_json"])
    assert payload["llm"]["summary"] == "Fake enrichment."
    assert runtime.store.get_state("lm_studio.health") == {"state": "ok", "enriched": 1}
