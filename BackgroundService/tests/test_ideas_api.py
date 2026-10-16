"""Real HTTP integration tests for the /v1/ideas* endpoints -- same
approach as test_core_api_v2.py (a real ThreadingHTTPServer, real urllib
requests, no mocking of the routing layer)."""

from __future__ import annotations

import json
import threading
import urllib.error
import urllib.request
from pathlib import Path

import pytest

from workspace_watcher.core_api import serve
from workspace_watcher.core_config import CoreConfig, HammerspoonInboxSettings, ProjectsSettings, SessionsSettings
from workspace_watcher.core_store import CoreStore
from workspace_watcher.intents import IntentFolderSettings


def _config(root: Path) -> CoreConfig:
    return CoreConfig(
        root, root / "Logs/workspace-watcher/core.db", IntentFolderSettings.for_workspace(root),
        root / "config.toml", root / "rules.toml", 0.1,
        HammerspoonInboxSettings(enabled=False, path=root / "inbox.jsonl"),
        ProjectsSettings(enabled=True, root="Projects"), SessionsSettings(),
    )


class _Server:
    def __init__(self, config: CoreConfig, *, runtime=None) -> None:
        self.server = serve(config, port=0, runtime=runtime)
        self.base = f"http://127.0.0.1:{self.server.server_port}"
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def close(self) -> None:
        self.server.shutdown()
        self.thread.join(timeout=5)
        self.server.server_close()

    def request(self, method: str, path: str, body: dict | None = None) -> tuple[int, dict]:
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(f"{self.base}{path}", data=data, method=method, headers={"Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=5) as response:
                return response.status, json.loads(response.read())
        except urllib.error.HTTPError as error:
            return error.code, json.loads(error.read())


@pytest.fixture
def server(tmp_path):
    ideas_folder = tmp_path / "Temporary" / "[[Ideas]]"
    ideas_folder.mkdir(parents=True)
    config = _config(tmp_path)
    with CoreStore(config.database_path):
        pass
    srv = _Server(config)
    yield srv, config, ideas_folder
    srv.close()


def test_creating_an_idea_over_http_keeps_metadata_private_and_lists_it(server):
    srv, config, ideas_folder = server
    status, body = srv.request("POST", "/v1/ideas", {"title": "A Podcast Format Idea"})
    assert status == 201
    idea_id = body["data"]["id"]
    assert not (ideas_folder / "A Podcast Format Idea" / "watcher.item.toml").exists()

    status, body = srv.request("GET", "/v1/ideas")
    assert status == 200
    assert any(row["id"] == idea_id and row["title"] == "A Podcast Format Idea" for row in body["data"])


def test_creating_an_idea_with_a_blank_title_is_a_400(server):
    srv, config, _ = server
    status, body = srv.request("POST", "/v1/ideas", {"title": "   "})
    assert status == 400
    assert "error" in body["data"] or "error" in body


def test_idea_detail_404s_for_an_unknown_id(server):
    srv, _, _ = server
    status, _ = srv.request("GET", "/v1/ideas/does-not-exist")
    assert status == 404


def test_patching_an_idea_updates_it_and_persists_privately(server):
    srv, config, ideas_folder = server
    _, created = srv.request("POST", "/v1/ideas", {"title": "Editable"})
    idea_id = created["data"]["id"]

    status, body = srv.request("PATCH", f"/v1/ideas/{idea_id}", {
        "type": "experiment", "status": "exploring", "tags": ["ai", "prototyping"], "one_liner": "Try it fast",
    })
    assert status == 200
    assert body["data"]["type"] == "experiment"
    assert set(body["data"]["tags"]) == {"ai", "prototyping"}

    from workspace_watcher.private_items import load_record
    with CoreStore(config.database_path) as reopened:
        record = load_record(reopened, ideas_folder / "Editable")
    assert record.type == "experiment" and record.one_liner == "Try it fast"

    # Restart-equivalent: a fresh GET reflects the persisted private record, not
    # just an in-memory response.
    status, body = srv.request("GET", f"/v1/ideas/{idea_id}")
    assert status == 200 and body["data"]["type"] == "experiment"


def test_patching_an_unknown_idea_is_a_404(server):
    srv, _, _ = server
    status, _ = srv.request("PATCH", "/v1/ideas/does-not-exist", {"status": "raw"})
    assert status == 404


def test_patching_an_unknown_field_is_a_400(server):
    srv, config, _ = server
    _, created = srv.request("POST", "/v1/ideas", {"title": "Editable"})
    idea_id = created["data"]["id"]
    status, body = srv.request("PATCH", f"/v1/ideas/{idea_id}", {"id": "not-allowed"})
    assert status == 400


def test_settings_reflect_the_config_default_until_overridden(server):
    srv, config, _ = server
    status, body = srv.request("GET", "/v1/settings")
    assert status == 200
    assert body["data"]["ideas_notion_sync_enabled"] is False  # config default
    assert body["data"]["ideas_notion_sync_default"] is False


def test_toggling_ideas_notion_sync_overrides_the_config_default(server):
    srv, config, _ = server
    status, body = srv.request("POST", "/v1/settings/ideas-notion-sync", {"enabled": True})
    assert status == 200 and body["data"]["ideas_notion_sync_enabled"] is True

    status, body = srv.request("GET", "/v1/settings")
    assert body["data"]["ideas_notion_sync_enabled"] is True
    assert body["data"]["ideas_notion_sync_default"] is False  # config.toml itself is untouched

    status, body = srv.request("POST", "/v1/settings/ideas-notion-sync", {"enabled": False})
    assert status == 200 and body["data"]["ideas_notion_sync_enabled"] is False


def test_resolve_conflict_404s_for_an_unknown_idea(server):
    srv, _, _ = server
    status, _ = srv.request("POST", "/v1/ideas/does-not-exist/resolve-conflict", {"resolution": "keep_local"})
    assert status == 404


def test_resolve_conflict_requires_the_running_service_or_a_linked_idea(server):
    srv, config, _ = server
    _, created = srv.request("POST", "/v1/ideas", {"title": "Never Synced"})
    idea_id = created["data"]["id"]
    # No runtime in this test server, and Notion is disabled -- either way
    # there's no linked page to resolve against, so this must fail cleanly
    # rather than crash.
    status, body = srv.request("POST", f"/v1/ideas/{idea_id}/resolve-conflict", {"resolution": "keep_local"})
    assert status == 400


def test_resurfacing_endpoint_is_empty_until_something_is_actually_surfaced(server):
    srv, config, _ = server
    _, created = srv.request("POST", "/v1/ideas", {"title": "Quiet Idea"})
    status, body = srv.request("GET", "/v1/ideas/resurfacing")
    assert status == 200 and body["data"] == []

    with CoreStore(config.database_path) as store:
        store.remember_resurfacing(created["data"]["id"], now="2026-01-01T00:00:00+00:00", surfaced=True, score=0.9, reasons={})
    status, body = srv.request("GET", "/v1/ideas/resurfacing")
    assert status == 200 and len(body["data"]) == 1
