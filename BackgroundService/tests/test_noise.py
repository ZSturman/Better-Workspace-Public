from workspace_watcher.config import DEFAULT_IGNORE_PATTERNS
from workspace_watcher.noise import NoiseFilter


def make_filter():
    return NoiseFilter(DEFAULT_IGNORE_PATTERNS, "Logs/workspace-watcher")


def test_ignores_git_directory_contents():
    nf = make_filter()
    v = nf.classify("Projects/Foo/.git/HEAD")
    assert v.ignored
    assert v.matched_rule == ".git"


def test_ignores_node_modules_nested_deep():
    nf = make_filter()
    v = nf.classify("Projects/Foo/frontend/node_modules/react/index.js")
    assert v.ignored


def test_ignores_pycache():
    nf = make_filter()
    v = nf.classify("Projects/Foo/pkg/__pycache__/mod.cpython-314.pyc")
    assert v.ignored


def test_ignores_ds_store():
    nf = make_filter()
    v = nf.classify("Projects/Foo/.DS_Store")
    assert v.ignored


def test_ignores_xcode_derived_data_and_xcuserstate():
    nf = make_filter()
    assert nf.classify("Projects/Foo/DerivedData/x").ignored
    assert nf.classify("Projects/Foo/Foo.xcodeproj/project.xcworkspace/xcuserdata/z/x").ignored
    assert nf.classify("Projects/Foo/Foo.xcodeproj/xcuserdata/a.xcuserstate").ignored


def test_does_not_ignore_ordinary_source_file():
    nf = make_filter()
    v = nf.classify("Projects/Foo/src/main.py")
    assert not v.ignored


def test_self_exclude_watcher_data_dir():
    nf = make_filter()
    v = nf.classify("Logs/workspace-watcher/events.db")
    assert v.ignored
    assert v.matched_rule == "self_exclude:watcher_data_dir"


def test_self_exclude_does_not_swallow_sibling_logs():
    nf = make_filter()
    v = nf.classify("Logs/some-other-tool/output.txt")
    assert not v.ignored


def test_area_specific_extra_ignore_patterns():
    nf = make_filter()
    assert not nf.classify("Resources/scratch-notes/draft.md", extra_patterns=["*.bak"]).ignored
    assert nf.classify("Resources/scratch-notes/draft.bak", extra_patterns=["*.bak"]).ignored


def test_transient_temp_name_detection():
    assert NoiseFilter.is_transient_temp_name(".foo.txt.swp")
    assert NoiseFilter.is_transient_temp_name("foo.txt~")
    assert NoiseFilter.is_transient_temp_name(".#foo.txt")
    assert NoiseFilter.is_transient_temp_name("bar.tmp")
    assert not NoiseFilter.is_transient_temp_name("main.py")


def test_transient_temp_name_with_pid_hash_suffix():
    # Observed live from an Xcode-driven save: temp name doesn't end in
    # ".tmp", it has more after it.
    assert NoiseFilter.is_transient_temp_name("Entities.swift.tmp.11534.5155d16373cb")
