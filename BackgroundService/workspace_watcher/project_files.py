"""Read-only browsing of a project's real folder contents.

The point of the project inspector is to be a fast way *into* the actual
project, so it has to show what is genuinely on disk -- not a second,
reconstructed idea of the project's contents. Nothing here writes, moves, or
creates anything.

Generated and dependency directories are listed but flagged rather than
hidden: "there is a 400 MB `node_modules` here" is real, useful information
about the folder, while silently omitting entries would make the listing
disagree with Finder.
"""

from __future__ import annotations

import os
from pathlib import Path
from typing import Any

from .noise import NoiseFilter

# A directory listing is for orientation, not for enumerating a dependency
# tree; a bound keeps one accidental click on `node_modules` from building a
# 100k-entry response.
MAX_ENTRIES = 500


class ProjectFilesError(ValueError):
    """A path that must not be served (outside the project, or missing)."""


def resolve_within(project_root: Path, relative: str) -> Path:
    """Resolve a browse request to a real path inside the project.

    Both sides are fully resolved before comparison, so neither `..` segments
    nor a symlink pointing out of the project can be used to read arbitrary
    parts of the filesystem through this endpoint.
    """
    root = project_root.resolve()
    if not root.is_dir():
        raise ProjectFilesError("project directory does not exist")
    candidate = (root / relative.lstrip("/")).resolve() if relative else root
    if candidate != root and not candidate.is_relative_to(root):
        raise ProjectFilesError("path is outside the project directory")
    if not candidate.exists():
        raise ProjectFilesError("path does not exist")
    return candidate


def list_directory(project_root: Path, relative: str = "", *, ignore_patterns: list[str] | None = None) -> dict[str, Any]:
    """One directory level, sorted folders-first then by name (Finder's own
    default ordering, so the listing reads the way the same folder does in
    Finder)."""
    root = project_root.resolve()
    target = resolve_within(project_root, relative)
    if not target.is_dir():
        raise ProjectFilesError("path is not a directory")
    noise = NoiseFilter(list(ignore_patterns or []), "") if ignore_patterns else None
    entries: list[dict[str, Any]] = []
    truncated = False
    # `scandir` so `is_dir`/`stat` reuse the directory entry's own metadata
    # rather than issuing a fresh syscall per field.
    with os.scandir(target) as scan:
        for entry in scan:
            if len(entries) >= MAX_ENTRIES:
                truncated = True
                break
            try:
                is_directory = entry.is_dir(follow_symlinks=False)
                info = entry.stat(follow_symlinks=False)
            except OSError:
                continue  # vanished or unreadable between listing and stat
            path = Path(entry.path)
            relpath = path.relative_to(root).as_posix()
            entries.append({
                "name": entry.name,
                "relative_path": relpath,
                "absolute_path": str(path),
                "is_directory": is_directory,
                "is_symlink": entry.is_symlink(),
                "size_bytes": None if is_directory else info.st_size,
                "modified_at": info.st_mtime,
                # Advisory only: the UI de-emphasizes these rather than
                # hiding them, so the listing still matches Finder.
                "ignored": bool(noise and noise.classify(relpath).ignored),
            })
    entries.sort(key=lambda item: (not item["is_directory"], item["name"].lower()))
    return {
        "relative_path": _relative(target, root),
        "absolute_path": str(target),
        "parent_path": None if target == root else _relative(target.parent, root),
        "entries": entries,
        "truncated": truncated,
    }


def _relative(path: Path, root: Path) -> str:
    """The project root is the empty string, never `"."` -- so a caller can
    pass a `parent_path` straight back in as the next `path` argument and
    reach the root, instead of having to special-case `pathlib`'s spelling."""
    relative = path.relative_to(root).as_posix()
    return "" if relative == "." else relative


def notion_page_url(notion_project_id: str | None) -> str | None:
    """Notion accepts its own page IDs undashed in a URL path; anything that
    is not a 32-hex-digit page ID is not turned into a link at all, so a
    malformed cached value can never become a misleading button."""
    if not notion_project_id:
        return None
    compact = notion_project_id.replace("-", "").strip()
    if len(compact) != 32 or any(character not in "0123456789abcdefABCDEF" for character in compact):
        return None
    return f"https://www.notion.so/{compact}"
