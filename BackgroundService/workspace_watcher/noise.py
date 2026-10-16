"""Noise classification.

Decides whether a path matches an ignore rule. This never discards raw
filesystem activity -- it only marks a NormalizedEvent as `meaningful=False`
and records which rule matched, so the decision stays visible and reversible
(a future consumer, or a config change, can still make use of "ignored"
activity without needing the watcher to have kept it around some other way).
"""

from __future__ import annotations

import fnmatch
from dataclasses import dataclass
from pathlib import PurePosixPath


@dataclass
class NoiseVerdict:
    ignored: bool
    matched_rule: str | None = None


class NoiseFilter:
    def __init__(self, global_patterns: list[str], self_exclude_relpath: str):
        self._global_patterns = list(global_patterns)
        self._self_exclude = PurePosixPath(self_exclude_relpath.strip("/"))

    def classify(self, relpath: str, extra_patterns: list[str] | None = None) -> NoiseVerdict:
        pp = PurePosixPath(relpath)

        if self._is_within(pp, self._self_exclude):
            return NoiseVerdict(True, "self_exclude:watcher_data_dir")

        patterns = self._global_patterns if not extra_patterns else [
            *self._global_patterns,
            *extra_patterns,
        ]

        parts = pp.parts
        for pattern in patterns:
            if "/" in pattern:
                if fnmatch.fnmatch(relpath, pattern) or fnmatch.fnmatch(relpath, f"*/{pattern}"):
                    return NoiseVerdict(True, pattern)
                continue
            for part in parts:
                if fnmatch.fnmatch(part, pattern):
                    return NoiseVerdict(True, pattern)

        return NoiseVerdict(False, None)

    @staticmethod
    def _is_within(path: PurePosixPath, ancestor: PurePosixPath) -> bool:
        if str(ancestor) in ("", "."):
            return False
        return path == ancestor or ancestor in path.parents

    @staticmethod
    def is_transient_temp_name(name: str) -> bool:
        """Names used by editors purely as a rename source during an atomic
        save (e.g. `.foo.txt.swp`, `foo.txt~`, `.#foo.txt`, `foo.txt.tmp`,
        Chrome's `*.crswap`, Safari's `*.sb-*`). Used by the coalescer to
        collapse create-temp + rename-over-target into one `modified` event.
        """
        temp_patterns = [
            "*.tmp", "*.temp", "*~", ".#*", "#*#",
            "*.swp", "*.swo", "*.swx", "*.crswap", "*.sb-*",
            ".goutputstream-*", "*.part", "*.crdownload",
            # Tools that append a pid/hash after ".tmp" rather than ending
            # the filename there, e.g. `Entities.swift.tmp.11534.5155d16373cb`
            # (observed from a live Xcode-driven save while testing this).
            "*.tmp.*", "*.temp.*",
        ]
        return any(fnmatch.fnmatch(name, p) for p in temp_patterns)
