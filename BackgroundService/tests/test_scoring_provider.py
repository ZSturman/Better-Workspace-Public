"""Talking to a real local model.

Every case here came from actually running a comparison against LM Studio,
where the job failed three different ways before any model output was even
looked at. None of it changes what a model is allowed to assert -- claims stay
unverified, citations stay mandatory -- it only stops the transport and the
packaging from making the feature unusable.
"""

from __future__ import annotations

import io
import json
from urllib.error import HTTPError

import pytest

from workspace_watcher.scoring.ai import (
    MAX_EVIDENCE_CHARACTERS, MAX_EVIDENCE_PER_PROJECT, LocalProvider, _validate_choice, compact_projects,
)

ENDPOINT = "http://127.0.0.1:1234/v1"


def _http_error(code: int, message: str) -> HTTPError:
    body = json.dumps({"error": {"message": message}}).encode()
    return HTTPError(ENDPOINT, code, "Bad Request", {}, io.BytesIO(body))


class _Opener:
    """Stands in for the urllib opener, recording each request body."""

    def __init__(self, *responses):
        self.responses = list(responses)
        self.bodies: list[dict] = []

    def open(self, request, timeout=None):
        self.bodies.append(json.loads(request.data))
        outcome = self.responses.pop(0)
        if isinstance(outcome, Exception):
            raise outcome
        return io.BytesIO(outcome.encode())


def _reply(content: str) -> str:
    return json.dumps({"choices": [{"message": {"content": content}, "finish_reason": "stop"}], "model": "test-model"})


@pytest.fixture
def provider(monkeypatch):
    made = LocalProvider(ENDPOINT, "test-model")

    def install(opener):
        monkeypatch.setattr("workspace_watcher.scoring.ai.build_opener", lambda *_: opener)
        return made

    return install


# -- Transport --------------------------------------------------------------

def test_an_unsupported_option_is_dropped_and_the_call_retried(provider):
    """`reasoning_effort` stops a reasoning model spending its whole budget on
    hidden thinking, but LM Studio rejects it outright for models that cannot
    reason. Requiring the caller to know which would make the flag useless."""
    opener = _Opener(_http_error(400, "unsupported parameter reasoning_effort"), _reply('{"ok": true}'))
    result, model = provider(opener).infer("instruction", {})
    assert result == {"ok": True} and model == "test-model"
    assert "reasoning_effort" in opener.bodies[0]
    assert "reasoning_effort" not in opener.bodies[1]
    # Dropping one option must not drop the others.
    assert "response_format" in opener.bodies[1]


def test_a_rejection_that_is_not_about_an_option_is_reported_with_its_detail(provider):
    """A bare "HTTP Error 400: Bad Request" gave no way to discover that the
    real problem was a payload larger than the model's context."""
    opener = _Opener(_http_error(400, "request (15246 tokens) exceeds the available context size (8192 tokens)"))
    with pytest.raises(ValueError, match="exceeds the available context size"):
        provider(opener).infer("instruction", {})


def test_a_non_json_error_body_is_still_surfaced(provider):
    error = HTTPError(ENDPOINT, 500, "Server Error", {}, io.BytesIO(b"engine crashed"))
    with pytest.raises(ValueError, match="engine crashed"):
        provider(_Opener(error)).infer("instruction", {})


# -- Packaging around the JSON ---------------------------------------------

@pytest.mark.parametrize("content", [
    '{"winner": null}',
    '```json\n{"winner": null}\n```',
    '```\n{"winner": null}\n```',
    'Here is the comparison:\n{"winner": null}',
    '{"winner": null}\n\nLet me know if you need more detail.',
])
def test_a_correct_object_is_accepted_however_the_model_wrapped_it(provider, content):
    """Local instruct models routinely fence or narrate a correct object even
    when asked for JSON only -- which failed every single comparison."""
    assert provider(_Opener(_reply(content))).infer("instruction", {})[0] == {"winner": None}


@pytest.mark.parametrize("content", ["I cannot answer that.", "[1, 2, 3]", "   "])
def test_a_reply_with_no_json_object_is_still_an_error(provider, content):
    with pytest.raises(ValueError):
        provider(_Opener(_reply(content))).infer("instruction", {})


def test_an_invalid_reply_reports_an_excerpt(provider):
    """Without the excerpt there is no way to tell a fenced object from a
    refusal from a genuine malformation."""
    with pytest.raises(ValueError, match="totally-not-json"):
        provider(_Opener(_reply('{"totally-not-json"'))).infer("instruction", {})


def test_empty_visible_content_names_the_likely_cause(provider):
    reply = json.dumps({"choices": [{"message": {"content": ""}, "finish_reason": "length"}]})
    with pytest.raises(ValueError, match="reasoning/token settings"):
        provider(_Opener(reply)).infer("instruction", {})


# -- Citation rules ---------------------------------------------------------

def _pair():
    return (
        {"id": "a", "name": "A", "evidence": [{"id": "ev-a"}],
         "metrics": {"activity_30d": {"reference": "metric:a:activity_30d"}}},
        {"id": "b", "name": "B", "evidence": [{"id": "ev-b"}],
         "metrics": {"activity_30d": {"reference": "metric:b:activity_30d"}}},
    )


def test_a_rationale_may_cite_the_project_it_is_compared_against():
    """"More active than the alternative" is a comparison, and citing both
    sides is exactly what a comparison prompt invites. Requiring each rationale
    to cite only its own project rejected every real model answer."""
    result = {"winner": "a", "rationale": [
        {"project_id": "a", "reason": "More active than B.",
         "references": ["metric:a:activity_30d", "metric:b:activity_30d", "ev-b"]},
    ]}
    assert _validate_choice(result, _pair()) is result


def test_a_reference_that_was_never_supplied_is_still_rejected():
    result = {"winner": "a", "rationale": [
        {"project_id": "a", "reason": "Because.", "references": ["metric:a:invented_metric"]},
    ]}
    with pytest.raises(ValueError, match="invented_metric"):
        _validate_choice(result, _pair())


def test_an_abbreviated_reference_is_rejected_and_named():
    """The model citing "activity_30d" instead of "metric:a:activity_30d"
    needs a different response from the model inventing a metric, so the
    error names what was actually cited."""
    result = {"winner": "a", "rationale": [
        {"project_id": "a", "reason": "Because.", "references": ["activity_30d"]},
    ]}
    with pytest.raises(ValueError, match="'activity_30d'"):
        _validate_choice(result, _pair())


def test_a_rationale_must_cite_something():
    result = {"winner": "a", "rationale": [{"project_id": "a", "reason": "Trust me.", "references": []}]}
    with pytest.raises(ValueError, match="at least one reference"):
        _validate_choice(result, _pair())


def test_a_winner_outside_the_pair_is_rejected():
    result = {"winner": "c", "rationale": [
        {"project_id": "a", "reason": "x", "references": ["metric:a:activity_30d"]}]}
    with pytest.raises(ValueError, match="winner"):
        _validate_choice(result, _pair())


# -- Payload size -----------------------------------------------------------

def _row(project_id: str, *, planning=None):
    dimension = {
        "value": 50.0, "raw_value": 1.25, "unit": "hours", "state": "provisional",
        "source": "core.db:completed sessions", "provenance": "deterministic",
        "input_provenance": ["observed"], "formula_version": "1.1",
        "window": {"days": 30, "start": "2026-09-01T00:00:00+00:00", "end": "2026-10-01T00:00:00+00:00"},
        "coverage": {"complete": False, "accepted_sessions": 4, "excluded_observed_hours": 0.0, "start": None, "end": None},
        "calculated_at": "2026-09-27T12:00:00+00:00", "explanation": "x" * 400, "components": {},
    }
    return {"id": project_id, "name": project_id, "planning": planning or {},
            "dimensions": {"investment_observed": dict(dimension), "activity_30d": dict(dimension)}}


def _evidence(project_id: str, count: int):
    return [{"project_id": project_id, "id": f"ev-{i}", "revision": 1, "category": "document_excerpt",
             "provenance": "observed", "confidence": 0.9, "timestamp": f"2026-09-{i + 1:02d}T00:00:00+00:00",
             "value": {"text": "y" * 4000}} for i in range(count)]


def test_a_pair_stays_small_enough_for_a_local_context():
    """Against the real portfolio one pair came to roughly 15,000 tokens,
    which a model with an 8,192-token context refuses outright -- so every
    comparison failed before the model saw anything."""
    summaries = compact_projects([_row("a"), _row("b")], _evidence("a", 30) + _evidence("b", 30))
    assert len(summaries) == 2
    for summary in summaries:
        assert len(summary["evidence"]) == MAX_EVIDENCE_PER_PROJECT
        for item in summary["evidence"]:
            assert len(item["value"]) <= MAX_EVIDENCE_CHARACTERS
    # A generous ceiling: comfortably inside an 8k-token context with room
    # for the instruction and the reply.
    assert len(json.dumps(summaries)) < 12_000


def test_the_newest_evidence_is_the_evidence_that_is_kept():
    summary = compact_projects([_row("a")], _evidence("a", 30))[0]
    assert [item["id"] for item in summary["evidence"]] == [f"ev-{i}" for i in range(29, 29 - MAX_EVIDENCE_PER_PROJECT, -1)]


def test_every_kept_metric_still_carries_a_citable_reference():
    """Compaction must never remove the thing a rationale has to cite."""
    summary = compact_projects([_row("a")], [])[0]
    assert {m["reference"] for m in summary["metrics"].values()} == {"metric:a:investment_observed", "metric:a:activity_30d"}
    assert all(m["state"] == "provisional" for m in summary["metrics"].values())


def test_empty_planning_is_omitted_rather_than_sent_per_project():
    assert "planning" not in compact_projects([_row("a")], [])[0]
    assert compact_projects([_row("a", planning={"scope": "release-1"})], [])[0]["planning"] == {"scope": "release-1"}


def test_compaction_preserves_false_zero_and_manual_input_provenance():
    row = _row("a")
    metric = row["dimensions"]["investment_observed"]
    metric["coverage"].update(answered=0, required=3)
    metric["input_provenance"] = ["manual"]
    result = compact_projects([row], [])[0]["metrics"]["investment_observed"]
    assert result["coverage"]["complete"] is False
    assert result["coverage"]["answered"] == 0
    assert result["coverage"]["excluded_observed_hours"] == 0
    assert result["input_provenance"] == ["manual"]
