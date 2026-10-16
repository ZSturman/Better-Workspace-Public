"""Optional LM Studio tag inference and summarization for intent-folder items.

Deliberately narrow: this is the *only* place an intent-folder item talks to
a model, and only for the two tasks a deterministic pass genuinely cannot do
well -- suggesting themes/tags from free text, and writing a short summary.
Matching, dates, persistence, and moving files stay fully deterministic (see
``relevance.py`` and ``reminders.py``).

Failure isolation mirrors ``work_logs.LMStudioWorkLogSummarizer``: a bad or
unavailable server records an error and leaves the item's existing tags/
summary untouched. Nothing here retries synchronously or blocks the caller;
``ContextEngine.tick()`` processes a small bounded batch per call so one
slow/offline server cannot stall the watcher.
"""

from __future__ import annotations

import hashlib
import json
from typing import Any

from .lm_studio import LMStudioClient

_SYSTEM_PROMPT = (
    "You classify a personal knowledge-base item. Given its title, description, "
    "and any existing tags, reply with ONLY a compact JSON object: "
    '{"tags": ["short theme", ...], "summary": "one short factual sentence"}. '
    "Suggest at most 5 tags, reusing the existing tags' wording style. Never "
    "invent facts not implied by the given text. summary may be an empty "
    'string ("") if the input is too sparse to summarize.'
)


def content_hash(title: str, description: str, existing_tags: list[str], source: str) -> str:
    payload = json.dumps(
        {"title": title, "description": description, "tags": sorted(existing_tags), "source": source},
        sort_keys=True, separators=(",", ":"),
    )
    return hashlib.sha256(payload.encode()).hexdigest()


class LMStudioItemAnalyzer:
    def __init__(self, endpoint: str, model: str, timeout_seconds: float) -> None:
        self.client = LMStudioClient(endpoint, timeout_seconds)
        self.model = model

    def analyze(self, title: str, description: str, existing_tags: list[str], want_summary: bool) -> dict[str, Any]:
        payload = {"title": title, "description": description, "existing_tags": existing_tags}
        content, used_model = self.client.chat_completion(
            [{"role": "system", "content": _SYSTEM_PROMPT}, {"role": "user", "content": json.dumps(payload)}],
            model=self.model, max_tokens=220,
        )
        parsed = json.loads(content)
        if not isinstance(parsed, dict):
            raise ValueError("LM Studio tag response was not a JSON object")
        tags = [str(t).strip() for t in parsed.get("tags", []) if isinstance(t, (str, int, float)) and str(t).strip()][:5]
        summary = str(parsed.get("summary") or "").strip() if want_summary else None
        return {"tags": tags, "summary": summary or None, "model": used_model}


def process_item(
    store, item: Any, analyzer: LMStudioItemAnalyzer, *, classify: bool, summarize: bool, confidence: float = 0.6,
) -> dict[str, Any]:
    """Run inference for one item if its content changed since the last attempt.

    Returns a small status dict for logging; never raises -- LM Studio being
    offline or malformed is recorded on the item and inference is simply
    retried on a later tick.
    """

    # Only *user*-provenance tags participate in the change hash and the
    # prompt context. Including inferred tags here would create a feedback
    # loop: every successful inference changes the input, which would look
    # like new content changed and trigger another call on the very next tick.
    existing_tags = [str(t["display"]) for t in store.tags_for_item(item["item_id"]) if t["provenance"] == "user"]
    title, description = str(item["title"] or item["name"]), str(item["description"] or "")
    current_hash = content_hash(title, description, existing_tags, str(item["source"] or ""))
    lm_state = json.loads(item["lm_state_json"] or "{}")
    if lm_state.get("input_hash") == current_hash and lm_state.get("succeeded"):
        return {"item_id": item["item_id"], "status": "unchanged"}
    state: dict[str, Any] = {"attempted": True, "succeeded": False, "model": None, "error": None, "input_hash": current_hash}
    try:
        result = analyzer.analyze(title, description, existing_tags, summarize)
        if classify and result["tags"]:
            store.set_item_inferred_tags(item["item_id"], [(tag, confidence) for tag in result["tags"]])
        if summarize and result["summary"]:
            state["summary"] = result["summary"]
        state.update({"succeeded": True, "model": result["model"]})
    except Exception as exc:  # noqa: BLE001 - LM Studio failure must never affect indexing
        state["error"] = str(exc)[:300]
    store.set_item_lm_state(item["item_id"], state)
    return {"item_id": item["item_id"], "status": "succeeded" if state["succeeded"] else "failed", "error": state.get("error")}
