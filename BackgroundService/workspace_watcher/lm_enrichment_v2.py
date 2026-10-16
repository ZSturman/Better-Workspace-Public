"""v2's optional LM Studio enrichment layer for Work Log drafts.

Strictly a post-hoc enrichment on top of already-generated deterministic
evidence (`WorkLogGenerator`'s payload) -- never a replacement for it, never
able to overwrite it, and never on the critical path that saves it (see
`CoreRuntime._enrich_work_logs`, called from the tick loop, never from the
`session.closed` hook that prepares a draft). Off by default; deterministic
Work Log generation is byte-for-byte identical whether this is enabled or
not.

Reuses `lm_studio.py`'s generic, store-agnostic `LMStudioClient` (the same
OpenAI-compatible client v1 already built) -- nothing here reimplements an
HTTP client.

Five small, focused passes rather than one large prompt. Each is
independently optional, independently timed out, and a failure in one never
blocks the others or the deterministic draft itself:

- `summary` -- a concise human summary of the day's work
- `work_type` -- an inferred one-to-three-word category. There is no real
  taxonomy source (no app/window observation -- see docs/v2-work-log-system.md's
  documented gap vs. Hammerspoon's work-mode classification), so this is
  necessarily a best-effort guess from file names/git alone, and the prompt
  says so explicitly rather than pretending otherwise.
- `accomplishments` -- a short list of concrete things likely done
- `next_step` -- one plausible next step
- `anomaly_note` -- only attempted when the session's confidence is below
  `low_confidence_threshold`; a normal, confident day gets no note at all

Only derived, already-aggregated evidence is ever sent -- never raw file
contents (never collected in the first place), never the full per-session
breakdown, just the day-level facts a human reviewer would also see.
"""

from __future__ import annotations

import hashlib
import json
from typing import Any

from .core_config import LMStudioSettings
from .core_engine import utc_now
from .lm_studio import LMStudioClient, LMStudioError

_EVIDENCE_KEYS = (
    "project", "date", "active_minutes", "elapsed_minutes", "meaningful_event_count",
    "session_count", "resumed_session_count", "interruption_count", "longest_uninterrupted_minutes",
    "summary", "confidence",
)


def _evidence_for_prompt(payload: dict[str, Any]) -> dict[str, Any]:
    """The exact, bounded fact set sent to the model -- day-level aggregates
    plus a capped list of file basenames and git branch/commit-subject only
    (never a diff, never file contents). `confidence` is folded in from the
    most-recent session, not stored at the day level today, so callers pass
    it in explicitly via `payload` before calling this."""
    evidence = {key: payload.get(key) for key in _EVIDENCE_KEYS if key in payload}
    files = payload.get("files") or []
    evidence["file_count"] = len(files)
    evidence["file_names"] = [str(path).rsplit("/", 1)[-1] for path in files[:15]]
    git_entries = [entry for entry in (payload.get("git") or []) if entry]
    if git_entries:
        latest = git_entries[-1]
        evidence["git"] = {"branch": latest.get("branch"), "head_subject": latest.get("head_subject"), "changed_file_count": latest.get("changed_file_count")}
    return evidence


def _hash_evidence(evidence: dict[str, Any]) -> str:
    return hashlib.sha256(json.dumps(evidence, sort_keys=True, default=str).encode()).hexdigest()


class LMEnrichmentService:
    def __init__(self, settings: LMStudioSettings, *, client: LMStudioClient | None = None) -> None:
        self.settings = settings
        self.client = client or LMStudioClient(settings.endpoint, settings.timeout_seconds)

    def enrich(self, draft: dict[str, Any], *, force: bool = False) -> dict[str, Any] | None:
        """Returns a new `llm` sub-object to merge into the draft's payload,
        or `None` if there's nothing to do (disabled, or evidence unchanged
        since the last enrichment and `force` wasn't given). Never raises --
        each pass's own failure is recorded per-pass in the returned dict's
        `errors` instead, and a total inability to reach LM Studio still
        returns a valid (mostly-empty) result rather than raising, so a
        caller never needs its own try/except around this."""
        if not self.settings.enabled:
            return None
        payload = json.loads(draft["payload_json"]) if isinstance(draft.get("payload_json"), str) else dict(draft.get("payload") or {})
        evidence = _evidence_for_prompt(payload)
        input_hash = _hash_evidence(evidence)
        existing = payload.get("llm") or {}
        if not force and existing.get("input_hash") == input_hash:
            return None
        confidence = float(payload.get("confidence") or 0.0)
        errors: dict[str, str] = {}
        result: dict[str, Any] = {
            "model": self.settings.model or None, "generated_at": utc_now(), "input_hash": input_hash,
            "summary": self._run_pass(
                "summary", errors, evidence,
                "Write one or two concise, factual sentences summarizing what kind of work happened today, "
                "using ONLY the given evidence. Do not invent details, tools, outcomes, or intent not present in the evidence.",
            ),
            "work_type": self._run_pass(
                "work_type", errors, evidence,
                "In 1-3 words, name the general category of work (e.g. 'bug fixing', 'feature development', "
                "'writing', 'refactoring', 'research', 'configuration'). Base this only on the given file names "
                "and git info. If you genuinely cannot tell, respond with exactly: unclear",
            ),
            "accomplishments": self._run_pass(
                "accomplishments", errors, evidence,
                "List up to 3 short, concrete things likely accomplished, based only on the given evidence "
                "(file names, counts, git commit subject if present), one per line with no numbering or bullets. "
                "If nothing concrete can be inferred beyond activity having occurred, say exactly: "
                "No specific accomplishments could be inferred from the available evidence.",
            ),
            "next_step": self._run_pass(
                "next_step", errors, evidence,
                "In one short sentence, suggest a plausible next step for this project based only on the given "
                "evidence. If there isn't enough information to guess, respond with exactly: "
                "Not enough information to suggest a next step.",
            ),
        }
        if confidence < self.settings.low_confidence_threshold:
            result["anomaly_note"] = self._run_pass(
                "anomaly_note", errors, {**evidence, "confidence_is_low_because_of": "unknown -- explain from evidence"},
                f"This work session was scored with low confidence ({confidence}). In one short sentence, state "
                "the most likely reason, based only on the given evidence (e.g. very few file changes, very "
                "short active time, very few distinct files). Do not speculate beyond what the evidence shows.",
            )
        else:
            result["anomaly_note"] = None
        result["errors"] = errors
        return result

    def _run_pass(self, name: str, errors: dict[str, str], evidence: dict[str, Any], system_prompt: str) -> str | list[str] | None:
        try:
            content, _model = self.client.chat_completion(
                [{"role": "system", "content": system_prompt}, {"role": "user", "content": json.dumps(evidence, sort_keys=True, default=str)}],
                model=self.settings.model, max_tokens=160,
            )
        except LMStudioError as exc:
            errors[name] = str(exc)[:300]
            return None
        except Exception as exc:  # noqa: BLE001 - an enrichment pass must never propagate and block the others
            errors[name] = f"unexpected error: {exc}"[:300]
            return None
        if name == "accomplishments":
            return [line.strip("-* \t") for line in content.splitlines() if line.strip()][:3]
        return content
