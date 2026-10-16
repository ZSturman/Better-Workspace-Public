"""Deterministic scoring. Pure functions: no filesystem, network or database writes."""
from __future__ import annotations

from datetime import datetime, timedelta, timezone
from math import isfinite
import json
from typing import Any

from .session_quality import assess_session
from .model import COSTS, DIMENSIONS, GROUPS, METRICS, Dimension, timestamp, validate_inputs, validate_profile, validate_manual_config


def calculate(*, sessions: list[dict], ratings: dict | None = None,
              inputs: dict | None = None, manual_config: dict | None = None,
              manual_source: str = "Project.betterproject", now: datetime | None = None,
              unobserved_since: datetime | None = None) -> dict[str, dict]:
    now = now or datetime.now(timezone.utc)
    if now.tzinfo is None:
        raise ValueError("now must include timezone")
    now = now.astimezone(timezone.utc)
    at = now.isoformat()
    result = {key: Dimension(calculated_at=at).json() for key in sorted(DIMENSIONS)}

    def put(key, value=None, *, raw=None, state="known", source="local planning", coverage=None,
            window=None, explanation="", components=None, unit="score"):
        result[key] = Dimension(value=round(value, 4) if value is not None else None,
                                raw_value=raw, state=state if value is not None else "unknown",
                                source=source, input_provenance=["manual" if source == manual_source or source == "local planning" else "observed"],
                                coverage=coverage or {}, window=window or {},
                                calculated_at=at, explanation=explanation, components=components or {}, unit=unit).json()

    # Preserve ratings verbatim elsewhere. Only valid canonical 1–5 answers enter formulas.
    validate_manual_config(manual_config)
    ratings = ratings or {}
    if not isinstance(ratings, dict):
        raise ValueError("ratings must be an object")
    json.dumps(ratings, allow_nan=False)
    valid = {k: v for k, v in ratings.items() if k in METRICS and type(v) is int and 1 <= v <= 5}
    desirability = {k: (5-v)*25 if k in COSTS else (v-1)*25 for k, v in valid.items()}
    config = manual_config or {}
    enabled_groups = config.get("enabled_groups", list(GROUPS))
    enabled_metrics = set(config.get("enabled_metrics", METRICS))
    weights = config.get("group_weights", {})
    active = {m for g in enabled_groups if g in GROUPS for m in GROUPS[g][1] if m in enabled_metrics}
    group_values = {}
    for group, (_, metrics) in GROUPS.items():
        selected = [m for m in metrics if m in active]
        answered = [desirability[m] for m in selected if m in desirability]
        value = sum(answered)/len(answered) if answered else None
        if value is not None:
            group_values[group] = value
        put(f"value_{group}", value, source=manual_source,
            state="known" if len(answered) == len(selected) else "provisional",
            coverage={"answered": len(answered), "required": len(selected)},
            explanation="Manual value-group mean; unanswered metrics excluded (legacy semantics).")
    scored_groups = [g for g in enabled_groups if g in group_values]
    if scored_groups:
        group_weights = {g: max(0, float(weights.get(g, GROUPS[g][0]))) for g in scored_groups}
        if any(not isfinite(w) for w in group_weights.values()):
            raise ValueError("manual weights must be finite")
        total = sum(group_weights.values())
        rated = (sum(group_values[g]*group_weights[g] for g in scored_groups)/total if total
                 else sum(group_values[g] for g in scored_groups)/len(scored_groups))
        completion = len(active & valid.keys())/len(active) if active else 0
        put("manual_assessment", 50+(rated-50)*completion, source=manual_source,
            state="known" if completion == 1 and manual_config is not None else "provisional",
            raw={"ratings": ratings, "rated_score": rated, "rating_coverage": completion},
            coverage={"answered": len(active & valid.keys()), "required": len(active),
                      "configuration_supplied": manual_config is not None},
            components={g: {"value": group_values[g], "weight": group_weights[g]} for g in scored_groups},
            explanation="Better Projects manual assessment: 50 + (Rated Score - 50) × rating coverage. Default configuration when absent; not project progress.")
    for key, components in {
        "importance": {"personalImportance": .5, "goalAlignment": .3, "dependencyImportance": .2},
        "urgency": {"urgency": 1},
        # A specifically named, stable benefit-only profile; no activity is treated as potential.
        "potential": {"incomePotential": .25, "opportunityPotential": .25, "leverage": .25, "explorationValue": .25},
    }.items():
        complete = all(k in desirability for k in components)
        put(key, sum(desirability[k]*w for k, w in components.items()) if complete else None,
            source=manual_source, coverage={"answered": sum(k in desirability for k in components), "required": len(components)},
            components={k: {"value": desirability.get(k), "weight": w} for k, w in components.items()},
            explanation="Manual-derived judgment; all listed inputs required, no missing-input renormalization.")

    inputs = validate_inputs(inputs) if inputs else {"version": 1}
    obs = inputs.get("observation")
    obs_start = timestamp(obs["start"]) if obs else None
    obs_end = timestamp(obs["end"]) if obs else None
    accepted, seen, rejected = [], set(), 0
    excluded = []
    mixed_sessions = capped_sessions = missing_files = 0
    for row in sessions:
        if row.get("status") != "completed":
            continue
        try:
            start, end = timestamp(row["started_at"]), timestamp(row["ended_at"])
            seconds = float(row["active_seconds"])
            if end < start or end > now or start > now or not isfinite(seconds) or seconds < 0:
                raise ValueError("invalid session")
            # Historical session heuristics can exceed elapsed time; retain observed seconds,
            # never advertise them as elapsed/human time.
            if row["id"] in seen:
                continue
            seen.add(row["id"])
            quality = assess_session(row)
            if not quality["eligible"]:
                excluded.append({"session_id": row["id"], "reason": quality["reason"], "observed_hours": seconds/3600})
                continue
            mixed_sessions += int(quality["mixed"])
            capped_sessions += int(quality["capped"])
            missing_files += int(quality["reason"] == "file_evidence_unavailable")
            accepted.append((start, end, seconds/3600))
        except (KeyError, TypeError, ValueError):
            rejected += 1
    accepted.sort()

    def coverage(start):
        complete = bool(obs and obs["complete"] and obs_start <= start and obs_end >= now and not rejected and not excluded and not mixed_sessions and not capped_sessions and not missing_files)
        return {"complete": complete, "start": obs_start.isoformat() if obs_start else None,
                "end": obs_end.isoformat() if obs_end else None,
                "accepted_sessions": len(accepted), "invalid_sessions": rejected,
                "first_eligible_session": accepted[0][0].isoformat() if accepted else None,
                "last_eligible_session": max(b for _,b,_ in accepted).isoformat() if accepted else None,
                "excluded_sessions": excluded, "excluded_observed_hours": sum(e["observed_hours"] for e in excluded),
                "mixed_background_sessions": mixed_sessions, "capped_file_samples": capped_sessions,
                "missing_file_evidence_sessions": missing_files,
                "note": "Session presence does not establish uninterrupted sensing coverage."}

    def hours_between(start, end):
        hours = 0.0
        for a, b, h in accepted:
            if b == a:
                hours += h if start <= a < end else 0
            else:
                overlap = max(0, (min(b, end)-max(a, start)).total_seconds())
                hours += h * overlap/(b-a).total_seconds()
        return hours

    first = min((a for a, _, _ in accepted), default=obs_start or now)
    cov = coverage(first)
    h = sum(h for _, _, h in accepted)
    available = bool(accepted) or cov["complete"]
    put("investment_observed", 100*h/(h+40) if available else None, raw=h if available else None,
        source="core.db:completed sessions", coverage=cov,
        state="known" if cov["complete"] else "provisional", window={"start": first.isoformat(), "end": at},
        explanation="100 × observed hours / (observed hours + 40). Since recorded observation, not lifetime or human labor.", unit="hours")
    for days in (7, 30, 90):
        start = now-timedelta(days=days)
        cov = coverage(start)
        h = hours_between(start, now)
        known_absence = cov["complete"]
        available = h > 0 or known_absence
        state = "known" if known_absence else "provisional"
        window = {"days": days, "start": start.isoformat(), "end": at, "timezone": "UTC"}
        put(f"investment_{days}d", 100*h/(h+40) if available else None, raw=h if available else None,
            state=state, source="core.db:completed sessions", coverage=cov, window=window, unit="hours",
            explanation="Observed hours; boundary sessions allocated proportionally to elapsed overlap, not exact work timestamps.")
        weights = [2**(-i/(days/4)) for i in range(days)]
        daily = [hours_between(now-timedelta(days=i+1), now-timedelta(days=i)) for i in range(days)]
        activity = 100*sum(min(x/2, 1)*w for x, w in zip(daily, weights))/sum(weights)
        put(f"activity_{days}d", activity if available else None, raw={"observed_hours": h},
            state=state, source="core.db:completed sessions", coverage=cov, window=window,
            explanation=f"Decayed daily observed hours, capped at 2 hours/day; half-life {days/4:g} days. Rolling UTC day bins and proportional session allocation; activity is not progress.")
    for days in (28, 84):
        start = now-timedelta(days=days)
        cov = coverage(start)
        weeks = days//7
        count = sum(any(now-timedelta(days=7*(i+1)) <= b < now-timedelta(days=7*i)
                        for _, b, _ in accepted) for i in range(weeks))
        available = count > 0 or cov["complete"]
        put(f"consistency_{days}d", 100*count/weeks if available else None,
            raw={"qualifying_weeks": count, "weeks": weeks}, source="core.db:completed sessions", coverage=cov,
            state="known" if cov["complete"] else "provisional", window={"days": days, "start": start.isoformat(), "end": at},
            explanation="Percentage of trailing seven-day bins with a completed session. Unobserved weeks prevent a known result.")
    if accepted:
        last = max(b for _, b, _ in accepted)
        age = (now-last).total_seconds()/86400
        cov = coverage(last)
        put("activity_age", age, raw=age, unit="days", state="known" if cov["complete"] else "provisional",
            source="core.db:completed sessions", coverage=cov, window={"last_observed": last.isoformat(), "end": at},
            explanation="Days since last observed completed session, not proof of no other work.")
    else:
        # No accepted session, but the service has been watching this project since
        # `unobserved_since`: report that span as a lower bound, never as a measurement.
        if unobserved_since is not None and unobserved_since <= now:
            since = unobserved_since.astimezone(timezone.utc)
            age = (now-since).total_seconds()/86400
            put("activity_age", age, raw=age, unit="days", state="provisional",
                source="core.db:sensing coverage", coverage=coverage(since),
                window={"unobserved_since": since.isoformat(), "end": at, "bound": "lower"},
                explanation=f"At least {int(age)} days: no observed work session since sensing began for this project on "
                            f"{since.date().isoformat()}. A lower bound, not proof of no other work.")
        last = timestamp(inputs["activated_at"]) if inputs.get("activated_at") else None
    if last and last <= now and inputs.get("cadence_days"):
        cadence = inputs["cadence_days"]
        age = (now-last).total_seconds()/86400
        cov = coverage(last)
        stale = 100*(1-2**(-max(0, age-cadence)/cadence))
        put("staleness", stale, raw={"days": age, "cadence_days": cadence}, coverage=cov,
            state="known" if cov["complete"] else "provisional", source="local cadence + observed sessions",
            explanation="Overdue relative to explicit cadence; activation date used only when no session exists.")
        importance = result["importance"]
        if importance["value"] is not None:
            put("neglect", importance["value"]*stale/100, source="importance + staleness", coverage=cov,
                state=result["staleness"]["state"], components={"importance": importance["value"], "staleness": stale},
                explanation="Importance × staleness / 100; exclude intentionally paused projects when prioritizing.")

    scopes = {s["id"]: s for s in inputs.get("scopes", [])}
    for key, selection in (("progress", "project_scope_id"), ("near_done", "next_scope_id")):
        scope = scopes.get(inputs.get(selection))
        if scope:
            total = sum(x["weight"] for x in scope["leaves"])
            done = sum(x["weight"] for x in scope["leaves"] if x["accepted"])
            put(key, 100*done/total, raw={"accepted_weight": done, "total_weight": total},
                coverage={"scope_id": scope["id"], "scope_revision": scope["revision"]},
                explanation="Accepted weight / defined leaf scope. No partial credit for activity or in-progress status.")
    scope = scopes.get(inputs.get("next_scope_id"))
    if scope:
        remaining = [x for x in scope["leaves"] if not x["accepted"]]
        estimates = [x["remaining_hours"] for x in remaining if "remaining_hours" in x]
        if remaining and len(estimates) == len(remaining):
            hours = sum(estimates)
            put("finishability", 100*2**(-hours/8), raw=hours, unit="remaining_hours",
                coverage={"estimated": len(estimates), "required": len(remaining), "scope_revision": scope["revision"]},
                components={"blocked": scope.get("blocked")},
                explanation="100 × 2^(-remaining estimated hours / 8). Small does not imply unblocked; estimates are human inputs.")
        if scope.get("history_start") and scope.get("planned_weight_per_week"):
            history_start = timestamp(scope["history_start"])
            events = sorted(scope.get("events", []), key=lambda e: timestamp(e["at"]))
            if any(timestamp(e["at"]) > now for e in events):
                raise ValueError("delivery history contains future events")
            # Complete history starts unaccepted. Duplicate accepts/reopens are no-ops;
            # compare state at window boundaries to prevent completion/reopen churn gaming.
            def state_at(t):
                state = set()
                for event in events:
                    if timestamp(event["at"]) > t:
                        break
                    if event["kind"] == "accept":
                        state.add(event["leaf_id"])
                    else:
                        state.discard(event["leaf_id"])
                return state
            final = state_at(now)
            if final != {x["id"] for x in scope["leaves"] if x["accepted"]}:
                raise ValueError("delivery history disagrees with accepted leaf states")
            for days in (7, 30, 90):
                start = now-timedelta(days=days)
                if history_start > start:
                    continue
                before = state_at(start)
                credit = sum(x["weight"]*((x["id"] in final)-(x["id"] in before)) for x in scope["leaves"])
                planned = scope["planned_weight_per_week"]*days/7
                put(f"momentum_{days}d", 100*min(1, max(0, credit)/planned),
                    raw={"net_accepted_weight": credit, "planned_weight": planned},
                    window={"days": days, "start": start.isoformat(), "end": at},
                    coverage={"scope_revision": scope["revision"], "history_start": scope["history_start"]},
                    explanation="Net accepted weight / declared delivery target, bounded 0–100. Reopens reverse credit; repeated accepts do not add credit.")
    return result


def composite(dimensions: dict[str, dict], profile: dict, *, now: datetime | None = None) -> dict:
    profile = validate_profile(profile)
    parts, missing = {}, []
    total = sum(profile["weights"].values())
    for key, weight in profile["weights"].items():
        metric = dimensions.get(key, {})
        eligible = metric.get("value") is not None and (metric.get("state") == "known" or
                   (profile["allow_provisional"] and metric.get("state") == "provisional"))
        value = metric["value"] if eligible else None
        if value is None:
            missing.append(key)
        parts[key] = {"value": value, "state": metric.get("state", "unknown"), "weight": weight,
                      "contribution": weight*(value or 0)/total, "imputed": not eligible}
    unavailable = missing and profile["missing_policy"] == "require_all"
    state = "unknown" if unavailable else ("provisional" if missing or any(p["state"] != "known" for p in parts.values()) else "known")
    return Dimension(value=None if unavailable else round(sum(p["contribution"] for p in parts.values()), 4),
                     state=state, source=f"profile:{profile['id']}", components=parts,
                     calculated_at=(now or datetime.now(timezone.utc)).isoformat(),
                     coverage={"missing": missing, "policy": profile["missing_policy"], "profile": profile},
                     explanation="Optional weighted decision profile. Fixed denominator; never renormalizes missing components.").json()
