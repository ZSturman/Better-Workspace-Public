"""Safe Finder-tag presentation adapter.

Finder stores tags in ``com.apple.metadata:_kMDItemUserTags`` as a binary
plist.  The watcher only owns tags with the ``WW: `` prefix, leaving every
other value (including a person's existing color tags) byte-for-byte intact.
This is intentionally a presentation adapter: status calculation never
depends on xattrs succeeding.
"""

from __future__ import annotations

import os
import plistlib
import subprocess
from pathlib import Path


XATTR = "com.apple.metadata:_kMDItemUserTags"
PREFIX = "WW: "
# Finder's documented label-number convention.  A tag without this suffix is
# still valid, but then Finder displays its user-selected/default color.
COLOR_NUMBER = {
    "gray": 1, "green": 2, "yellow": 3, "blue": 4, "purple": 5,
    "red": 6, "orange": 7,
}
STATUS_PRESENTATION = {
    "active": ("Active", "yellow"), "recent": ("Recent", "green"),
    "stale": ("Stale", "gray"), "attention": ("Attention", "orange"),
    "error": ("Error", "red"), "blocked": ("Blocked", "orange"),
    "unknown": ("Unknown", "orange"), "completed": ("Completed", "green"),
    "reference": ("Reference", "blue"), "normal": ("Normal", "gray"),
}


def _decode(raw: bytes) -> list[str]:
    try:
        tags = plistlib.loads(raw)
        return [str(tag) for tag in tags] if isinstance(tags, list) else []
    except (ValueError, TypeError):
        # Never destroy a malformed/third-party tag xattr just because this
        # adapter cannot understand it.
        return []


def _read_xattr(path: Path) -> bytes:
    if hasattr(os, "getxattr"):
        return os.getxattr(path, XATTR)  # type: ignore[attr-defined]
    result = subprocess.run(["xattr", "-px", XATTR, str(path)], capture_output=True, text=True, check=False)
    if result.returncode:
        if "No such xattr" in result.stderr:
            return b""
        raise OSError(result.stderr.strip() or "xattr unavailable")
    return bytes.fromhex("".join(result.stdout.split()))


def _write_xattr(path: Path, value: bytes) -> None:
    if hasattr(os, "setxattr"):
        os.setxattr(path, XATTR, value)  # type: ignore[attr-defined]
        return
    result = subprocess.run(["xattr", "-wx", XATTR, value.hex(), str(path)], capture_output=True, text=True, check=False)
    if result.returncode:
        raise OSError(result.stderr.strip() or "xattr unavailable")


def read_tags(path: Path) -> list[str]:
    try:
        return _decode(_read_xattr(path))
    except (OSError, AttributeError):
        return []


def owned_tag_for(status: str) -> str:
    label, color = STATUS_PRESENTATION.get(status, STATUS_PRESENTATION["normal"])
    return f"{PREFIX}{label}\n{COLOR_NUMBER[color]}"


def apply_status_tag(path: Path, status: str) -> bool:
    """Replace only this app's single tag. Returns false if unsupported."""
    try:
        existing = _decode(_read_xattr(path))
    except OSError as exc:
        # ENODATA means there are no existing tags. Other errors (network
        # volume, permissions) are deliberately non-fatal to the watcher.
        if getattr(exc, "errno", None) not in {61, 93}:  # ENODATA macOS/Linux
            return False
        existing = []
    except AttributeError:
        return False
    wanted = owned_tag_for(status)
    retained = [tag for tag in existing if not tag.startswith(PREFIX)]
    updated = retained + [wanted]
    if updated == existing:
        return True
    try:
        _write_xattr(path, plistlib.dumps(updated, fmt=plistlib.FMT_BINARY))
        return True
    except (OSError, AttributeError):
        return False
