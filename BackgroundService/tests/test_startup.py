from __future__ import annotations

import pytest

from workspace_watcher.config import default_config
from workspace_watcher.instance_lock import InstanceLock
from workspace_watcher.startup import WATCHER_LABEL, _definition


def test_launch_agent_definition_is_login_safe_and_throttled(tmp_path):
    config = default_config(tmp_path)
    definition = _definition(WATCHER_LABEL, config, "run", background=True)
    assert definition["Label"] == WATCHER_LABEL
    assert definition["RunAtLoad"] is True
    assert definition["KeepAlive"] == {"SuccessfulExit": False}
    assert definition["ThrottleInterval"] == 30
    assert definition["ProgramArguments"][-1] == "run"
    assert str(config.data_dir) in definition["StandardErrorPath"]


def test_instance_lock_rejects_a_second_watcher(tmp_path):
    first, second = InstanceLock(tmp_path / "watcher.lock"), InstanceLock(tmp_path / "watcher.lock")
    first.acquire()
    with pytest.raises(RuntimeError, match="already running"):
        second.acquire()
    first.release()
    second.acquire()
    second.release()


def test_the_service_runs_under_better_workspaces_label_and_log_names(tmp_path):
    # Better Workspace's BackgroundServiceAgent writes the same label and log names;
    # if these drift apart, the two installers set up competing agents.
    config = default_config(tmp_path)
    definition = _definition(WATCHER_LABEL, config, "run", background=True)
    assert WATCHER_LABEL == "com.zacharysturman.BetterWorkspace.BackgroundService"
    assert definition["StandardOutPath"].endswith("background-service.stdout.log")
    assert definition["StandardErrorPath"].endswith("background-service.stderr.log")


def test_installing_from_here_is_refused_in_favour_of_better_workspace(tmp_path):
    from workspace_watcher.startup import install
    with pytest.raises(RuntimeError, match="BetterWorkspace --service install"):
        install(default_config(tmp_path))
