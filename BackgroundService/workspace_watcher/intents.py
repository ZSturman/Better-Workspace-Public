"""Intent-folder discovery for the local-first Workspace Watcher core.

This module deliberately has no dependency on watchdog, SQLite, or the old
configured-name intent index.  It is the one authority for the question
"is this directory an intent folder?" and makes every decision explainable.
"""

from __future__ import annotations

import json
import os
import re
import tomllib
from dataclasses import dataclass, field
from pathlib import Path
from .transparent_folders import FOREIGN_NAMES
from typing import Any, Iterator


INTENT_FILENAME = "watcher.intent.toml"
INTENT_PATTERN = re.compile(r"^\[\[(?P<name>[^\[\]\r\n]+)\]\]$")
NEXT_CONFIG_NAMES = frozenset({"next.config.js", "next.config.mjs", "next.config.cjs", "next.config.ts"})
DEFAULT_EXCLUDED_NAMES = frozenset({".git", ".hg", ".svn", "node_modules", ".next", ".venv", "venv", "__pycache__", "build", "dist", "DerivedData"})


@dataclass(frozen=True)
class IntentFolderSettings:
    """Policy supplied by the application configuration.

    Roots are absolute, resolved paths.  A symlink is never followed by
    default because crossing a workspace boundary invisibly is surprising.
    """

    search_roots: tuple[Path, ...]
    excluded_roots: tuple[Path, ...] = ()
    excluded_names: frozenset[str] = DEFAULT_EXCLUDED_NAMES
    follow_symlinks: bool = False
    allow_nested: bool = False
    # Plain-named folders that are intent folders by configuration rather than by
    # ``[[Name]]`` syntax: (absolute path, intent name). Better Workspace gives each
    # top-level Workspace folder an ordinary name ("Ideas", "For Inspiration"), and
    # renaming them out of ``[[...]]`` must not silently switch off ideas,
    # resurfacing and due-item attention -- which is what happened on 2026-09-28.
    declared: tuple[tuple[Path, str], ...] = ()

    @classmethod
    def for_workspace(cls, workspace: Path, roots: list[str | Path] | None = None) -> "IntentFolderSettings":
        workspace = workspace.expanduser().resolve()
        requested = roots or [workspace, workspace / "Temporary", workspace / "Projects"]
        return cls(tuple(normalize_roots(requested)))


@dataclass(frozen=True)
class DetectionExplanation:
    path: Path
    is_intent: bool
    intent_name: str | None
    reason: str
    checks: tuple[str, ...]
    project_root: Path | None = None

    def to_dict(self) -> dict[str, Any]:
        return {
            "path": str(self.path), "is_intent": self.is_intent,
            "intent_name": self.intent_name, "reason": self.reason,
            "checks": list(self.checks), "project_root": str(self.project_root) if self.project_root else None,
        }


@dataclass(frozen=True)
class IntentFolder:
    path: Path
    root: Path
    name: str
    config: dict[str, Any] = field(default_factory=dict)

    @property
    def stable_path_key(self) -> str:
        return str(self.path)


def normalize_roots(roots: list[str | Path] | tuple[str | Path, ...]) -> list[Path]:
    """Canonicalize roots and remove descendants already covered by a root."""

    resolved = sorted({Path(root).expanduser().resolve() for root in roots}, key=lambda path: (len(path.parts), str(path)))
    result: list[Path] = []
    for root in resolved:
        if not any(root == parent or parent in root.parents for parent in result):
            result.append(root)
    return result


class IntentFolderDetector:
    """Discover and explain ``[[Name]]`` folders under eligible roots."""

    def __init__(self, settings: IntentFolderSettings) -> None:
        self.settings = IntentFolderSettings(
            search_roots=tuple(normalize_roots(settings.search_roots)),
            excluded_roots=tuple(normalize_roots(settings.excluded_roots)),
            excluded_names=settings.excluded_names,
            follow_symlinks=settings.follow_symlinks,
            allow_nested=settings.allow_nested,
            declared=tuple((Path(path).expanduser().resolve(), name) for path, name in settings.declared),
        )
        self._declared = dict(self.settings.declared)

    def explain(self, path: str | Path) -> DetectionExplanation:
        candidate = Path(path).expanduser()
        # resolve() is intentionally used for comparison but lstat below keeps
        # symlink policy observable before the target is accepted.
        canonical = candidate.resolve()
        checks: list[str] = []
        declared = self._declared.get(canonical)
        if declared is not None:
            if candidate.is_symlink() and not self.settings.follow_symlinks:
                return DetectionExplanation(candidate, False, declared, "symlink policy excludes candidate", ("MATCH declared intent folder", "FAIL symlink policy"))
            if not canonical.is_dir():
                return DetectionExplanation(candidate, False, declared, "declared intent folder is missing", ("MATCH declared intent folder", "FAIL exists"))
            return DetectionExplanation(candidate, True, declared, "declared intent folder", ("MATCH declared intent folder", "RESULT intent folder"))
        match = INTENT_PATTERN.fullmatch(candidate.name)
        if not match:
            return DetectionExplanation(candidate, False, None, "name does not use [[Name]] syntax", tuple(checks + ["FAIL name syntax"]))
        name = match.group("name").strip()
        if not name:
            return DetectionExplanation(candidate, False, None, "intent name is empty", tuple(checks + ["FAIL non-empty name"]))
        checks.append("MATCH name syntax")
        if candidate.is_symlink() and not self.settings.follow_symlinks:
            return DetectionExplanation(candidate, False, name, "symlink policy excludes candidate", tuple(checks + ["FAIL symlink policy"]))
        root = self._containing_root(canonical)
        if root is None:
            return DetectionExplanation(candidate, False, name, "outside configured search roots", tuple(checks + ["FAIL eligible root"]))
        checks.append(f"MATCH eligible root: {root}")
        if self._is_excluded(canonical):
            return DetectionExplanation(candidate, False, name, "inside excluded root", tuple(checks + ["FAIL excluded root"]))
        if not self.settings.allow_nested and self._has_intent_ancestor(canonical, root):
            return DetectionExplanation(candidate, False, name, "nested intent folders are disabled", tuple(checks + ["FAIL nested intent policy"]))
        project_root = self._next_project_root(canonical, root)
        if project_root and self._in_next_route_tree(canonical, project_root):
            return DetectionExplanation(candidate, False, name, "Next.js route directory", tuple(checks + ["MATCH Next.js project", "MATCH Next.js route tree", "RESULT ignored"]), project_root)
        checks.append("PASS framework-route exclusion")
        return DetectionExplanation(candidate, True, name, "eligible intent folder", tuple(checks + ["RESULT intent folder"]), project_root)

    def discover(self) -> Iterator[IntentFolder]:
        """Walk each normalized root once, pruning known non-workspace trees."""

        seen: set[Path] = set()
        # Declared folders first: they need no walk, and a declared folder that also
        # sits under a search root is then not yielded twice.
        for path, name in self.settings.declared:
            if self.explain(path).is_intent:
                seen.add(path)
                yield IntentFolder(path, self._containing_root(path) or path.parent, name, load_intent_config(path / INTENT_FILENAME))
        for root in self.settings.search_roots:
            if not root.is_dir():
                continue
            for current, dirnames, _ in os.walk(root, followlinks=self.settings.follow_symlinks):
                current_path = Path(current)
                dirnames[:] = [name for name in dirnames if name not in self.settings.excluded_names and self._should_descend(current_path / name)]
                for name in list(dirnames):
                    candidate = current_path / name
                    if candidate.resolve() in seen:
                        # Already yielded as declared; never descend into its items.
                        dirnames.remove(name)
                        continue
                    explanation = self.explain(candidate)
                    if explanation.is_intent and candidate.resolve() not in seen:
                        seen.add(candidate.resolve())
                        yield IntentFolder(candidate.resolve(), self._containing_root(candidate.resolve()) or root, explanation.intent_name or name, load_intent_config(candidate / INTENT_FILENAME))
                        if not self.settings.allow_nested:
                            dirnames.remove(name)

    def _should_descend(self, path: Path) -> bool:
        if path.name in FOREIGN_NAMES:
            return False
        if self._is_excluded(path.resolve()):
            return False
        return self.settings.follow_symlinks or not path.is_symlink()

    def _containing_root(self, path: Path) -> Path | None:
        return next((root for root in self.settings.search_roots if path == root or root in path.parents), None)

    def _is_excluded(self, path: Path) -> bool:
        return any(path == root or root in path.parents for root in self.settings.excluded_roots)

    def _has_intent_ancestor(self, path: Path, root: Path) -> bool:
        for parent in path.parents:
            if parent == root.parent:
                break
            if INTENT_PATTERN.fullmatch(parent.name) or parent in self._declared:
                return True
        return False

    def _next_project_root(self, path: Path, boundary: Path) -> Path | None:
        for directory in (path, *path.parents):
            if directory == boundary.parent:
                break
            if any((directory / marker).is_file() for marker in NEXT_CONFIG_NAMES) or _package_uses_next(directory / "package.json"):
                return directory
        return None

    @staticmethod
    def _in_next_route_tree(path: Path, project_root: Path) -> bool:
        try:
            rel = path.relative_to(project_root).parts
        except ValueError:
            return False
        return bool(rel) and (rel[0] in {"app", "pages"} or (len(rel) >= 2 and rel[0] == "src" and rel[1] in {"app", "pages"}))


def _package_uses_next(path: Path) -> bool:
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError, UnicodeDecodeError):
        return False
    return any("next" in (raw.get(section) or {}) for section in ("dependencies", "devDependencies", "peerDependencies"))


def load_intent_config(path: Path) -> dict[str, Any]:
    """Read optional folder behaviour without making a bad file fatal to discovery.

    Returning an error marker is intentional: the detector can still expose
    an otherwise valid folder to Diagnostics instead of silently losing it.
    """

    try:
        with path.open("rb") as stream:
            raw = tomllib.load(stream)
    except (OSError, tomllib.TOMLDecodeError):
        return {}
    try:
        validate_intent_config(raw)
    except ValueError as error:
        return {"_error": str(error)}
    return raw


def validate_intent_config(raw: dict[str, Any]) -> None:
    """Validate the stable v1 folder contract while leaving future keys open."""

    if raw.get("schema_version", 1) != 1:
        raise ValueError("unsupported watcher.intent.toml schema_version")
    for table in ("intent", "behavior", "defaults", "resurfacing", "notifications"):
        value = raw.get(table)
        if value is not None and not isinstance(value, dict):
            raise ValueError(f"[{table}] must be a TOML table")
    intent = raw.get("intent", {})
    if "id" in intent and (not isinstance(intent["id"], str) or not intent["id"].strip()):
        raise ValueError("intent.id must be a non-empty string")
    minimum_days = raw.get("resurfacing", {}).get("minimum_days_between")
    if minimum_days is not None and (not isinstance(minimum_days, int) or minimum_days < 0):
        raise ValueError("resurfacing.minimum_days_between must be a non-negative integer")
