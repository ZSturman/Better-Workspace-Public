"""Workspace-area classification.

Maps a workspace-root-relative path to the Workspace "area" it belongs to
(Projects, Unsorted, Ideas, ...). Unrecognized top-level directories still
get classified -- as "generic" -- so a brand new area shows up in events
immediately, without needing a config change first.
"""

from __future__ import annotations

from dataclasses import dataclass

from .config import Config


@dataclass
class AreaMatch:
    area: str
    area_kind: str


def classify(relpath: str, config: Config) -> AreaMatch:
    relpath = relpath.strip("/")
    if not relpath:
        return AreaMatch("Workspace", "root")

    top = relpath.split("/", 1)[0]
    area = config.area_for_top_segment(top)
    if area is not None:
        return AreaMatch(area.name, area.kind)

    if "/" not in relpath:
        # A file or directory sitting directly at the Workspace root.
        return AreaMatch("Workspace", "root")

    return AreaMatch(top, "generic")
