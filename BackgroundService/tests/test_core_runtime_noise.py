"""Generated and background writes must not become work activity.

The v1 watcher classified every settled path against the ignore rules before
letting it draw activity conclusions.  The v2 cutover kept the rules and the
`[ignore]` config but stopped consulting them, so a Finder browse
(`.DS_Store`), a running dev server (`.sites-runtime/...`) and `.git`
bookkeeping all recorded observed session hours -- and, because any touch
re-activates its project, a single background writer repeatedly stole the
active project from whatever was really being edited.

These tests drive `_on_settled` directly rather than a real observer: the
question is what the runtime concludes from a settled event, which needs no
filesystem timing.
"""

from __future__ import annotations

from pathlib import Path

import pytest

from workspace_watcher.coalescer import Settled
from workspace_watcher.core_config import CoreConfig, load_core_config
from workspace_watcher.core_runtime import CoreRuntime
from workspace_watcher.intents import IntentFolderSettings


def runtime_for(root: Path, **overrides) -> CoreRuntime:
    config = CoreConfig(
        root, root / "Logs/workspace-watcher/core.db",
        IntentFolderSettings.for_workspace(root),
        root / "config.toml", root / "rules.toml", 0.1, **overrides,
    )
    return CoreRuntime(config)


def settled(path: str, *, kind: str = "modified", is_directory: bool = False) -> Settled:
    return Settled(kind=kind, path=path, prev_path=None, is_directory=is_directory, raw_event_count=1, ts=0.0)


@pytest.fixture
def workspace(tmp_path):
    (tmp_path / "Projects" / "Real Work" / "src").mkdir(parents=True)
    (tmp_path / "Projects" / "Noisy" / ".sites-runtime" / "wrangler" / "dev-registry").mkdir(parents=True)
    (tmp_path / "Logs" / "workspace-watcher").mkdir(parents=True)
    return tmp_path


# Exactly the shapes that produced observed hours in the real database.
NOISE_PATHS = [
    "Projects/Noisy/.DS_Store",
    "Projects/Noisy/.sites-runtime/wrangler/dev-registry/site-creator",
    "Projects/Noisy/.git/FETCH_HEAD",
    "Projects/Noisy/.git/index",
    "Projects/Noisy/node_modules/left-pad/index.js",
    "Projects/Noisy/.wrangler/registry/worker",
    "Projects/Noisy/src/__pycache__/x.pyc",
    "Projects/Noisy/.next/build-manifest.json",
]


@pytest.mark.parametrize("path", NOISE_PATHS)
def test_background_writes_start_no_session_and_do_not_activate(workspace, path):
    runtime = runtime_for(workspace)
    runtime._on_settled(settled(path))
    assert runtime.store.open_session() is None
    assert runtime.store.get_state("project.current") is None


def test_real_source_edit_starts_a_session(workspace):
    runtime = runtime_for(workspace)
    runtime._on_settled(settled("Projects/Real Work/src/main.py"))
    session = runtime.store.open_session()
    assert session is not None
    assert session["project_name"] == "Real Work"
    assert runtime.store.get_state("project.current")["name"] == "Real Work"


def test_directory_modified_is_redundant_with_the_child_write(workspace):
    """A directory's own mtime bump is implied by the change inside it."""
    runtime = runtime_for(workspace)
    runtime._on_settled(settled("Projects/Real Work/src", kind="modified", is_directory=True))
    assert runtime.store.open_session() is None
    assert runtime._ignored_counts["directory_modified_redundant"] == 1


def test_bulk_change_still_counts_as_real_activity(workspace):
    """`bulk_change` is directory-shaped only because many child writes were
    deliberately collapsed into one event; it is not a redundant mtime bump."""
    runtime = runtime_for(workspace)
    runtime._on_settled(settled("Projects/Real Work", kind="bulk_change", is_directory=True))
    assert runtime.store.open_session() is not None


def test_noise_does_not_steal_the_active_project_from_real_work(workspace):
    """The regression that fragmented real sessions: a dev server writing
    every few seconds flipped `project.current` back and forth, closing the
    genuine session as `switched` over and over."""
    runtime = runtime_for(workspace)
    runtime._on_settled(settled("Projects/Real Work/src/main.py"))
    started = runtime.store.open_session()["id"]
    for _ in range(5):
        runtime._on_settled(settled("Projects/Noisy/.sites-runtime/wrangler/dev-registry/site-creator"))
    still_open = runtime.store.open_session()
    assert still_open is not None and still_open["id"] == started
    assert runtime.store.get_state("project.current")["name"] == "Real Work"


def test_watcher_never_observes_its_own_database_writes(workspace):
    """Self-exclusion is derived from the configured database location, so a
    relocated database cannot feed the watcher its own activity."""
    (workspace / "Projects" / "Real Work" / "wwdata").mkdir()
    runtime = runtime_for(workspace.parent, )  # unrelated root -> falls back to the default
    assert runtime.noise.classify("Logs/workspace-watcher/core.db").ignored

    config = CoreConfig(
        workspace, workspace / "Projects/Real Work/wwdata/core.db",
        IntentFolderSettings.for_workspace(workspace), workspace / "config.toml",
        workspace / "rules.toml", 0.1,
    )
    relocated = CoreRuntime(config)
    assert relocated.noise.classify("Projects/Real Work/wwdata/core.db-wal").ignored
    relocated._on_settled(settled("Projects/Real Work/wwdata/core.db-wal"))
    assert relocated.store.open_session() is None


def test_ignored_counts_are_published_for_inspection(workspace):
    runtime = runtime_for(workspace)
    runtime._on_settled(settled("Projects/Noisy/.DS_Store"))
    runtime._on_settled(settled("Projects/Noisy/.git/index"))
    runtime._publish_noise_stats()
    state = runtime.store.get_state("noise.ignored_counts")
    assert state["total"] == 2
    assert state["by_rule"] == {".DS_Store": 1, ".git": 1}


def test_ignore_config_extends_and_replaces_the_built_in_list(tmp_path):
    (tmp_path / "config.toml").write_text(
        '[workspace_watcher]\nworkspace_root = "%s"\n\n[ignore]\nextend = ["Vendored"]\n' % tmp_path
    )
    config = load_core_config(tmp_path / "config.toml")
    assert "Vendored" in config.ignore_patterns and ".DS_Store" in config.ignore_patterns

    (tmp_path / "replace.toml").write_text(
        '[workspace_watcher]\nworkspace_root = "%s"\n\n[ignore]\npatterns = ["OnlyThis"]\n' % tmp_path
    )
    replaced = load_core_config(tmp_path / "replace.toml")
    assert replaced.ignore_patterns == ["OnlyThis"]


def test_custom_ignore_patterns_gate_activity(workspace):
    runtime = runtime_for(workspace, ignore_patterns=["Generated"])
    (workspace / "Projects" / "Real Work" / "Generated").mkdir()
    runtime._on_settled(settled("Projects/Real Work/Generated/out.js"))
    assert runtime.store.open_session() is None
    # A replaced list really replaces: the built-in default no longer applies.
    runtime._on_settled(settled("Projects/Real Work/.DS_Store"))
    assert runtime.store.open_session() is not None
