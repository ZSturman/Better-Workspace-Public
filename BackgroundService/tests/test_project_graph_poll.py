from concurrent.futures import Future
from unittest.mock import Mock

from workspace_watcher.project_graph_poll import ProjectGraphPoller


def test_interval_and_in_flight_checks_do_not_overlap():
    poller = ProjectGraphPoller("/app/BetterWorkspace")
    poller.executor.shutdown()
    first = Future()
    second = Future()
    poller.executor = Mock()
    poller.executor.submit.side_effect = [first, second]
    poller.tick(0)
    poller.tick(100)
    poller.tick(950)
    assert poller.executor.submit.call_count == 1
    first.set_result(0)
    poller.tick(950)
    assert poller.executor.submit.call_count == 2
    poller.stop()


def test_disabled_checker_does_not_spawn_process(monkeypatch):
    monkeypatch.delenv("BETTER_WORKSPACE_EXECUTABLE", raising=False)
    poller = ProjectGraphPoller()
    poller.tick(0)
    assert poller.future is None
    poller.stop()


def test_headless_command_has_no_token_or_write_arguments(monkeypatch):
    run = Mock(return_value=Mock(returncode=0))
    monkeypatch.setattr("workspace_watcher.project_graph_poll.subprocess.run", run)
    poller = ProjectGraphPoller("/app/BetterWorkspace")
    assert poller._check() == 0
    assert run.call_args.args[0] == ["/app/BetterWorkspace", "--notion", "check"]
    assert run.call_args.kwargs["timeout"] < 900
    poller.stop()


def test_missing_executable_retains_failure_as_result():
    poller = ProjectGraphPoller("/definitely/missing/BetterWorkspace")
    assert poller._check() == -1
    poller.stop()
