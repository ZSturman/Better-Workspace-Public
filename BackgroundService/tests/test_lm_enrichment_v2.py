"""v2's optional LM Studio enrichment: disabled-by-default safety, per-pass
failure isolation, timeout/malformed-output/unavailability handling,
idempotency (no regeneration on unchanged evidence), and manual
regeneration -- all against a fake client, never touching a real LM Studio
server."""

from __future__ import annotations

import json

from workspace_watcher.core_config import LMStudioSettings
from workspace_watcher.lm_enrichment_v2 import LMEnrichmentService, _hash_evidence, _evidence_for_prompt
from workspace_watcher.lm_studio import LMStudioError


class FakeClient:
    def __init__(self, *, response: str = "A concise summary.", fail: bool = False, error: Exception | None = None) -> None:
        self.response = response
        self.fail = fail
        self.error = error
        self.calls: list[dict] = []

    def chat_completion(self, messages, *, model="", max_tokens=180):
        self.calls.append({"messages": messages, "model": model})
        if self.fail:
            raise self.error or LMStudioError("simulated failure")
        return self.response, model or "fake-model"


def _draft(payload: dict) -> dict:
    return {"id": "worklog-1", "payload_json": json.dumps(payload)}


def _payload(**overrides) -> dict:
    base = {
        "project": "Demo", "date": "2026-01-01", "active_minutes": 45.0, "elapsed_minutes": 60.0,
        "meaningful_event_count": 12, "session_count": 2, "resumed_session_count": 0, "interruption_count": 1,
        "longest_uninterrupted_minutes": 30.0, "summary": "12 meaningful changes across 4 file(s).",
        "confidence": 0.8, "files": ["Projects/Demo/a.py", "Projects/Demo/b.py"], "git": [{"branch": "main", "head_subject": "fix bug"}],
    }
    base.update(overrides)
    return base


def test_disabled_by_default_returns_none_and_never_calls_the_client(tmp_path):
    client = FakeClient()
    service = LMEnrichmentService(LMStudioSettings(enabled=False), client=client)
    result = service.enrich(_draft(_payload()))
    assert result is None
    assert client.calls == []


def test_enabled_produces_all_passes_from_a_successful_client():
    client = FakeClient(response="Worked on Demo, fixed a bug.")
    service = LMEnrichmentService(LMStudioSettings(enabled=True), client=client)
    result = service.enrich(_draft(_payload()))
    assert result is not None
    assert result["summary"] == "Worked on Demo, fixed a bug."
    assert result["work_type"] == "Worked on Demo, fixed a bug."  # same fake response reused for every pass
    assert isinstance(result["accomplishments"], list)
    assert result["next_step"] == "Worked on Demo, fixed a bug."
    assert result["anomaly_note"] is None  # confidence 0.8 is above the default 0.6 threshold
    assert result["model"] == "fake-model" or result["model"] is None
    assert result["errors"] == {}
    assert "generated_at" in result and "input_hash" in result
    # 4 passes (no anomaly note needed at this confidence)
    assert len(client.calls) == 4


def test_low_confidence_triggers_the_extra_anomaly_pass():
    client = FakeClient(response="Very short session, likely noise.")
    service = LMEnrichmentService(LMStudioSettings(enabled=True, low_confidence_threshold=0.6), client=client)
    result = service.enrich(_draft(_payload(confidence=0.2)))
    assert result["anomaly_note"] == "Very short session, likely noise."
    assert len(client.calls) == 5


def test_a_single_pass_failure_does_not_block_the_others():
    class PartiallyFailingClient(FakeClient):
        def chat_completion(self, messages, *, model="", max_tokens=180):
            system_prompt = messages[0]["content"]
            if "category of work" in system_prompt:
                raise LMStudioError("model timed out")
            return super().chat_completion(messages, model=model, max_tokens=max_tokens)

    client = PartiallyFailingClient(response="ok")
    service = LMEnrichmentService(LMStudioSettings(enabled=True), client=client)
    result = service.enrich(_draft(_payload()))
    assert result["work_type"] is None
    assert result["errors"] == {"work_type": "model timed out"}
    assert result["summary"] == "ok"  # the other passes still succeeded


def test_total_unavailability_still_returns_a_result_never_raises():
    client = FakeClient(fail=True, error=LMStudioError("Connection refused"))
    service = LMEnrichmentService(LMStudioSettings(enabled=True), client=client)
    result = service.enrich(_draft(_payload()))
    assert result is not None
    assert all(result[key] is None for key in ("summary", "work_type", "next_step"))
    assert result["accomplishments"] is None
    assert set(result["errors"]) == {"summary", "work_type", "accomplishments", "next_step"}


def test_an_unexpected_exception_in_a_pass_is_caught_too():
    class WeirdClient(FakeClient):
        def chat_completion(self, messages, *, model="", max_tokens=180):
            raise ValueError("some totally unexpected bug")

    service = LMEnrichmentService(LMStudioSettings(enabled=True), client=WeirdClient())
    result = service.enrich(_draft(_payload()))
    assert result is not None
    assert "unexpected error" in result["errors"]["summary"]


def test_malformed_accomplishments_output_is_parsed_defensively():
    client = FakeClient(response="- did a thing\n* did another\n\nand a third thing\nand a fourth (should be capped)")
    service = LMEnrichmentService(LMStudioSettings(enabled=True), client=client)
    result = service.enrich(_draft(_payload()))
    assert len(result["accomplishments"]) == 3  # capped, blank lines dropped, leading bullet chars stripped
    assert result["accomplishments"][0] == "did a thing"


def test_unchanged_evidence_is_not_regenerated(tmp_path):
    client = FakeClient()
    service = LMEnrichmentService(LMStudioSettings(enabled=True), client=client)
    payload = _payload()
    first = service.enrich(_draft(payload))
    assert first is not None
    calls_after_first = len(client.calls)

    # Simulate what WorkLogGenerator does: carry the llm result forward into
    # the payload, then ask again with the *same* underlying evidence.
    payload["llm"] = first
    second = service.enrich(_draft(payload))
    assert second is None  # nothing changed -- no new calls
    assert len(client.calls) == calls_after_first


def test_changed_evidence_does_regenerate(tmp_path):
    client = FakeClient()
    service = LMEnrichmentService(LMStudioSettings(enabled=True), client=client)
    payload = _payload()
    first = service.enrich(_draft(payload))
    payload["llm"] = first
    payload["meaningful_event_count"] = 99  # evidence changed
    second = service.enrich(_draft(payload))
    assert second is not None
    assert second["input_hash"] != first["input_hash"]


def test_force_regenerates_even_with_unchanged_evidence(tmp_path):
    client = FakeClient()
    service = LMEnrichmentService(LMStudioSettings(enabled=True), client=client)
    payload = _payload()
    first = service.enrich(_draft(payload))
    payload["llm"] = first
    calls_before = len(client.calls)
    second = service.enrich(_draft(payload), force=True)
    assert second is not None
    assert len(client.calls) > calls_before  # manual regeneration actually re-ran


def test_evidence_sent_to_the_model_never_includes_raw_file_contents_or_full_session_list():
    payload = _payload(sessions=[{"session_id": "s1", "files": ["a.py"], "git": {"diff": "SECRET DIFF CONTENT"}}])
    evidence = _evidence_for_prompt(payload)
    assert "sessions" not in evidence  # only day-level aggregates go to the model
    assert "diff" not in json.dumps(evidence)
    assert evidence["file_names"] == ["a.py", "b.py"]
    assert evidence["file_count"] == 2


def test_hash_is_stable_for_identical_evidence_and_differs_for_different_evidence():
    a = _evidence_for_prompt(_payload())
    b = _evidence_for_prompt(_payload())
    c = _evidence_for_prompt(_payload(meaningful_event_count=999))
    assert _hash_evidence(a) == _hash_evidence(b)
    assert _hash_evidence(a) != _hash_evidence(c)
