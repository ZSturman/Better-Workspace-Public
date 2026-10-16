"""Tiny macOS delivery adapter; persistent issue state lives in SQLite."""

from __future__ import annotations

import subprocess


def notify(title: str, message: str) -> None:
    """Deliver a native Notification Center notification without shell quoting.

    Buttons/pickers belong in the Project Finder reconciliation UI: macOS
    notification actions cannot safely host the required explicit link picker.
    """
    script = 'on run argv\n display notification (item 2 of argv) with title (item 1 of argv)\nend run'
    result = subprocess.run(["osascript", "-e", script, title, message], capture_output=True, text=True, timeout=10)
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or "osascript notification failed")
