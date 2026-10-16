"""macOS LaunchAgent installation and diagnostics.

This process is Better Workspace's background service. Better Workspace installs
and owns its LaunchAgent (``BackgroundServiceAgent.swift`` there); this module is
the same installation for development from a checkout, and uses the same label so
the two can never set up competing agents. Workspace Watcher's own labels are
retired -- unloaded and moved out of ``~/Library/LaunchAgents`` -- on install.

The rumps menu bar is no longer installed by default: Better Workspace's menu bar
extra replaces it. ``--with-menubar`` still installs it for comparison.
"""

from __future__ import annotations

import os
import plistlib
import subprocess
from pathlib import Path

from .config import Config


WATCHER_LABEL = "com.zacharysturman.BetterWorkspace.BackgroundService"
MENUBAR_LABEL = "com.zacharysturman.workspace-watcher-menubar"
LEGACY_WATCHER_LABEL = "com.zacharysturman.workspace-watcher"
RETIRED_AGENTS = Path.home() / "Library" / "Application Support" / "BetterWorkspace" / "Migration" / "retired-launch-agents"


def _domain() -> str:
    return f"gui/{os.getuid()}"


def _agent_path(label: str) -> Path:
    return Path.home() / "Library" / "LaunchAgents" / f"{label}.plist"


def _definition(label: str, config: Config, command: str, *, background: bool) -> dict:
    project_root = Path(__file__).resolve().parents[1]
    data = config.data_dir
    data.mkdir(parents=True, exist_ok=True)
    definition = {
        "Label": label,
        "ProgramArguments": [str(project_root / "run.sh"), command],
        "WorkingDirectory": str(project_root),
        "RunAtLoad": True,
        "KeepAlive": {"SuccessfulExit": False},
        "ThrottleInterval": 30,
        "ProcessType": "Background" if background else "Interactive",
        "StandardOutPath": str(data / f"{_log_name(label)}.stdout.log"),
        "StandardErrorPath": str(data / f"{_log_name(label)}.stderr.log"),
    }
    if label == WATCHER_LABEL:
        # Shown as Better Workspace in Login Items rather than as "run.sh".
        definition["AssociatedBundleIdentifiers"] = ["com.zacharysturman.BetterWorkspace"]
    return definition


def _log_name(label: str) -> str:
    # Matches the name Better Workspace's installer gives the same agent's logs.
    return "background-service" if label == WATCHER_LABEL else label


def _wait_until_unloaded(label: str, timeout: float = 30.0) -> None:
    """``launchctl bootout`` returns before the service has finished its graceful
    shutdown; bootstrapping before then is refused."""
    import time
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        probe = subprocess.run(["launchctl", "print", f"{_domain()}/{label}"], capture_output=True, text=True, check=False)
        if probe.returncode != 0:
            return
        time.sleep(0.25)


def _bootstrap(path: Path, label: str, attempts: int = 8) -> None:
    import time
    message = ""
    for attempt in range(attempts):
        result = subprocess.run(["launchctl", "bootstrap", _domain(), str(path)], capture_output=True, text=True, check=False)
        if result.returncode == 0:
            return
        message = result.stderr.strip() or result.stdout.strip()
        if attempt < attempts - 1:
            time.sleep(1)
    raise RuntimeError(f"Could not start {label}: {message}")


def _retire(label: str) -> None:
    """Unload one of Workspace Watcher's own agents and move its definition aside,
    so it is not loaded again at the next login. Never deleted."""
    path = _agent_path(label)
    subprocess.run(["launchctl", "bootout", f"{_domain()}/{label}"], capture_output=True, text=True, check=False)
    _wait_until_unloaded(label)
    if path.exists():
        RETIRED_AGENTS.mkdir(parents=True, exist_ok=True)
        destination = RETIRED_AGENTS / path.name
        if destination.exists():
            destination = RETIRED_AGENTS / f"{label}-{int(__import__('time').time())}.plist"
        path.rename(destination)


INSTALLED_BY_BETTER_WORKSPACE = (
    "The background service is installed by Better Workspace: use Settings → Background "
    "service, or `BetterWorkspace --service install`. It runs from "
    "~/Library/Application Support/BetterWorkspace/BackgroundService, not from a checkout."
)


def install(config: Config, *, include_menubar: bool = False) -> list[Path]:
    # Better Workspace bundles, installs and launches this service; a second installer
    # here would point the same launchd label back at a source directory.
    raise RuntimeError(INSTALLED_BY_BETTER_WORKSPACE)


def _install_from_checkout(config: Config, *, include_menubar: bool = False) -> list[Path]:
    paths = []
    # The service holds an instance lock and a fixed port: the old agent must be
    # gone before the new one starts, or launchd restarts the loser every 30s.
    _retire(LEGACY_WATCHER_LABEL)
    if not include_menubar:
        _retire(MENUBAR_LABEL)
    agents = [(WATCHER_LABEL, "run", True)]
    if include_menubar:
        agents.append((MENUBAR_LABEL, "menubar", False))
    for label, command, background in agents:
        path = _agent_path(label)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(plistlib.dumps(_definition(label, config, command, background=background), fmt=plistlib.FMT_XML))
        # bootstrap refuses an existing job; bootout is harmless if not loaded.
        subprocess.run(["launchctl", "bootout", _domain(), str(path)], capture_output=True, text=True, check=False)
        _wait_until_unloaded(label)
        _bootstrap(path, label)
        paths.append(path)
    return paths


def stop(*, include_menubar: bool = True, remove: bool = False) -> None:
    labels = [WATCHER_LABEL] + ([MENUBAR_LABEL] if include_menubar else [])
    for label in labels:
        path = _agent_path(label)
        subprocess.run(["launchctl", "bootout", _domain(), str(path)], capture_output=True, text=True, check=False)
        if remove and path.exists():
            path.unlink()


def restart(config: Config) -> None:
    # `kickstart -k` can wait indefinitely while a Python process handles its
    # graceful SIGTERM. Re-bootstrap is deterministic and still lets the
    # watcher flush/close before launchd starts its replacement.
    for label in (WATCHER_LABEL, MENUBAR_LABEL):
        path = _agent_path(label)
        if path.exists():
            subprocess.run(["launchctl", "bootout", _domain(), str(path)], capture_output=True, text=True, check=False)
            _wait_until_unloaded(label)
            _bootstrap(path, label)


def status(config: Config) -> dict[str, object]:
    result: dict[str, object] = {"data_dir": str(config.data_dir), "agents": {}}
    for label in (WATCHER_LABEL, MENUBAR_LABEL):
        path = _agent_path(label)
        probe = subprocess.run(["launchctl", "print", f"{_domain()}/{label}"], capture_output=True, text=True, check=False)
        result["agents"][label] = {"installed": path.exists(), "running": probe.returncode == 0, "path": str(path), "detail": (probe.stderr or probe.stdout).strip()[:300]}
    return result
