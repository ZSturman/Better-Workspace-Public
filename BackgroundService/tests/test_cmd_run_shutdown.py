"""`cmd_run` must treat an intentional SIGTERM/SIGINT (what `./run.sh
restart`/`stop` actually send) as a clean shutdown, not a crash -- otherwise
every routine restart wrongly recovers open sessions/work as
`recovered_after_restart` instead of `watcher_stopped`."""

from __future__ import annotations

import os
import signal
import socket
import threading
import time
from argparse import Namespace
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from workspace_watcher.__main__ import cmd_run
from workspace_watcher.core_store import CoreStore


class _QuietHandler(BaseHTTPRequestHandler):
    def log_message(self, *_args) -> None:
        return


def _wait_for(predicate, timeout: float = 8.0) -> bool:
    deadline = time.time() + timeout
    while time.time() < deadline:
        if predicate():
            return True
        time.sleep(0.05)
    return False


def _write_config(tmp_path: Path, root: Path, db_path: Path) -> Path:
    config_path = tmp_path / "config.toml"
    config_path.write_text(
        f"""
[workspace_watcher]
workspace_root = "{root}"
rules_file = "rules.toml"
[workspace_watcher.storage]
database = "{db_path}"
[workspace_watcher.watcher]
debounce_seconds = 0.1
""".strip()
    )
    return config_path


def test_sigterm_stops_cleanly_and_closes_the_open_session(tmp_path, monkeypatch):
    root = tmp_path / "workspace"
    root.mkdir()
    db_path = root / "Logs/workspace-watcher/core.db"
    config_path = _write_config(tmp_path, root, db_path)

    # A real ThreadingHTTPServer (bound to an OS-assigned free port, not the
    # production 8765) so `.shutdown()` behaves exactly like it does in
    # production -- the whole point being tested is that path.
    real_server = ThreadingHTTPServer(("127.0.0.1", 0), _QuietHandler)
    monkeypatch.setattr("workspace_watcher.core_api.serve", lambda config, runtime=None: real_server)
    # cmd_run always probes the real port 8765 before starting; force it to
    # look free regardless of whether a real Workspace Watcher instance
    # happens to be running on this machine.
    monkeypatch.setattr(socket.socket, "connect_ex", lambda self, addr: 1)

    def _touch_then_signal() -> None:
        # Give cmd_run a moment to reach serve_forever() before creating
        # real filesystem activity for its real watchdog sensor to pick up.
        time.sleep(0.3)
        (root / "Projects" / "Demo").mkdir(parents=True)
        (root / "Projects" / "Demo" / "main.py").write_text("print(1)\n")

        def _session_is_open() -> bool:
            try:
                store = CoreStore(db_path, read_only=True)
            except Exception:
                return False
            try:
                return store.open_session() is not None
            finally:
                store.close()

        _wait_for(_session_is_open, timeout=8.0)
        os.kill(os.getpid(), signal.SIGTERM)

    threading.Thread(target=_touch_then_signal, daemon=True).start()
    # cmd_run installs its SIGTERM handler on this (the main) thread and then
    # blocks in serve_forever() -- exactly the real production shape. The
    # background thread above sends the signal from outside, like launchd
    # actually does.
    result = cmd_run(Namespace(config=config_path, workspace_root=None))

    assert result == 0
    store = CoreStore(db_path, read_only=True)
    try:
        assert store.get_state("watcher.health") == {"state": "stopped"}
        sessions = store.recent_sessions()
        assert len(sessions) == 1
        assert sessions[0]["close_reason"] == "watcher_stopped"
    finally:
        store.close()


def test_sigint_also_stops_cleanly(tmp_path, monkeypatch):
    root = tmp_path / "workspace"
    root.mkdir()
    db_path = root / "Logs/workspace-watcher/core.db"
    config_path = _write_config(tmp_path, root, db_path)

    real_server = ThreadingHTTPServer(("127.0.0.1", 0), _QuietHandler)
    monkeypatch.setattr("workspace_watcher.core_api.serve", lambda config, runtime=None: real_server)
    monkeypatch.setattr(socket.socket, "connect_ex", lambda self, addr: 1)

    def _signal_shortly() -> None:
        time.sleep(0.3)
        os.kill(os.getpid(), signal.SIGINT)

    threading.Thread(target=_signal_shortly, daemon=True).start()
    result = cmd_run(Namespace(config=config_path, workspace_root=None))

    assert result == 0
    store = CoreStore(db_path, read_only=True)
    try:
        assert store.get_state("watcher.health") == {"state": "stopped"}
    finally:
        store.close()
