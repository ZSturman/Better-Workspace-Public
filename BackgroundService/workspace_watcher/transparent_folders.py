"""Read-only visible children with real paths; metadata and symlinks stay opaque."""
from pathlib import Path

FOREIGN_NAMES = frozenset({"_audit", ".project-core", "watcher.item.toml", "Project.betterproject"})


def visible_children(root: Path, excluded_names=(), *, _depth: int = 0) -> list[Path]:
    if root.is_symlink() or _depth >= 64:
        raise ValueError("Choose ordinary bounded workspace directories")
    result: list[Path] = []
    for child in sorted(root.iterdir(), key=lambda path: path.name.casefold()):
        if child.name.startswith(".") or child.name in FOREIGN_NAMES or (child.name.startswith("_") and child.name in excluded_names) or child.is_symlink():
            continue
        if child.name.startswith("_") and child.is_dir():
            result.extend(visible_children(child, excluded_names, _depth=_depth + 1))
        else:
            result.append(child)
    return sorted(result, key=lambda path: (path.name.casefold(), str(path)))


def is_visible_child(path: Path, root: Path) -> bool:
    """Only underscore directories can stand between an area and its visible item.

    The leaf can already have moved during promotion acknowledgement. Do not resolve
    symlinks first, which would erase the evidence used by this boundary check.
    """
    try:
        parts = path.absolute().relative_to(root.absolute()).parts
    except ValueError:
        return False
    if root.is_symlink() or not parts or any(part in {".", ".."} or part.startswith(".") or part in FOREIGN_NAMES for part in parts):
        return False
    if not all(part.startswith("_") for part in parts[:-1]):
        return False
    current = root
    for part in parts:
        current = current / part
        if current.is_symlink():
            return False
    return not (path.name.startswith("_") and path.is_dir())
