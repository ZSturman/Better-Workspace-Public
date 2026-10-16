from __future__ import annotations

import json

import workspace_watcher.lm_studio as lm_module
from workspace_watcher.config import default_config
from workspace_watcher.intent import IntentItemIndex
from workspace_watcher.lm_tagging import LMStudioItemAnalyzer, process_item
from workspace_watcher.store import WorkspaceStore


class _Response:
    def __init__(self, payload):
        self.payload = payload

    def __enter__(self):
        return self

    def __exit__(self, *args):
        return None

    def read(self):
        return json.dumps(self.payload).encode()


def _chat_response(content: str):
    return _Response({"model": "local-model", "choices": [{"message": {"content": content}}]})


def _make_item(tmp_path):
    d = tmp_path / "For Inspiration" / "Dashboard Screenshots"
    d.mkdir(parents=True)
    (d / ".item.toml").write_text('tags = ["Dashboard design"]\n')
    cfg = default_config(tmp_path)
    store = WorkspaceStore(tmp_path / "events.db")
    IntentItemIndex(store, tmp_path).rebuild(cfg, reason="test")
    return store, store.get_item_by_path("For Inspiration/Dashboard Screenshots")


def test_successful_inference_adds_inferred_tags_and_summary(tmp_path, monkeypatch):
    store, item = _make_item(tmp_path)
    monkeypatch.setattr(
        lm_module, "urlopen",
        lambda *_, **__: _chat_response(json.dumps({"tags": ["Navigation", "Minimal UX"], "summary": "Dashboard layout inspiration."})),
    )
    analyzer = LMStudioItemAnalyzer("http://local/v1", "", 5)
    result = process_item(store, item, analyzer, classify=True, summarize=True)
    assert result["status"] == "succeeded"
    tags = {t["display"]: t["provenance"] for t in store.tags_for_item(item["item_id"])}
    assert tags["Navigation"] == "inferred" and tags["Dashboard design"] == "user"
    state = json.loads(store.get_item(item["item_id"])["lm_state_json"])
    assert state["succeeded"] is True and state["summary"] == "Dashboard layout inspiration."
    store.close()


def test_unchanged_content_skips_a_second_call(tmp_path, monkeypatch):
    store, item = _make_item(tmp_path)
    calls = []

    def fake_urlopen(request, timeout):
        calls.append(1)
        return _chat_response(json.dumps({"tags": ["Navigation"], "summary": ""}))

    monkeypatch.setattr(lm_module, "urlopen", fake_urlopen)
    analyzer = LMStudioItemAnalyzer("http://local/v1", "", 5)
    process_item(store, item, analyzer, classify=True, summarize=False)
    item_again = store.get_item(item["item_id"])
    result2 = process_item(store, item_again, analyzer, classify=True, summarize=False)
    assert result2["status"] == "unchanged"
    assert len(calls) == 1
    store.close()


def test_offline_server_does_not_crash_and_records_error(tmp_path, monkeypatch):
    store, item = _make_item(tmp_path)

    def fake_urlopen(*_args, **_kwargs):
        raise OSError("connection refused")

    monkeypatch.setattr(lm_module, "urlopen", fake_urlopen)
    analyzer = LMStudioItemAnalyzer("http://local/v1", "", 5)
    result = process_item(store, item, analyzer, classify=True, summarize=True)
    assert result["status"] == "failed" and result["error"]
    # Existing user tags are untouched by the failed inference attempt.
    tags = [t["display"] for t in store.tags_for_item(item["item_id"])]
    assert tags == ["Dashboard design"]
    store.close()
