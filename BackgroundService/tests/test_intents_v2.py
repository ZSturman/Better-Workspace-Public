from __future__ import annotations

from pathlib import Path

from workspace_watcher.intents import IntentFolderDetector, IntentFolderSettings, normalize_roots, validate_intent_config
from workspace_watcher.item_records import ITEM_FILENAME, initialize_item_record, parse_item_record


def detector(root: Path) -> IntentFolderDetector:
    return IntentFolderDetector(IntentFolderSettings.for_workspace(root))


def test_default_roots_are_normalized_and_discover_expected_locations(tmp_path):
    for path in (tmp_path / "[[Inbox]]", tmp_path / "Temporary" / "[[Ideas]]", tmp_path / "Projects" / "[[To Test]]"):
        path.mkdir(parents=True)
    found = {(folder.name, folder.path.name) for folder in detector(tmp_path).discover()}
    assert found == {("Inbox", "[[Inbox]]"), ("Ideas", "[[Ideas]]"), ("To Test", "[[To Test]]")}
    roots = normalize_roots([tmp_path, tmp_path / "Temporary", tmp_path / "Projects"])
    assert roots == [tmp_path.resolve()]


def test_next_route_candidates_are_excluded_but_non_route_brackets_are_not(tmp_path):
    route = tmp_path / "Projects" / "NextBasic" / "app" / "blog" / "[[...slug]]"
    route.mkdir(parents=True)
    (route.parents[2] / "next.config.ts").write_text("export default {}")
    src_route = tmp_path / "Projects" / "NextSrc" / "src" / "app" / "docs" / "[[...params]]"
    src_route.mkdir(parents=True)
    (src_route.parents[3] / "package.json").write_text('{"dependencies":{"next":"latest"}}')
    non_next = tmp_path / "Projects" / "Plain" / "docs" / "[[Research]]"
    non_next.mkdir(parents=True)
    found = {folder.name for folder in detector(tmp_path).discover()}
    assert found == {"Research"}
    explanation = detector(tmp_path).explain(route)
    assert not explanation.is_intent and explanation.reason == "Next.js route directory"
    assert "MATCH Next.js route tree" in explanation.checks


def test_item_record_is_atomic_and_preserves_generated_identity(tmp_path):
    item = tmp_path / "[[Ideas]]" / "Voice Dashboard"
    first = initialize_item_record(item)
    second = initialize_item_record(item)
    assert first.id == second.id
    assert (item / ITEM_FILENAME).exists()
    assert parse_item_record(item / ITEM_FILENAME).title == "Voice Dashboard"


def test_intent_configuration_has_a_small_versioned_validation_contract():
    validate_intent_config({"schema_version": 1, "intent": {"id": "ideas"}, "resurfacing": {"minimum_days_between": 7}})
    import pytest
    with pytest.raises(ValueError, match="non-negative"):
        validate_intent_config({"schema_version": 1, "resurfacing": {"minimum_days_between": -1}})
