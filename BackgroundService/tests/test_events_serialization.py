import json

from workspace_watcher.events import EventType, NormalizedEvent


def test_round_trips_through_json():
    event = NormalizedEvent(
        type=EventType.CREATED,
        path="Projects/Foo/main.py",
        is_directory=False,
        area="Projects",
        area_kind="projects",
        meaningful=True,
        project_id="abc-123",
        project_name="Foo",
    )
    payload = json.loads(event.to_json())
    assert payload["path"] == "Projects/Foo/main.py"
    assert payload["type"] == "created"
    assert payload["project_id"] == "abc-123"
    assert payload["meaningful"] is True
    assert "event_id" in payload and "ts_iso" in payload


def test_summary_marks_ignored_events():
    event = NormalizedEvent(
        type=EventType.CREATED, path="Projects/Foo/.git/HEAD", is_directory=False,
        area="Projects", area_kind="projects", meaningful=False, matched_rule=".git",
    )
    assert "[ignored:.git]" in event.summary()


def test_summary_shows_rename_arrow():
    event = NormalizedEvent(
        type=EventType.RENAMED, path="Projects/Foo/new.py", prev_path="Projects/Foo/old.py",
        is_directory=False, area="Projects", area_kind="projects", meaningful=True,
    )
    assert "-> Projects/Foo/old.py" in event.summary()
