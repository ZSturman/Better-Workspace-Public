"""Read-only project folder browsing, and the containment rules that keep it
from becoming a way to read arbitrary files through the local API."""

from __future__ import annotations

import pytest

from workspace_watcher.project_files import (
    MAX_ENTRIES, ProjectFilesError, list_directory, notion_page_url, resolve_within,
)


@pytest.fixture
def project(tmp_path):
    root = tmp_path / "Projects" / "Demo"
    (root / "src").mkdir(parents=True)
    (root / "node_modules" / "left-pad").mkdir(parents=True)
    (root / "src" / "main.py").write_text("print('hi')\n")
    (root / "README.md").write_text("# Demo\n")
    (root / ".DS_Store").write_bytes(b"\x00")
    (tmp_path / "secret.txt").write_text("not part of the project")
    return root


def test_lists_one_level_folders_first(project):
    listing = list_directory(project)
    assert [entry["name"] for entry in listing["entries"]] == [
        "node_modules", "src", ".DS_Store", "README.md",
    ]
    assert listing["relative_path"] == "" and listing["parent_path"] is None
    src = next(entry for entry in listing["entries"] if entry["name"] == "src")
    assert src["is_directory"] and src["size_bytes"] is None
    readme = next(entry for entry in listing["entries"] if entry["name"] == "README.md")
    assert readme["size_bytes"] == len("# Demo\n")


def test_descends_into_a_subdirectory(project):
    listing = list_directory(project, "src")
    assert [entry["name"] for entry in listing["entries"]] == ["main.py"]
    assert listing["relative_path"] == "src" and listing["parent_path"] == ""


def test_generated_directories_are_flagged_not_hidden(project):
    """Hiding them would make the listing disagree with Finder; the flag lets
    the UI de-emphasize them while still showing what is really there."""
    listing = list_directory(project, ignore_patterns=["node_modules", ".DS_Store"])
    flags = {entry["name"]: entry["ignored"] for entry in listing["entries"]}
    assert flags == {"node_modules": True, ".DS_Store": True, "src": False, "README.md": False}
    # With no configured patterns nothing is presumed to be noise.
    assert all(not entry["ignored"] for entry in list_directory(project)["entries"])


@pytest.mark.parametrize("escape", ["..", "../..", "../secret.txt", "src/../../secret.txt", "/etc"])
def test_paths_outside_the_project_are_refused(project, escape):
    with pytest.raises(ProjectFilesError):
        resolve_within(project, escape)


def test_a_symlink_out_of_the_project_is_refused(project):
    (project / "escape").symlink_to(project.parent.parent / "secret.txt")
    # The link itself is listed (it really is in the folder) ...
    assert any(entry["name"] == "escape" and entry["is_symlink"] for entry in list_directory(project)["entries"])
    # ... but it cannot be used to read through to its target.
    with pytest.raises(ProjectFilesError):
        resolve_within(project, "escape")


def test_missing_paths_and_files_are_reported_distinctly(project):
    with pytest.raises(ProjectFilesError, match="does not exist"):
        list_directory(project, "nope")
    with pytest.raises(ProjectFilesError, match="not a directory"):
        list_directory(project, "README.md")


def test_a_huge_directory_is_bounded_and_says_so(project):
    crowded = project / "many"
    crowded.mkdir()
    for index in range(MAX_ENTRIES + 25):
        (crowded / f"file-{index:04d}").write_text("")
    listing = list_directory(project, "many")
    assert listing["truncated"] and len(listing["entries"]) == MAX_ENTRIES


def test_a_vanished_entry_does_not_fail_the_listing(project, monkeypatch):
    """A build deleting files while the folder is being listed must not turn
    an ordinary browse into an error."""
    import os
    real_stat = os.DirEntry.stat

    def flaky(self, *, follow_symlinks=True):
        if self.name == "README.md":
            raise OSError("vanished")
        return real_stat(self, follow_symlinks=follow_symlinks)

    monkeypatch.setattr(os.DirEntry, "stat", flaky)
    assert "README.md" not in [entry["name"] for entry in list_directory(project)["entries"]]


@pytest.mark.parametrize("value", [None, "", "not-an-id", "3e7aec94", "3e7aec94-4d3c-808e-9798-d65ba59a78dZ"])
def test_a_malformed_notion_id_produces_no_link(value):
    """Better no button than one that opens a broken Notion page."""
    assert notion_page_url(value) is None


def test_a_real_notion_id_becomes_a_page_url():
    assert notion_page_url("3e7aec94-4d3c-808e-9798-d65ba59a78d9") == "https://www.notion.so/3e7aec944d3c808e9798d65ba59a78d9"
