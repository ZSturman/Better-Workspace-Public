"""The generic, store-agnostic LM Studio HTTP client -- shared by
lm_enrichment_v2.py (Work Log enrichment) and lm_tagging.py (item tagging).
Work-Log-specific refinement behavior is covered in test_lm_enrichment_v2.py
against v2's own generator."""

from __future__ import annotations

import json
from urllib.error import URLError

import pytest

import workspace_watcher.lm_studio as module
from workspace_watcher.lm_studio import LMStudioClient, LMStudioError


class Response:
    def __init__(self, payload): self.payload = payload
    def __enter__(self): return self
    def __exit__(self, *args): return None
    def read(self): return json.dumps(self.payload).encode()


def test_models_chat_and_embeddings_use_openai_compatible_shapes(monkeypatch):
    requests = []
    def fake_urlopen(request, timeout):
        requests.append((request.full_url, request.get_method(), request.data, timeout))
        if request.full_url.endswith("/models"):
            return Response({"data": [{"id": "chat"}, {"id": "embed"}]})
        if request.full_url.endswith("/embeddings"):
            return Response({"model": "embed", "data": [{"embedding": [1, 0]}, {"embedding": [0, 1]}]})
        return Response({"model": "chat", "choices": [{"message": {"content": " Factual result. "}}]})
    monkeypatch.setattr(module, "urlopen", fake_urlopen)
    client = LMStudioClient("http://local/v1", 7)
    assert client.models() == ["chat", "embed"]
    assert client.chat_completion([{"role": "user", "content": "x"}]) == ("Factual result.", "chat")
    assert client.embeddings(["a", "b"], model="embed") == ([[1.0, 0.0], [0.0, 1.0]], "embed")
    assert json.loads(requests[1][2])["messages"][0]["content"] == "x"
    assert "model" not in json.loads(requests[1][2])  # blank model permits server selection


@pytest.mark.parametrize("payload", [{}, {"choices": []}, {"choices": [{"message": {"content": ""}}]}])
def test_malformed_chat_response_is_a_clear_error(monkeypatch, payload):
    monkeypatch.setattr(module, "urlopen", lambda *_, **__: Response(payload))
    with pytest.raises(LMStudioError):
        LMStudioClient().chat_completion([])


def test_connection_refusal_is_failure_isolated(monkeypatch):
    monkeypatch.setattr(module, "urlopen", lambda *_, **__: (_ for _ in ()).throw(URLError("offline")))
    health = LMStudioClient().health()
    assert health.ok is False and "offline" in health.error
