from pathlib import Path

from workspace_watcher.areas import classify
from workspace_watcher.config import default_config


def cfg():
    return default_config(Path("/tmp/fake-workspace"))


def test_classifies_known_area():
    m = classify("Projects/Recallable/Sources/main.swift", cfg())
    assert m.area == "Projects"
    assert m.area_kind == "projects"


def test_classifies_inbox_area():
    m = classify("Unsorted/To Organize/file.pdf", cfg())
    assert m.area_kind == "inbox"


def test_classifies_root_level_file():
    m = classify(".DS_Store", cfg())
    assert m.area_kind == "root"


def test_classifies_unknown_top_level_directory_as_generic():
    m = classify("BrandNewArea/something/file.txt", cfg())
    assert m.area == "BrandNewArea"
    assert m.area_kind == "generic"


def test_case_insensitive_area_matching():
    m = classify("projects/Foo/file.txt", cfg())
    assert m.area_kind == "projects"
