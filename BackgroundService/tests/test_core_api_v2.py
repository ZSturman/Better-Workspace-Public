"""Real HTTP integration tests for the v2 project-browsing/query,
domain/tags, goals, session-lifecycle, and saved-views endpoints -- a real
`ThreadingHTTPServer` on an OS-assigned port, real `urllib` requests, no
mocking of the routing layer itself. `core_api.py` had zero test coverage
before this; the routing here is string-split-based and easy to get subtly
wrong (an earlier draft of `/goals/add` mis-parsed its own project id), so
this exercises the real HTTP path end to end."""

from __future__ import annotations

import json
import threading
import urllib.error
import urllib.request
from pathlib import Path

import pytest

from workspace_watcher.core_api import serve
from workspace_watcher.core_config import CoreConfig, HammerspoonInboxSettings, ProjectsSettings, SessionsSettings, WorkLogsSettings
from workspace_watcher.core_runtime import CoreRuntime
from workspace_watcher.core_store import CoreStore
from workspace_watcher.intents import IntentFolderSettings


def _config(root: Path, **overrides) -> CoreConfig:
    return CoreConfig(
        root, root / "Logs/workspace-watcher/core.db", IntentFolderSettings.for_workspace(root),
        root / "config.toml", root / "rules.toml", 0.1,
        HammerspoonInboxSettings(enabled=False, path=root / "inbox.jsonl"),
        ProjectsSettings(enabled=True, root="Projects"),
        SessionsSettings(**overrides.pop("sessions", {})) if overrides.get("sessions") else SessionsSettings(),
    )


class _Server:
    """Starts a real server on an OS-assigned free port and tears it down
    cleanly; requests go over real sockets against 127.0.0.1."""

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
    config = _config(tmp_path)
    with CoreStore(config.database_path):
        pass  # create the schema before the server's own per-request CoreStore opens it
    srv = _Server(config)
    yield srv, config
    srv.close()


def _make_project(config: CoreConfig, project_id: str, name: str) -> None:
    with CoreStore(config.database_path) as store:
        store.create_project(project_id=project_id, path=f"Projects/{name}", root_path="Projects", name=name, device=1, inode=hash(project_id) % 100000, timestamp="2026-01-01T00:00:00+00:00")


def test_ranked_projects_returns_scored_real_data_not_a_fabricated_list(server):
    srv, config = server
    _make_project(config, "p1", "Alpha")
    status, body = srv.request("GET", "/v1/projects/ranked")
    assert status == 200
    assert body["data"][0]["name"] == "Alpha"
    assert body["data"][0]["score"] == 0.0  # no sessions yet -- real, not guessed


def test_widget_snapshot_is_versioned_and_uses_the_existing_projection(server):
    srv, config = server
    _make_project(config, "p1", "Alpha")
    with CoreStore(config.database_path) as store:
        store.replace_project_goals("p1", ["Ship it"], session_id=None, source="test", timestamp="2026-01-01T00:00:00+00:00")
    status, body = srv.request("GET", "/v1/widgets/snapshot")
    assert status == 200
    snapshot = body["data"]
    assert snapshot["schema_version"] == 1
    assert snapshot["projects"][0]["next_action"] == "Ship it"
    assert "metadata_json" not in json.dumps(snapshot)


def test_project_query_compound_filter_over_http(server):
    srv, config = server
    _make_project(config, "p1", "Alpha")
    _make_project(config, "p2", "Beta")
    with CoreStore(config.database_path) as store:
        store.set_project_domain("p1", "Software", "2026-01-01T00:00:00+00:00")
        store.set_project_domain("p2", "Writing", "2026-01-01T00:00:00+00:00")
    status, body = srv.request("POST", "/v1/projects/query", {"query": {"field": "domain", "op": "eq", "value": "Software"}})
    assert status == 200
    assert [p["name"] for p in body["data"]["projects"]] == ["Alpha"]
    assert body["data"]["count"] == 1


def test_project_query_with_grouping(server):
    srv, config = server
    _make_project(config, "p1", "Alpha")
    _make_project(config, "p2", "Beta")
    with CoreStore(config.database_path) as store:
        store.set_project_domain("p1", "Software", "2026-01-01T00:00:00+00:00")
    status, body = srv.request("POST", "/v1/projects/query", {"group_by": "domain"})
    assert status == 200
    assert "Software" in body["data"]["groups"]
    assert "(none)" in body["data"]["groups"]


def test_project_detail_404s_for_an_unknown_project(server):
    srv, _ = server
    status, body = srv.request("GET", "/v1/projects/does-not-exist")
    assert status == 404


def test_project_detail_returns_the_full_bundle(server):
    srv, config = server
    _make_project(config, "p1", "Alpha")
    status, body = srv.request("GET", "/v1/projects/p1")
    assert status == 200
    assert body["data"]["name"] == "Alpha"
    assert body["data"]["goals"] == []
    assert body["data"]["sessions"] == []


def test_setting_and_removing_a_project_domain(server):
    srv, config = server
    _make_project(config, "p1", "Alpha")
    status, _ = srv.request("POST", "/v1/projects/p1/domain", {"domain": "Software"})
    assert status == 200
    _, detail = srv.request("GET", "/v1/projects/p1")
    assert detail["data"]["domain"] == "Software"

    srv.request("POST", "/v1/projects/p1/domain", {"domain": None})
    _, detail_after = srv.request("GET", "/v1/projects/p1")
    assert detail_after["data"]["domain"] is None


def test_assigning_and_removing_a_project_tag(server):
    srv, config = server
    _make_project(config, "p1", "Alpha")
    status, body = srv.request("POST", "/v1/projects/p1/tags", {"tag": "AI"})
    assert status == 200
    tag_id = body["data"]["tag"]["id"]

    _, detail = srv.request("GET", "/v1/projects/p1")
    assert detail["data"]["tags"] == [{"id": tag_id, "display": "AI"}]

    status, removed = srv.request("DELETE", f"/v1/projects/p1/tags/{tag_id}")
    assert removed["data"]["removed"] is True
    _, detail_after = srv.request("GET", "/v1/projects/p1")
    assert detail_after["data"]["tags"] == []


def test_reassigning_an_existing_tag_by_id_reuses_it_not_a_duplicate(server):
    srv, config = server
    _make_project(config, "p1", "Alpha")
    _, first = srv.request("POST", "/v1/projects/p1/tags", {"tag": "AI"})
    tag_id = first["data"]["tag"]["id"]
    _make_project(config, "p2", "Beta")
    status, second = srv.request("POST", "/v1/projects/p2/tags", {"tag_id": tag_id})
    assert status == 200
    with CoreStore(config.database_path) as store:
        assert len(store.tags()) == 1  # not a second "AI" tag


def test_full_goal_lifecycle_over_http(server):
    srv, config = server
    _make_project(config, "p1", "Alpha")
    status, goals = srv.request("POST", "/v1/projects/p1/goals", {"goals": ["Fix the bug", "Write docs"]})
    assert status == 200 and len(goals["data"]) == 2
    goal_id = goals["data"][0]["id"]

    status, updated = srv.request("PATCH", f"/v1/goals/{goal_id}", {"completed": True})
    assert status == 200 and updated["data"]["completed"] == 1

    status, added = srv.request("POST", "/v1/projects/p1/goals/add", {"text": "One more thing"})
    assert status == 201
    assert added["data"]["project_id"] == "p1"  # the earlier parsing bug would have produced "goals" here

    _, live_goals = srv.request("GET", "/v1/projects/p1/goals")
    assert len(live_goals["data"]) == 3

    status, deleted = srv.request("DELETE", f"/v1/goals/{goal_id}")
    assert deleted["data"]["removed"] is True


def test_patching_an_unknown_goal_404s(server):
    srv, _ = server
    status, _ = srv.request("PATCH", "/v1/goals/does-not-exist", {"completed": True})
    assert status == 404


def test_session_live_reports_inactive_with_no_open_session(server):
    srv, _ = server
    status, body = srv.request("GET", "/v1/session/live")
    assert status == 200
    assert body["data"]["active"] is False


def test_session_end_requires_a_running_runtime(server):
    srv, _ = server
    status, body = srv.request("POST", "/v1/session/end", {})
    assert status == 400
    assert "running backend" in body["data"]["error"]


def test_session_end_via_a_real_runtime_closes_the_open_session(tmp_path):
    config = _config(tmp_path)
    runtime = CoreRuntime(config)
    runtime.reload_rules()
    from workspace_watcher.coalescer import Settled
    import time
    (tmp_path / "Projects" / "Alpha").mkdir(parents=True)
    runtime._on_settled(Settled(kind="created", path="Projects/Alpha/a.py", prev_path=None, is_directory=False, raw_event_count=1, ts=time.time()))
    assert runtime.store.open_session() is not None

    srv = _Server(config, runtime=runtime)
    try:
        status, body = srv.request("POST", "/v1/session/end", {"reason": "user_ended"})
        assert status == 200
        assert body["data"]["close_reason"] == "user_ended"
        assert runtime.store.open_session() is None
    finally:
        srv.close()


def test_session_wrapup_records_notes_and_sets_next_session_goals(server):
    srv, config = server
    _make_project(config, "p1", "Alpha")
    with CoreStore(config.database_path) as store:
        store.upsert_session({
            "id": "s1", "project_id": "p1", "project_name": "Alpha", "started_at": "2026-01-01T00:00:00+00:00", "ended_at": "2026-01-01T01:00:00+00:00",
            "active_seconds": 3600, "meaningful_event_count": 10, "files": [], "burst_count": 1, "intensity": 0.5, "confidence": 0.8,
            "git": {}, "status": "completed", "close_reason": "switched", "longest_gap_seconds": 0, "longest_burst_seconds": 3600,
            "current_burst_started_at": None, "open_reason": "started", "created_at": "2026-01-01T00:00:00+00:00", "updated_at": "2026-01-01T01:00:00+00:00",
        })
    status, body = srv.request("POST", "/v1/session/wrapup", {
        "project_id": "p1", "accomplished": "Fixed the bug", "unfinished_notes": "Tests still needed",
        "notes": "Good progress", "next_session_goals": ["Write the tests", "Deploy"],
    })
    assert status == 200
    assert body["data"]["session_id"] == "s1"

    _, detail = srv.request("GET", "/v1/projects/p1")
    assert len(detail["data"]["goals"]) == 2
    assert detail["data"]["wrapups"][0]["accomplished"] == "Fixed the bug"
    assert detail["data"]["next_action"] == "Write the tests (+1 more goal(s))"


def test_saved_views_crud_and_built_in_protection(server):
    srv, _ = server
    status, views = srv.request("GET", "/v1/saved-views")
    assert status == 200
    assert len(views["data"]) == 7
    builtin_id = views["data"][0]["id"]

    status, created = srv.request("POST", "/v1/saved-views", {"name": "My View", "query": {"field": "score", "op": "gt", "value": 50}})
    assert status == 201
    view_id = created["data"]["id"]

    status, updated = srv.request("PATCH", f"/v1/saved-views/{view_id}", {"name": "Renamed"})
    assert status == 200 and updated["data"]["name"] == "Renamed"

    status, delete_result = srv.request("DELETE", f"/v1/saved-views/{view_id}")
    assert status == 200 and delete_result["data"]["removed"] is True

    status, protect_result = srv.request("DELETE", f"/v1/saved-views/{builtin_id}")
    assert status == 403


def test_widget_snapshot_does_not_wait_on_the_pipeline_lock(tmp_path):
    """WidgetKit gives a provider very little time, and the pipeline lock is
    held by the tick loop for the whole of its work -- including a Notion sync
    over the network. Asking the runtime to republish from this route made it
    take 58 seconds against the real workspace, so every widget permanently
    showed "Waiting for Workspace Watcher". The tick loop republishes anyway.
    """
    import threading
    from workspace_watcher.core_runtime import CoreRuntime

    config = _config(tmp_path)
    (tmp_path / "Projects" / "Alpha").mkdir(parents=True)
    runtime = CoreRuntime(config)
    srv = _Server(config, runtime=runtime)
    try:
        # Hold the pipeline lock for longer than any widget request may take.
        holding = threading.Event()
        release = threading.Event()

        def hog():
            with runtime._lock:
                holding.set()
                release.wait(timeout=10)

        thread = threading.Thread(target=hog, daemon=True)
        thread.start()
        assert holding.wait(timeout=5)
        try:
            status, body = srv.request("GET", "/v1/widgets/snapshot")
        finally:
            release.set()
            thread.join(timeout=5)
        assert status == 200
        assert body["data"]["schema_version"] == 1
    finally:
        srv.close()
        runtime.store.close()


def test_project_graph_writer_handoff_is_explicit_and_stops_both_writers(tmp_path):
    config = _config(tmp_path)
    runtime = CoreRuntime(config)
    srv = _Server(config, runtime=runtime)
    try:
        status, _ = srv.request("POST", "/v1/notion/project-graph-writer", {"owner": "unknown"})
        assert status == 400
        assert runtime.store.get_state("project_graph.writer") is None
        status, body = srv.request("POST", "/v1/notion/project-graph-writer", {"owner": "better-workspace"})
        assert status == 200
        assert body["data"]["owner"] == "better-workspace"
        assert runtime._sync_ideas() == {"skipped": True, "reason": "project graph owns Notion writes"}
        with pytest.raises(ValueError, match="reviewed Send"):
            runtime.sync_ideas_now()
        assert runtime._sync_work_logs() is None
        status, body = srv.request("GET", "/v1/notion/project-graph-writer")
        assert status == 200
        assert body["data"]["owner"] == "better-workspace"
    finally:
        srv.close()
        runtime.project_graph_poller.stop()
        runtime.store.close()


def test_project_graph_link_acknowledgement_is_bound_and_rejects_rebinding(tmp_path):
    from workspace_watcher.ideas_v2 import create_idea
    config = _config(tmp_path)
    runtime = CoreRuntime(config)
    folder = tmp_path / "Ideas"
    folder.mkdir()
    runtime.store.upsert_intent_folder(folder_id="ideas", path=str(folder), root_path=str(tmp_path), name="Ideas", config={}, timestamp="2026-10-03T00:00:00Z")
    idea = create_idea(runtime.store, folder, "Sync identity")
    srv = _Server(config, runtime=runtime)
    try:
        payload = {"kind": "ideas", "record_id": idea["id"], "page_id": "page-a"}
        status, _ = srv.request("POST", "/v1/notion/project-graph-link", payload)
        assert status == 400
        srv.request("POST", "/v1/notion/project-graph-writer", {"owner": "better-workspace"})
        status, body = srv.request("POST", "/v1/notion/project-graph-link", payload)
        assert status == 200, body
        assert runtime.store.idea_notion_link(idea["id"])["notion_page_id"] == "page-a"
        status, body = srv.request("PATCH", "/v1/ideas/" + idea["id"], {"related_projects": ["Notion-only project"]})
        assert status == 200, body
        assert body["data"]["related_projects"] == ["Notion-only project"]
        payload["page_id"] = "page-b"
        status, _ = srv.request("POST", "/v1/notion/project-graph-link", payload)
        assert status == 400
        assert runtime.store.idea_notion_link(idea["id"])["notion_page_id"] == "page-a"
    finally:
        srv.close()
        runtime.project_graph_poller.stop()
        runtime.store.close()
