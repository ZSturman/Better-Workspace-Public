"""Rare, evidence-backed nudge decisions and delivery.

Detection is intentionally separate from presentation.  Every candidate gets
an audit row even when notifications are disabled, quiet hours apply, or a
cooldown suppresses it, which makes tuning explainable instead of magical.
"""

from __future__ import annotations

import subprocess
from dataclasses import dataclass
from datetime import datetime, timedelta
from typing import Any, Callable

from .config import NudgeRuleSettings, NudgeSettings
from .store import WorkspaceStore


@dataclass(frozen=True)
class NudgeCandidate:
    rule: str
    message: str
    confidence: float
    evidence: dict[str, Any]
    project_id: str | None = None
    project_name: str | None = None
    # Intent-folder notifications (contextual matches, due reminders) are a
    # distinct feature from behavioral coaching nudges and are gated by their
    # own per-folder [[intent_folders]].notifications flags, not [nudges]
    # enabled. They still go through every other spam guard below
    # (cooldown/dedup/quiet-hours/daily-limit) -- only the master switch and
    # per-rule enabled flag are bypassed.
    bypass_master_switch: bool = False


class MacOSNotifier:
    """A small, loosely coupled fallback when no external Hammerspoon API exists."""

    def __call__(self, title: str, message: str) -> None:
        script = 'on run argv\ndisplay notification item 2 of argv with title item 1 of argv\nend run'
        result = subprocess.run(
            ["osascript", "-e", script, "Better Workspace", message],
            text=True, capture_output=True, timeout=5, check=False,
        )
        if result.returncode:
            raise RuntimeError((result.stderr or "macOS notification failed").strip()[:300])


class NudgeEngine:
    def __init__(
        self,
        store: WorkspaceStore,
        settings: NudgeSettings,
        *,
        notifier: Callable[[str, str], None] | None = None,
    ) -> None:
        self.store = store
        self.settings = settings
        self.notifier = notifier or MacOSNotifier()

    def consider(self, candidate: NudgeCandidate, now: float) -> dict[str, Any]:
        suppression = self._suppression_reason(candidate, now)
        if suppression:
            return self._record(candidate, now, "suppressed", suppression)
        if self.settings.log_only or self.settings.delivery == "none":
            return self._record(candidate, now, "logged", "log_only")
        if self.settings.dry_run:
            return self._record(candidate, now, "dry_run", "dry_run")
        try:
            self.notifier("Workspace Watcher", candidate.message)
        except Exception as exc:  # noqa: BLE001 - notifications are never bookkeeping
            return self._record(candidate, now, "delivery_failed", f"delivery_failed: {exc}")
        return self._record(candidate, now, "delivered", None)

    def snooze(self, until: float) -> None:
        self.store.set_state("intelligence.nudges.snooze_until", until)

    def _suppression_reason(self, candidate: NudgeCandidate, now: float) -> str | None:
        if not candidate.bypass_master_switch and not self.settings.enabled:
            return "nudges_disabled"
        rule_settings = self._rule_settings(candidate.rule)
        if not candidate.bypass_master_switch and not rule_settings.enabled:
            return "rule_disabled"
        # [nudges].minimum_confidence is tuned for behavioral-coaching nudges
        # (context switching, priority drift). Intent-folder candidates have
        # their own quality gate already (relevance.minimum_score /
        # reminders.py's due conditions), so they bypass this one too.
        if not candidate.bypass_master_switch and candidate.confidence < self.settings.minimum_confidence:
            return "below_minimum_confidence"
        snoozed_until = self.store.get_state("intelligence.nudges.snooze_until")
        if isinstance(snoozed_until, (int, float)) and now < snoozed_until:
            return "snoozed"
        if self._in_quiet_hours(now):
            return "quiet_hours"
        local = datetime.fromtimestamp(now).astimezone()
        day_start = local.replace(hour=0, minute=0, second=0, microsecond=0).timestamp()
        if self.store.delivered_nudge_count_between(day_start, day_start + 86400) >= self.settings.daily_limit:
            return "daily_limit"
        global_last = self.store.latest_delivered_nudge()
        if global_last and now - float(global_last["evaluated_at"]) < self.settings.global_cooldown_minutes * 60:
            return "global_cooldown"
        rule_last = self.store.latest_delivered_nudge(rule=candidate.rule)
        if rule_last and now - float(rule_last["evaluated_at"]) < rule_settings.cooldown_minutes * 60:
            return "rule_cooldown"
        if candidate.project_id:
            project_last = self.store.latest_delivered_nudge(project_id=candidate.project_id)
            if project_last and now - float(project_last["evaluated_at"]) < self.settings.per_project_cooldown_minutes * 60:
                return "project_cooldown"
        return None

    def _rule_settings(self, rule: str) -> NudgeRuleSettings:
        try:
            return getattr(self.settings, rule)
        except AttributeError:
            return NudgeRuleSettings(enabled=False)

    def _in_quiet_hours(self, now: float) -> bool:
        def minute(value: str) -> int:
            hour, mins = (int(part) for part in value.split(":", 1))
            return hour * 60 + mins

        start, end = minute(self.settings.quiet_hours_start), minute(self.settings.quiet_hours_end)
        current = datetime.fromtimestamp(now).astimezone()
        at = current.hour * 60 + current.minute
        if start == end:
            return False
        return start <= at < end if start < end else at >= start or at < end

    def _record(self, candidate: NudgeCandidate, now: float, decision: str, reason: str | None) -> dict[str, Any]:
        self.store.record_nudge_decision({
            "evaluated_at": now, "rule": candidate.rule, "project_id": candidate.project_id,
            "project_name": candidate.project_name, "confidence": candidate.confidence,
            "decision": decision, "suppression_reason": reason, "evidence": candidate.evidence,
            "message": candidate.message,
        })
        return {"decision": decision, "suppression_reason": reason, "rule": candidate.rule}


def snooze_until(now: float, minutes: float) -> float:
    return (datetime.fromtimestamp(now).astimezone() + timedelta(minutes=minutes)).timestamp()
