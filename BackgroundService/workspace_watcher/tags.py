"""Tag normalization.

Tags are stored twice: the original human-readable ``display`` form (so
"Simplistic UX" round-trips exactly) and a ``normalized`` form used for
matching ("simplistic ux"). Normalization is deliberately simple and
deterministic -- casefold, Unicode NFKC, collapse whitespace/punctuation --
so two spellings of the same tag reliably collide without any model call.
Fuzzier equivalence (aliases) is a separate, explicit table; nothing here
guesses that two different words mean the same thing.
"""

from __future__ import annotations

import re
import unicodedata

_WHITESPACE = re.compile(r"[\s_-]+")
_STRIP_PUNCTUATION = re.compile(r"[^\w\s-]", re.UNICODE)


def normalize_tag(display: str) -> str:
    """Canonical matching key for a human-readable tag string."""

    value = unicodedata.normalize("NFKC", display).casefold().strip()
    value = _STRIP_PUNCTUATION.sub("", value)
    value = _WHITESPACE.sub(" ", value).strip()
    return value


def split_tag_list(raw: object) -> list[str]:
    """Accept a list, comma/semicolon-separated string, or None."""

    if raw is None:
        return []
    if isinstance(raw, (list, tuple)):
        items = [str(item) for item in raw]
    else:
        items = re.split(r"[;,]", str(raw))
    seen: dict[str, str] = {}
    for item in items:
        display = item.strip()
        if not display:
            continue
        key = normalize_tag(display)
        if key and key not in seen:
            seen[key] = display
    return list(seen.values())
