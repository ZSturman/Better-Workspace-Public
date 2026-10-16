"""Plain-named folders declared in config are intent folders.

Better Workspace names its top-level folders plainly ("Ideas", "For Inspiration").
When the ``[[Ideas]]`` folders were renamed that way on 2026-09-28, discovery found
nothing, and ideas, resurfacing and due-item attention all went quiet without an error.
"""

from pathlib import Path

from workspace_watcher.core_config import load_core_config
from workspace_watcher.intents import IntentFolderDetector, IntentFolderSettings


def _settings(root: Path, declared: dict[str, str]) -> IntentFolderSettings:
    return IntentFolderSettings(
        search_roots=(root,),
        declared=tuple((root / folder, name) for folder, name in declared.items()),
    )


def test_a_declared_plain_folder_is_discovered_under_its_intent_name(tmp_path: Path) -> None:
    (tmp_path / "Ideas" / "A thought").mkdir(parents=True)
    (tmp_path / "For Inspiration").mkdir()
    (tmp_path / "Projects" / "Thing").mkdir(parents=True)
    detector = IntentFolderDetector(_settings(tmp_path, {"Ideas": "Ideas", "For Inspiration": "Inspiration"}))

    found = {folder.path.name: folder.name for folder in detector.discover()}

    assert found == {"Ideas": "Ideas", "For Inspiration": "Inspiration"}
    assert detector.explain(tmp_path / "Ideas").reason == "declared intent folder"


def test_bracket_syntax_still_works_beside_declared_folders(tmp_path: Path) -> None:
    (tmp_path / "Ideas").mkdir()
    (tmp_path / "Temporary" / "[[Review]]").mkdir(parents=True)
    detector = IntentFolderDetector(_settings(tmp_path, {"Ideas": "Ideas"}))

    assert sorted(folder.name for folder in detector.discover()) == ["Ideas", "Review"]


def test_a_bracket_folder_inside_a_declared_one_is_nested_and_ignored(tmp_path: Path) -> None:
    (tmp_path / "Ideas" / "[[Inner]]").mkdir(parents=True)
    detector = IntentFolderDetector(_settings(tmp_path, {"Ideas": "Ideas"}))

    assert [folder.name for folder in detector.discover()] == ["Ideas"]
    assert detector.explain(tmp_path / "Ideas" / "[[Inner]]").is_intent is False


def test_a_missing_declared_folder_is_not_an_intent_folder(tmp_path: Path) -> None:
    detector = IntentFolderDetector(_settings(tmp_path, {"Ideas": "Ideas"}))

    assert list(detector.discover()) == []
    assert detector.explain(tmp_path / "Ideas").reason == "declared intent folder is missing"


def test_declared_folders_are_read_from_config_relative_to_the_workspace(tmp_path: Path) -> None:
    workspace = tmp_path / "Workspace"
    (workspace / "Ideas").mkdir(parents=True)
    config = tmp_path / "config.toml"
    config.write_text(
        f'[workspace_watcher]\nworkspace_root = "{workspace}"\n'
        '[workspace_watcher.intent_folders.declared]\n"Ideas" = "Ideas"\n',
        encoding="utf-8",
    )

    settings = load_core_config(config).intent_settings

    assert settings.declared == ((workspace / "Ideas", "Ideas"),)
