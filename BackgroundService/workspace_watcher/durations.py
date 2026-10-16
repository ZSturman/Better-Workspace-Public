"""Deterministic, dependency-free duration parsing.

Human-authored metadata and configuration express durations as short strings
("30d", "12h", "2w") rather than raw seconds. Parsing stays plain arithmetic
-- no LLM, no calendar library -- so reminder/defer evaluation is exact and
fast on every tick.
"""

from __future__ import annotations

import re

_UNIT_SECONDS = {
    "m": 60.0,
    "h": 3600.0,
    "d": 86400.0,
    "w": 7 * 86400.0,
    "mo": 30 * 86400.0,  # approximate; only meaningful for coarse thresholds
}

# Longer unit codes must be tried before shorter ones that are a prefix of
# them (e.g. "mo" before "m").
_PATTERN = re.compile(r"^\s*(\d+(?:\.\d+)?)\s*(mo|[mhdw])\s*$", re.IGNORECASE)


def parse_duration_seconds(value: str) -> float | None:
    """Parse a duration like "30d" into seconds, or None if unparseable."""

    if not isinstance(value, str):
        return None
    match = _PATTERN.match(value)
    if not match:
        return None
    amount, unit = match.groups()
    return float(amount) * _UNIT_SECONDS[unit.lower()]


def format_duration(seconds: float) -> str:
    """Render seconds back to the coarsest whole unit for display."""

    seconds = max(0.0, float(seconds))
    if seconds >= _UNIT_SECONDS["w"] and seconds % _UNIT_SECONDS["w"] == 0:
        return f"{int(seconds // _UNIT_SECONDS['w'])}w"
    if seconds >= _UNIT_SECONDS["d"]:
        return f"{seconds / _UNIT_SECONDS['d']:.1f}".rstrip("0").rstrip(".") + "d"
    if seconds >= _UNIT_SECONDS["h"]:
        return f"{seconds / _UNIT_SECONDS['h']:.1f}".rstrip("0").rstrip(".") + "h"
    return f"{seconds / _UNIT_SECONDS['m']:.0f}m"
