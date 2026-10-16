"""v2 Work Log generation: prepare/merge idempotency, confidence gating,
dry-run preview, sync retry, and duplicate prevention -- all against a fake
Notion sync object, so none of this touches task_management or the network."""

from __future__ import annotations

from datetime import datetime, timezone
from pathlib import Path

from workspace_watcher.core_config import LMStudioSettings, NotionSettings, WorkLogsSettings
from workspace_watcher.core_store import CoreStore
from workspace_watcher.lm_enrichment_v2 import LMEnrichmentService
from workspace_watcher.sessions_v2 import Session
from workspace_watcher.work_logs_v2 import WorkLogGenerator, _draft_id


class FakeSync:
    def __init__(self) -> None:
        self.synced: list[dict] = []
        self.previewed: list[dict] = []
        self.fail_next = False
        self.next_page_id = "page-1"

    def sync(self, draft: dict) -> str:
        if self.fail_next:
            self.fail_next = False
            raise RuntimeError("simulated Notion failure")
        self.synced.append(draft)
        return draft.get("notion_page_id") or self.next_page_id

    def preview(self, draft: dict) -> dict:
        self.previewed.append(draft)
        return {"action": "update" if draft.get("notion_page_id") else "create", "notion_page_id": draft.get("notion_page_id"), "properties": {"fake": True}}


def _iso(dt: datetime) -> str:
    return dt.isoformat()


def _session(**overrides) -> Session:
    base = dict(
        id="s1", project_id="p1", project_name="Demo", started_at=_iso(datetime(2026, 1, 1, 10, 0, tzinfo=timezone.utc)),
        ended_at=_iso(datetime(2026, 1, 1, 10, 30, tzinfo=timezone.utc)), active_seconds=600.0,
        meaningful_event_count=5, files=["a.py", "b.py"], burst_count=1, intensity=0.5, confidence=0.8,
        git={"branch": "main"}, status="completed", close_reason="switched",
        created_at=_iso(datetime(2026, 1, 1, 10, 0, tzinfo=timezone.utc)), updated_at=_iso(datetime(2026, 1, 1, 10, 30, tzinfo=timezone.utc)),
    )
    base.update(overrides)
    return Session(**base)


def _generator(tmp_path: Path, store: CoreStore, fake: FakeSync, **settings_overrides) -> WorkLogGenerator:
    settings = WorkLogsSettings(**settings_overrides)
    notion_settings = NotionSettings(enabled=True)
    return WorkLogGenerator(store, settings, notion_settings, tmp_path, sync=fake)


def test_prepare_creates_a_draft_for_a_completed_session(tmp_path):
    with CoreStore(tmp_path / "core.db") as store:
        generator = _generator(tmp_path, store, FakeSync())
        record = generator.prepare(_session())
        assert record is not None
        assert record["status"] == "prepared"
        drafts = store.work_log_drafts()
        assert len(drafts) == 1 and drafts[0]["project_id"] == "p1"


def test_prepare_ignores_a_discarded_or_open_session(tmp_path):
    with CoreStore(tmp_path / "core.db") as store:
        generator = _generator(tmp_path, store, FakeSync())
        assert generator.prepare(_session(status="discarded")) is None
        assert generator.prepare(_session(status="open")) is None
        assert store.work_log_drafts() == []


def test_prepare_below_minimum_confidence_is_skipped(tmp_path):
    with CoreStore(tmp_path / "core.db") as store:
        generator = _generator(tmp_path, store, FakeSync(), minimum_session_confidence=0.9)
        assert generator.prepare(_session(confidence=0.5)) is None
        assert store.work_log_drafts() == []


def test_two_sessions_same_project_same_day_merge_into_one_draft(tmp_path):
    with CoreStore(tmp_path / "core.db") as store:
        generator = _generator(tmp_path, store, FakeSync())
        generator.prepare(_session(id="s1"))
        generator.prepare(_session(id="s2", started_at=_iso(datetime(2026, 1, 1, 14, 0, tzinfo=timezone.utc)), ended_at=_iso(datetime(2026, 1, 1, 14, 20, tzinfo=timezone.utc))))
        drafts = store.work_log_drafts()
        assert len(drafts) == 1  # merged, not two separate drafts
        import json
        payload = json.loads(drafts[0]["payload_json"])
        assert payload["session_count"] == 2
        assert len(json.loads(drafts[0]["session_ids_json"])) == 2


def test_preparing_the_same_session_twice_does_not_duplicate(tmp_path):
    with CoreStore(tmp_path / "core.db") as store:
        generator = _generator(tmp_path, store, FakeSync())
        generator.prepare(_session())
        generator.prepare(_session())  # e.g. a redundant re-evaluation of the same event
        drafts = store.work_log_drafts()
        assert len(drafts) == 1
        import json
        payload = json.loads(drafts[0]["payload_json"])
        assert payload["session_count"] == 1  # not appended twice
        assert json.loads(drafts[0]["session_ids_json"]) == ["s1"]


def test_a_resumed_sessions_second_close_refreshes_its_stale_fact(tmp_path):
    """A resumed session keeps the same id across each of its closes
    (sessions_v2.Sessionizer._open's resume path). Re-preparing after a
    later close of the *same* session id must replace its embedded evidence
    with the fresh, final numbers -- not silently keep whatever was true at
    the first close, which would make the merged Work Log permanently
    understate a session that got resumed and extended further."""
    with CoreStore(tmp_path / "core.db") as store:
        generator = _generator(tmp_path, store, FakeSync())
        generator.prepare(_session(id="s1", meaningful_event_count=2, files=["a.py"], active_seconds=60.0))
        generator.prepare(_session(id="s1", meaningful_event_count=6, files=["a.py", "b.py", "c.py"], active_seconds=300.0))
        drafts = store.work_log_drafts()
        assert len(drafts) == 1
        import json
        payload = json.loads(drafts[0]["payload_json"])
        assert payload["session_count"] == 1  # still one component, not two
        assert payload["meaningful_event_count"] == 6  # refreshed, not stuck at 2
        assert payload["files"] == ["a.py", "b.py", "c.py"]
        assert payload["sessions"][0]["meaningful_event_count"] == 6


def test_different_projects_same_day_get_separate_drafts(tmp_path):
    with CoreStore(tmp_path / "core.db") as store:
        generator = _generator(tmp_path, store, FakeSync())
        generator.prepare(_session(id="s1", project_id="p1"))
        generator.prepare(_session(id="s2", project_id="p2", project_name="Other"))
        assert len(store.work_log_drafts()) == 2


def test_merge_by_project_day_disabled_gives_one_draft_per_session(tmp_path):
    with CoreStore(tmp_path / "core.db") as store:
        generator = _generator(tmp_path, store, FakeSync(), merge_by_project_day=False)
        generator.prepare(_session(id="s1"))
        generator.prepare(_session(id="s2"))
        assert len(store.work_log_drafts()) == 2


def test_draft_id_is_deterministic_from_project_and_date():
    assert _draft_id("p1", "2026-01-01") == _draft_id("p1", "2026-01-01")
    assert _draft_id("p1", "2026-01-01") != _draft_id("p1", "2026-01-02")
    assert _draft_id("p1", "2026-01-01") != _draft_id("p2", "2026-01-01")


def test_sync_pending_is_a_noop_when_notion_sync_is_off(tmp_path):
    with CoreStore(tmp_path / "core.db") as store:
        fake = FakeSync()
        generator = _generator(tmp_path, store, fake, notion_sync=False)
        generator.prepare(_session())
        assert generator.sync_pending() == []
        assert fake.synced == []
        assert store.work_log_drafts()[0]["status"] == "prepared"


def test_sync_pending_is_a_noop_when_authoritative_writer_is_still_legacy(tmp_path):
    # Third independent gate: notion_sync=true alone must not be enough.
    with CoreStore(tmp_path / "core.db") as store:
        fake = FakeSync()
        generator = _generator(tmp_path, store, fake, notion_sync=True, authoritative_writer="legacy")
        generator.prepare(_session())
        assert generator.sync_pending() == []
        assert fake.synced == []
        assert store.work_log_drafts()[0]["status"] == "prepared"


def test_sync_pending_is_a_noop_with_an_unrecognized_authoritative_writer_value(tmp_path):
    # Anything other than the literal "v2" refuses to write -- a typo in
    # config.toml fails closed, not open.
    with CoreStore(tmp_path / "core.db") as store:
        fake = FakeSync()
        generator = _generator(tmp_path, store, fake, notion_sync=True, authoritative_writer="V2")
        generator.prepare(_session())
        assert generator.sync_pending() == []
        assert fake.synced == []


def test_sync_pending_syncs_and_marks_synced(tmp_path):
    with CoreStore(tmp_path / "core.db") as store:
        fake = FakeSync()
        generator = _generator(tmp_path, store, fake, notion_sync=True, authoritative_writer="v2")
        generator.prepare(_session())
        results = generator.sync_pending()
        assert len(results) == 1 and results[0]["status"] == "synced"
        assert store.work_log_drafts()[0]["status"] == "synced"
        assert store.work_log_drafts()[0]["notion_page_id"] == "page-1"


def test_sync_pending_records_failure_and_retries_next_call(tmp_path):
    with CoreStore(tmp_path / "core.db") as store:
        fake = FakeSync()
        generator = _generator(tmp_path, store, fake, notion_sync=True, authoritative_writer="v2")
        generator.prepare(_session())
        fake.fail_next = True
        results = generator.sync_pending()
        assert results[0]["status"] == "sync_failed"
        assert store.work_log_drafts()[0]["status"] == "sync_failed"

        # A retry (e.g. next tick) picks the same draft back up and succeeds.
        second = generator.sync_pending()
        assert second[0]["status"] == "synced"
        assert len(store.work_log_drafts()) == 1  # never duplicated by the retry


def test_sync_pending_updates_the_same_page_on_a_later_sync_not_a_new_one(tmp_path):
    with CoreStore(tmp_path / "core.db") as store:
        fake = FakeSync()
        generator = _generator(tmp_path, store, fake, notion_sync=True, authoritative_writer="v2")
        generator.prepare(_session(id="s1"))
        generator.sync_pending()
        first_page_id = store.work_log_drafts()[0]["notion_page_id"]

        # More activity the same day -> draft re-prepared, marked prepared
        # again, and synced again -- must reuse the same Notion page.
        generator.prepare(_session(id="s2", started_at=_iso(datetime(2026, 1, 1, 15, 0, tzinfo=timezone.utc)), ended_at=_iso(datetime(2026, 1, 1, 15, 10, tzinfo=timezone.utc))))
        assert store.work_log_drafts()[0]["status"] == "prepared"
        generator.sync_pending()
        assert len(store.work_log_drafts()) == 1
        assert store.work_log_drafts()[0]["notion_page_id"] == first_page_id
        assert len(fake.synced) == 2
        assert fake.synced[1]["notion_page_id"] == first_page_id  # sync() was told about the existing page


def test_preview_pending_never_calls_sync_and_reports_notion_disabled(tmp_path):
    with CoreStore(tmp_path / "core.db") as store:
        fake = FakeSync()
        settings = WorkLogsSettings(notion_sync=False)
        notion_settings = NotionSettings(enabled=False)
        generator = WorkLogGenerator(store, settings, notion_settings, tmp_path, sync=fake)
        generator.prepare(_session())
        previews = generator.preview_pending()
        assert previews == [{"draft_id": None, "error": "Notion is disabled ([workspace_watcher.notion].enabled = false)"}]
        assert fake.synced == [] and fake.previewed == []


def test_preview_pending_shows_what_would_be_written_without_syncing(tmp_path):
    with CoreStore(tmp_path / "core.db") as store:
        fake = FakeSync()
        generator = _generator(tmp_path, store, fake, notion_sync=False)  # sync stays off; preview still works
        generator.prepare(_session())
        previews = generator.preview_pending()
        assert len(previews) == 1
        assert previews[0]["action"] == "create"
        assert fake.synced == []  # never actually wrote anything
        assert len(fake.previewed) == 1
        assert store.work_log_drafts()[0]["status"] == "prepared"  # preview never mutates draft status


class FakeLMClient:
    def __init__(self, response: str = "A summary.") -> None:
        self.response = response
        self.calls = 0

    def chat_completion(self, messages, *, model="", max_tokens=180):
        self.calls += 1
        return self.response, "fake-model"


def test_enrich_pending_is_a_noop_when_lm_studio_disabled(tmp_path):
    with CoreStore(tmp_path / "core.db") as store:
        generator = _generator(tmp_path, store, FakeSync())
        generator.prepare(_session())
        assert generator.enrich_pending() == []
        import json
        assert "llm" not in json.loads(store.work_log_drafts()[0]["payload_json"])


def test_enrich_pending_enriches_a_prepared_draft(tmp_path):
    with CoreStore(tmp_path / "core.db") as store:
        generator = _generator(tmp_path, store, FakeSync())
        generator.prepare(_session())
        client = FakeLMClient()
        generator.lm_service = LMEnrichmentService(LMStudioSettings(enabled=True), client=client)
        results = generator.enrich_pending()
        assert len(results) == 1
        import json
        payload = json.loads(store.work_log_drafts()[0]["payload_json"])
        assert payload["llm"]["summary"] == "A summary."
        assert payload["summary"] != payload["llm"]["summary"]  # deterministic summary is untouched, kept separate


def test_enrich_pending_does_not_reenrich_unchanged_drafts_on_a_second_call(tmp_path):
    with CoreStore(tmp_path / "core.db") as store:
        generator = _generator(tmp_path, store, FakeSync())
        generator.prepare(_session())
        client = FakeLMClient()
        generator.lm_service = LMEnrichmentService(LMStudioSettings(enabled=True), client=client)
        generator.enrich_pending()
        calls_after_first = client.calls
        assert generator.enrich_pending() == []  # nothing changed -- no new drafts to enrich
        assert client.calls == calls_after_first


def test_preparing_a_new_session_the_same_day_preserves_the_prior_enrichment_until_regenerated(tmp_path):
    with CoreStore(tmp_path / "core.db") as store:
        generator = _generator(tmp_path, store, FakeSync())
        generator.prepare(_session(id="s1"))
        client = FakeLMClient()
        generator.lm_service = LMEnrichmentService(LMStudioSettings(enabled=True), client=client)
        generator.enrich_pending()
        import json
        first_llm = json.loads(store.work_log_drafts()[0]["payload_json"])["llm"]

        # More activity the same day -> prepare() must not silently drop the
        # existing enrichment (even though it's now evidence-stale).
        generator.prepare(_session(id="s2", started_at=_iso(datetime(2026, 1, 1, 14, 0, tzinfo=timezone.utc)), ended_at=_iso(datetime(2026, 1, 1, 14, 20, tzinfo=timezone.utc))))
        payload_after_reprepare = json.loads(store.work_log_drafts()[0]["payload_json"])
        assert payload_after_reprepare["llm"] == first_llm  # carried forward, not dropped

        # A later enrichment pass notices the evidence changed and regenerates.
        generator.enrich_pending()
        payload_after_reenrich = json.loads(store.work_log_drafts()[0]["payload_json"])
        assert payload_after_reenrich["llm"]["input_hash"] != first_llm["input_hash"]


def test_enrich_draft_forces_regeneration_for_manual_use(tmp_path):
    with CoreStore(tmp_path / "core.db") as store:
        generator = _generator(tmp_path, store, FakeSync())
        record = generator.prepare(_session())
        client = FakeLMClient()
        generator.lm_service = LMEnrichmentService(LMStudioSettings(enabled=True), client=client)
        generator.enrich_pending()
        calls_after_first = client.calls
        result = generator.enrich_draft(record["id"])
        assert result is not None
        assert client.calls > calls_after_first  # force=True by default for manual regeneration


def test_enrich_draft_returns_none_for_an_unknown_id(tmp_path):
    with CoreStore(tmp_path / "core.db") as store:
        generator = _generator(tmp_path, store, FakeSync())
        generator.lm_service = LMEnrichmentService(LMStudioSettings(enabled=True), client=FakeLMClient())
        assert generator.enrich_draft("worklog-does-not-exist") is None


def test_an_overnight_session_is_bucketed_under_its_start_date_not_split(tmp_path):
    # A session that runs past midnight (started working late, kept going)
    # is one continuous unit of work -- it must be attributed to the day it
    # STARTED, not the day it ended, and never split across two drafts.
    local_tz = datetime.now().astimezone().tzinfo
    session = _session(
        started_at=_iso(datetime(2026, 1, 1, 23, 50, tzinfo=local_tz)),
        ended_at=_iso(datetime(2026, 1, 2, 0, 20, tzinfo=local_tz)),
    )
    with CoreStore(tmp_path / "core.db") as store:
        generator = _generator(tmp_path, store, FakeSync())
        record = generator.prepare(session)
        assert record["date_key"] == "2026-01-01"
        drafts = store.work_log_drafts()
        assert len(drafts) == 1  # never split into a second draft for the 2nd calendar day


def test_a_new_session_starting_just_after_midnight_gets_its_own_draft(tmp_path):
    # The following day's early-morning work is a genuinely separate day's
    # Work Log, not merged into the overnight session's draft from the day
    # before, even for the same project.
    local_tz = datetime.now().astimezone().tzinfo
    late_session = _session(id="s1", started_at=_iso(datetime(2026, 1, 1, 23, 0, tzinfo=local_tz)), ended_at=_iso(datetime(2026, 1, 1, 23, 30, tzinfo=local_tz)))
    early_session = _session(id="s2", started_at=_iso(datetime(2026, 1, 2, 9, 0, tzinfo=local_tz)), ended_at=_iso(datetime(2026, 1, 2, 9, 30, tzinfo=local_tz)))
    with CoreStore(tmp_path / "core.db") as store:
        generator = _generator(tmp_path, store, FakeSync())
        first = generator.prepare(late_session)
        second = generator.prepare(early_session)
        assert first["date_key"] == "2026-01-01"
        assert second["date_key"] == "2026-01-02"
        assert first["id"] != second["id"]
        assert len(store.work_log_drafts()) == 2


def test_prepare_promotes_an_imported_legacy_draft_back_to_prepared_preserving_its_notion_page_id(tmp_path):
    """The core cross-writer dedup guarantee `legacy_import_v2.py` depends
    on: once a legacy Notion Work Log page has been imported (status
    'imported', a real notion_page_id, no local session evidence yet),
    genuinely new v2-observed activity for that same (project, day) must
    upsert the SAME draft row, flip it back to 'prepared', and keep the
    legacy page id -- so an eventual sync updates that page instead of
    creating a second one. No special-casing lives in `prepare()` for this;
    this test proves that's actually true, not just reasoned about."""
    with CoreStore(tmp_path / "core.db") as store:
        session = _session()
        draft_id = _draft_id(session.project_id, "2026-01-01")
        now = "2026-01-01T00:00:00+00:00"
        store.upsert_work_log_draft({
            "id": draft_id, "project_id": session.project_id, "project_name": session.project_name, "date_key": "2026-01-01",
            "session_ids": [],
            "payload": {"project_id": session.project_id, "project": session.project_name, "date": "2026-01-01",
                        "summary": "(imported from an existing legacy Notion Work Log page; no local evidence yet)",
                        "provenance": ["legacy_import:notion"], "session_count": 0},
            "status": "imported", "notion_page_id": "legacy-page-123", "sync_error": None,
            "created_at": now, "updated_at": now,
        })

        generator = _generator(tmp_path, store, FakeSync())
        record = generator.prepare(session)

        assert record["id"] == draft_id  # same row, not a new one
        assert record["status"] == "prepared"  # promoted
        assert record["notion_page_id"] == "legacy-page-123"  # legacy identity preserved
        assert session.id in record["session_ids"]
        assert record["payload"]["session_count"] == 1  # genuine v2 evidence now present

        row = store.get_work_log_draft(draft_id)
        assert row["status"] == "prepared"
        assert row["notion_page_id"] == "legacy-page-123"
