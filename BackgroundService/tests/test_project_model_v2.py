"""The shared project view model: scoring, next-action derivation, and the
detail bundle -- the one place every surface (ranked widget, per-project
widget, Finder browser, query engine) reads project state from."""

from __future__ import annotations

from datetime import datetime, timedelta, timezone

import pytest

from workspace_watcher.core_store import CoreStore
from workspace_watcher.project_model_v2 import build_project_views, project_detail

NOW = datetime(2026, 6, 1, 12, 0, tzinfo=timezone.utc)


def _iso(dt: datetime) -> str:
    return dt.isoformat()


def _make_project(store: CoreStore, project_id: str, name: str) -> None:
    store.create_project(project_id=project_id, path=f"Projects/{name}", root_path="Projects", name=name, device=1, inode=hash(project_id) % 100000, timestamp=_iso(NOW))


def _make_session(store: CoreStore, project_id: str, name: str, *, ended_at: datetime, confidence: float = 0.8, status: str = "completed", files: list[str] | None = None) -> str:
    session_id = f"s-{project_id}-{ended_at.isoformat()}"
    store.upsert_session({
        "id": session_id, "project_id": project_id, "project_name": name,
        "started_at": _iso(ended_at - timedelta(minutes=30)), "ended_at": _iso(ended_at),
        "active_seconds": 1200.0, "meaningful_event_count": 10, "files": ["a.py"] if files is None else files, "burst_count": 1,
        "intensity": 0.5, "confidence": confidence, "git": {}, "status": status, "close_reason": "switched",
        "longest_gap_seconds": 0.0, "longest_burst_seconds": 1200.0, "current_burst_started_at": None, "open_reason": "started",
        "created_at": _iso(ended_at - timedelta(minutes=30)), "updated_at": _iso(ended_at),
    })
    return session_id


def test_a_project_with_no_sessions_scores_zero(tmp_path):
    with CoreStore(tmp_path / "core.db") as store:
        _make_project(store, "p1", "Alpha")
        views = build_project_views(store, now=NOW)
        assert views[0]["score"] == 0.0
        assert views[0]["next_action"] == "Not started yet"


def test_a_recently_worked_project_outranks_a_stale_one(tmp_path):
    with CoreStore(tmp_path / "core.db") as store:
        _make_project(store, "p1", "Recent")
        _make_project(store, "p2", "Stale")
        _make_session(store, "p1", "Recent", ended_at=NOW - timedelta(hours=2))
        _make_session(store, "p2", "Stale", ended_at=NOW - timedelta(days=60))
        views = {v["name"]: v for v in build_project_views(store, now=NOW)}
        assert views["Recent"]["score"] > views["Stale"]["score"]


def test_open_goals_boost_score_and_become_the_next_action(tmp_path):
    with CoreStore(tmp_path / "core.db") as store:
        _make_project(store, "p1", "Alpha")
        _make_session(store, "p1", "Alpha", ended_at=NOW - timedelta(days=10))
        before = build_project_views(store, now=NOW)[0]

        store.replace_project_goals("p1", ["Fix the login bug", "Write tests"], session_id=None, source="user", timestamp=_iso(NOW))
        after = build_project_views(store, now=NOW)[0]

        assert after["score"] > before["score"]
        assert after["open_goals_count"] == 2
        assert after["next_action"] == "Fix the login bug (+1 more goal(s))"


def test_a_stalled_project_with_open_goals_needs_attention(tmp_path):
    with CoreStore(tmp_path / "core.db") as store:
        _make_project(store, "p1", "Alpha")
        _make_session(store, "p1", "Alpha", ended_at=NOW - timedelta(days=30))
        store.replace_project_goals("p1", ["Ship it"], session_id=None, source="user", timestamp=_iso(NOW))
        view = build_project_views(store, now=NOW)[0]
        assert view["needs_attention"] is True


def test_a_fresh_project_with_open_goals_does_not_need_attention(tmp_path):
    with CoreStore(tmp_path / "core.db") as store:
        _make_project(store, "p1", "Alpha")
        _make_session(store, "p1", "Alpha", ended_at=NOW - timedelta(hours=1))
        store.replace_project_goals("p1", ["Ship it"], session_id=None, source="user", timestamp=_iso(NOW))
        view = build_project_views(store, now=NOW)[0]
        assert view["needs_attention"] is False


def test_next_action_falls_back_to_wrapup_notes_then_to_last_touched_file(tmp_path):
    with CoreStore(tmp_path / "core.db") as store:
        _make_project(store, "p1", "Alpha")
        session_id = _make_session(store, "p1", "Alpha", ended_at=NOW - timedelta(days=1))
        view = build_project_views(store, now=NOW)[0]
        assert "a.py" in view["next_action"]

        store.record_session_wrapup({
            "session_id": session_id, "project_id": "p1", "accomplished": "Did stuff",
            "unfinished_notes": "Still need to handle the edge case with empty input", "notes": "", "created_at": _iso(NOW),
        })
        view_after = build_project_views(store, now=NOW)[0]
        assert view_after["next_action"] == "Still need to handle the edge case with empty input"


def test_project_detail_includes_goals_sessions_and_wrapups(tmp_path):
    with CoreStore(tmp_path / "core.db") as store:
        _make_project(store, "p1", "Alpha")
        session_id = _make_session(store, "p1", "Alpha", ended_at=NOW - timedelta(hours=3))
        store.replace_project_goals("p1", ["Do the thing"], session_id=session_id, source="user", timestamp=_iso(NOW))
        store.record_session_wrapup({"session_id": session_id, "project_id": "p1", "accomplished": "X", "unfinished_notes": "Y", "notes": "Z", "created_at": _iso(NOW)})

        detail = project_detail(store, "p1", now=NOW, workspace_root=tmp_path)
        assert detail is not None
        assert detail["name"] == "Alpha"
        assert detail["absolute_path"] == str((tmp_path / "Projects/Alpha").resolve())
        assert len(detail["goals"]) == 1
        assert len(detail["sessions"]) == 1
        assert len(detail["wrapups"]) == 1


def test_project_detail_returns_none_for_an_unknown_project(tmp_path):
    with CoreStore(tmp_path / "core.db") as store:
        assert project_detail(store, "does-not-exist", now=NOW) is None


def test_momentum_caps_at_one_with_five_or_more_sessions_in_the_14_day_window(tmp_path):
    with CoreStore(tmp_path / "core.db") as store:
        _make_project(store, "p1", "Alpha")
        for i in range(7):
            _make_session(store, "p1", "Alpha", ended_at=NOW - timedelta(days=i))
        view = build_project_views(store, now=NOW)[0]
        assert view["score_factors"]["momentum"] == 1.0
        assert view["sessions_recent_14d"] == 7


def test_sessions_outside_the_14_day_window_do_not_count_toward_momentum(tmp_path):
    with CoreStore(tmp_path / "core.db") as store:
        _make_project(store, "p1", "Alpha")
        _make_session(store, "p1", "Alpha", ended_at=NOW - timedelta(days=1))
        _make_session(store, "p1", "Alpha", ended_at=NOW - timedelta(days=20))
        _make_session(store, "p1", "Alpha", ended_at=NOW - timedelta(days=40))
        view = build_project_views(store, now=NOW)[0]
        assert view["sessions_recent_14d"] == 1
        assert view["score_factors"]["momentum"] == round(1 / 5, 3)


def test_confidence_factor_averages_only_the_three_most_recent_closed_sessions(tmp_path):
    with CoreStore(tmp_path / "core.db") as store:
        _make_project(store, "p1", "Alpha")
        # Oldest, low-confidence session should be excluded from the average
        # once a fourth, more recent session pushes it out of the top three.
        _make_session(store, "p1", "Alpha", ended_at=NOW - timedelta(days=10), confidence=0.1)
        _make_session(store, "p1", "Alpha", ended_at=NOW - timedelta(days=3), confidence=0.9)
        _make_session(store, "p1", "Alpha", ended_at=NOW - timedelta(days=2), confidence=0.9)
        _make_session(store, "p1", "Alpha", ended_at=NOW - timedelta(days=1), confidence=0.9)
        view = build_project_views(store, now=NOW)[0]
        assert view["score_factors"]["session_confidence"] == 0.9


def test_an_open_session_is_excluded_from_the_confidence_average(tmp_path):
    with CoreStore(tmp_path / "core.db") as store:
        _make_project(store, "p1", "Alpha")
        _make_session(store, "p1", "Alpha", ended_at=NOW - timedelta(days=2), confidence=0.8)
        store.upsert_session({
            "id": "open-1", "project_id": "p1", "project_name": "Alpha",
            "started_at": _iso(NOW), "ended_at": _iso(NOW), "active_seconds": 0,
            "meaningful_event_count": 1, "files": [], "burst_count": 1, "intensity": 0,
            "confidence": 0.0, "git": {}, "status": "open", "close_reason": None,
            "longest_gap_seconds": 0.0, "longest_burst_seconds": 0.0,
            "current_burst_started_at": None, "open_reason": "started",
            "created_at": _iso(NOW), "updated_at": _iso(NOW),
        })
        view = build_project_views(store, now=NOW)[0]
        # If the open session (confidence 0.0) leaked into the average this
        # would be 0.4, not the single closed session's own confidence.
        assert view["score_factors"]["session_confidence"] == 0.8


def test_recency_factor_is_exactly_half_at_the_configured_half_life(tmp_path):
    from workspace_watcher.project_model_v2 import RECENCY_HALF_LIFE_DAYS
    with CoreStore(tmp_path / "core.db") as store:
        _make_project(store, "p1", "Alpha")
        _make_session(store, "p1", "Alpha", ended_at=NOW - timedelta(days=RECENCY_HALF_LIFE_DAYS))
        view = build_project_views(store, now=NOW)[0]
        assert view["score_factors"]["recency"] == 0.5


def test_score_is_the_weighted_sum_of_its_published_factors(tmp_path):
    with CoreStore(tmp_path / "core.db") as store:
        _make_project(store, "p1", "Alpha")
        _make_session(store, "p1", "Alpha", ended_at=NOW - timedelta(hours=1), confidence=0.6)
        store.replace_project_goals("p1", ["Ship it"], session_id=None, source="user", timestamp=_iso(NOW))
        view = build_project_views(store, now=NOW)[0]
        factors = view["score_factors"]
        weights = factors["weights"]
        expected = round(100 * (
            weights["recency"] * factors["recency"]
            + weights["momentum"] * factors["momentum"]
            + weights["unfinished_work"] * factors["unfinished_work"]
            + weights["session_confidence"] * factors["session_confidence"]
        ), 1)
        # Published factors are pre-rounded to 3 decimals for display, so
        # reconstructing the score from them can be off by a rounding hair
        # versus the unrounded internal computation -- allow that slack.
        assert view["score"] == pytest.approx(expected, abs=0.1)


def test_current_project_and_active_session_flags_are_accurate(tmp_path):
    with CoreStore(tmp_path / "core.db") as store:
        _make_project(store, "p1", "Alpha")
        _make_project(store, "p2", "Beta")
        store.set_state("project.current", {"project_id": "p1", "name": "Alpha", "path": "Projects/Alpha"}, _iso(NOW))
        store.upsert_session({
            "id": "open-1", "project_id": "p1", "project_name": "Alpha", "started_at": _iso(NOW), "ended_at": _iso(NOW),
            "active_seconds": 0, "meaningful_event_count": 1, "files": [], "burst_count": 1, "intensity": 0, "confidence": 0,
            "git": {}, "status": "open", "close_reason": None,
            "longest_gap_seconds": 0.0, "longest_burst_seconds": 0.0, "current_burst_started_at": None, "open_reason": "started",
            "created_at": _iso(NOW), "updated_at": _iso(NOW),
        })
        views = {v["name"]: v for v in build_project_views(store, now=NOW)}
        assert views["Alpha"]["is_current"] is True
        assert views["Alpha"]["has_active_session"] is True
        assert views["Beta"]["is_current"] is False
        assert views["Beta"]["has_active_session"] is False


@pytest.mark.parametrize("files", [
    ["Project.betterproject"],
    [".DS_Store"],
    ["src/.git/index"],
    ["node_modules/left-pad/index.js"],
])
def test_next_action_never_cites_a_file_the_person_did_not_write(tmp_path, files):
    """Against the real portfolio almost every project reported "last touched
    Project.betterproject" -- metadata the Better Projects app writes by
    itself. Naming it tells a person nothing about where they left off."""
    with CoreStore(tmp_path / "core.db") as store:
        _make_project(store, "p1", "Alpha")
        _make_session(store, "p1", "Alpha", ended_at=NOW - timedelta(days=1), files=files)
        assert build_project_views(store, now=NOW)[0]["next_action"] == "Resume where you left off"


def test_next_action_names_the_last_real_file_even_after_background_writes(tmp_path):
    with CoreStore(tmp_path / "core.db") as store:
        _make_project(store, "p1", "Alpha")
        _make_session(store, "p1", "Alpha", ended_at=NOW - timedelta(days=1),
                      files=["src/main.py", "Project.betterproject", ".DS_Store"])
        assert build_project_views(store, now=NOW)[0]["next_action"] == "Resume: last touched main.py"
