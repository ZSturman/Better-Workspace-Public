"""Read-only adapter for Watcher SQLite + portable Better Projects documents."""
from __future__ import annotations

from collections import defaultdict
from contextlib import closing
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import sqlite3

from .engine import calculate, composite
from .model import DIMENSIONS, VERSION, validate_manual_config
from .query import NAMED_VIEWS, select
from .store import ScoringStore
from .evidence import EvidenceStore, union_seconds
from .model import timestamp


class ScoringService:
    def __init__(self, database: Path, workspace_root: Path):
        self.database = Path(database).resolve()
        self.root = Path(workspace_root).resolve()
        self.store = ScoringStore(self.database.with_name("project-scoring.db"))

    def _projects_sessions(self):
        with closing(sqlite3.connect(self.database.as_uri()+"?mode=ro", uri=True)) as conn:
            conn.row_factory = sqlite3.Row
            conn.execute("BEGIN")  # consistent snapshot while the sensing process writes
            projects = [dict(r) for r in conn.execute("SELECT * FROM projects")]
            sessions = [dict(r) for r in conn.execute("SELECT * FROM sessions WHERE status='completed'")]
            # When sensing began: the earliest recorded session of any status.
            first = conn.execute("SELECT MIN(started_at) FROM sessions").fetchone()[0]
        def aware(value):
            parsed = datetime.fromisoformat(value)
            return parsed if parsed.tzinfo else parsed.replace(tzinfo=timezone.utc)
        self._aware = aware
        self.sensing_since = aware(first) if first else None
        return projects, sessions

    def catalog(self):
        return {"contract_version": VERSION, "dimensions": sorted(DIMENSIONS), "views": NAMED_VIEWS,
                "profiles": self.store.profiles(), "profile_records": self.store.records("profile"),
                "states": ["unknown", "provisional", "known"]}

    def projects(self, *, now=None, query=None, sort="importance", direction="desc", view=None,
                 profile_id=None, include_inactive=False):
        now = now or datetime.now(timezone.utc)
        projects, sessions = self._projects_sessions()
        def unobserved_since(project):
            # The later of sensing starting and this project being discovered.
            if self.sensing_since is None:
                return None
            try:
                discovered = self._aware(project["discovered_at"])
            except (KeyError, TypeError, ValueError):
                return self.sensing_since
            return max(self.sensing_since, discovered)
        by_project = defaultdict(list)
        for session in sessions:
            by_project[session["project_id"]].append(session)
        imported = self.store.records("manual_import")
        supplemental = self.store.records("inputs")
        profiles = self.store.profiles()
        if profile_id and profile_id not in profiles:
            raise ValueError("unknown profile")
        rows = []
        for project in projects:
            if not include_inactive and project["status"] != "active":
                continue
            document = (self.root/project["path"]/"Project.betterproject").resolve()
            warnings, state, revision, manifest = [], {}, None, {}
            try:
                if not document.is_relative_to(self.root):
                    raise ValueError("document outside workspace")
                if document.exists():
                    raw = document.read_bytes()
                    manifest = json.loads(raw)
                    if not isinstance(manifest, dict) or manifest.get("formatVersion") != 1:
                        raise ValueError("unsupported project document")
                    linked = manifest.get("workspaceProjectID")
                    if linked and linked != project["id"]:
                        raise ValueError("project document identity mismatch")
                    state = manifest.get("localState") or {}
                    if not isinstance(state, dict):
                        raise ValueError("invalid localState")
                    revision = hashlib.sha256(raw).hexdigest()
            except (OSError, ValueError, TypeError) as exc:
                warnings.append(str(exc)); state = {}; manifest = {}
            manual = imported.get(project["id"], {}).get("payload", {})
            # Presence of ratings, including {}, supersedes imports: deliberate clears survive.
            local_ratings = "ratings" in state
            ratings = state.get("ratings") if local_ratings else manual.get("ratings", {})
            source = "Project.betterproject:localState.ratings" if local_ratings else manual.get("source", "no manual data")
            inputs_row = supplemental.get(project["id"], {})
            inputs = state.get("scoring", inputs_row.get("payload"))
            config = state.get("scoringConfiguration") if local_ratings else manual.get("configuration")
            planning = {}
            try:
                dimensions = calculate(sessions=by_project[project["id"]], ratings=ratings,
                                       inputs=inputs, manual_config=config, manual_source=source, now=now,
                                       unobserved_since=unobserved_since(project))
                planning = {
                    "selected_outcome": (inputs or {}).get("next_scope_id"),
                    "scopes": [{"id": scope["id"], "revision": scope["revision"], "title": str(scope.get("title", scope["id"]))[:200],
                                "blocked": scope.get("blocked"), "leaf_count": len(scope["leaves"])} for scope in (inputs or {}).get("scopes", [])],
                    "tasks": [{"title": str(x.get("title", ""))[:200], "status": x.get("status")} for x in state.get("tasks", [])[:10] if isinstance(x, dict)],
                    "milestones": [{"title": str(x.get("title", ""))[:200], "status": x.get("status")} for x in state.get("milestones", [])[:10] if isinstance(x, dict)],
                }
            except (ValueError, KeyError, TypeError, AttributeError, OverflowError) as exc:
                # A malformed document must not take down scoring for the rest of the portfolio.
                # Preserve session evidence, with explicit warning; do not guess valid planning.
                warnings.append(f"Invalid scoring inputs: {exc}")
                try:
                    # Invalid outcome/coverage facts cannot erase independent manual judgments.
                    dimensions = calculate(sessions=by_project[project["id"]], ratings=ratings,
                                           manual_config=config, manual_source=source, now=now)
                except (ValueError, KeyError, TypeError, AttributeError, OverflowError):
                    dimensions = calculate(sessions=by_project[project["id"]], now=now)
            rows.append({"id": project["id"], "name": project["name"], "status": project["status"],
                         "document_revision": revision, "inputs_revision": inputs_row.get("revision"),
                         "manual_import_revision": imported.get(project["id"], {}).get("revision"),
                         "planning": planning, "dimensions": dimensions, "composites": {k: composite(dimensions, p, now=now) for k,p in profiles.items()},
                         "warnings": warnings})
        evidence = EvidenceStore(self.store.path).summary()
        for row in rows:
            items = [e for e in evidence["records"] if e["project_id"] == row["id"] and not e.get("stale")]
            intervals = []
            for e in items:
                if e["category"] == "attention_interval" and e["confidence"] >= .8:
                    intervals.extend((timestamp(a), timestamp(b)) for a,b in e["value"].get("not_afk_intervals", []) if timestamp(b) <= now)
            row["evidence_summary"] = {
                "git_commits_in_bounded_snapshot": sum(e["category"] == "git_commit" for e in items),
                "activitywatch_not_afk_seconds": union_seconds(intervals) if intervals else None,
                "time_policy": "Union of attributed AFK-filtered intervals (confidence >= 0.8); separate from Watcher hours, never summed.",
                "qualitative_claims": [e for e in items if e["provenance"] == "llm_extracted"][-10:],
                "evidence_ids": [e["id"] for e in items],
            }
        from .ai import current_comparisons
        return {"contract_version": VERSION, "calculated_at": now.isoformat(),
                "ai_comparisons": current_comparisons(rows, evidence, profiles),
                "projects": select(rows, query=query, sort=sort, direction=direction, view=view, profile_id=profile_id)}

    def ensure_write_safe(self):
        projects, _ = self._projects_sessions()
        # Never put a writable scoring DB in any observed project tree.
        if any(self.store.path.resolve().is_relative_to((self.root/p["path"]).resolve()) for p in projects):
            raise ValueError("scoring persistence must live outside observed project directories")
        return projects

    def save(self, kind, key, payload, expected_revision=0):
        projects = self.ensure_write_safe()
        if kind != "profile" and key not in {p["id"] for p in projects}:
            raise ValueError("unknown project id")
        return self.store.put(kind, key, payload, expected_revision=expected_revision)

    def import_manual_cache(self, cache_path: Path, *, apply=False, configuration=None):
        """Explicit migration, never automatic cache discovery or writes to source files.

        Join by stored Notion identity only; no fuzzy names or new project identities.
        Ambiguous/missing matches are reported. Repeated identical imports are no-ops.
        """
        validate_manual_config(configuration)
        data = json.loads(Path(cache_path).read_text())
        remote = defaultdict(list)
        for row in data.get("projects", []):
            if row.get("ratings"):
                remote[row["id"]].append(row)
        projects, _ = self._projects_sessions()
        candidates, skipped = [], []
        links = defaultdict(list)
        for project in projects:
            if project["status"] != "active":
                continue
            path = (self.root/project["path"]/"Project.betterproject").resolve()
            try:
                if not path.is_relative_to(self.root):
                    continue
                doc = json.loads(path.read_text())
                if doc.get("workspaceProjectID") not in (None, project["id"]):
                    continue
                if doc.get("notionProjectID"):
                    links[doc["notionProjectID"]].append((project,doc))
            except (OSError, ValueError, AttributeError):
                continue
        old = self.store.records("manual_import")
        for remote_id, records in remote.items():
            matches = links.get(remote_id, [])
            if len(records) != 1 or len(matches) != 1:
                skipped.append({"notion_id": remote_id, "reason": "missing or ambiguous identity match"}); continue
            project, doc = matches[0]
            if "ratings" in (doc.get("localState") or {}):
                skipped.append({"id": project["id"], "reason": "document ratings are authoritative"}); continue
            payload = {"ratings": records[0]["ratings"], "source": "explicit Better Projects cache import",
                       "source_project_id": remote_id, "configuration": configuration,
                       "source_last_refreshed": data.get("lastRefreshed")}
            previous = old.get(project["id"], {})
            changed = previous.get("payload") != payload
            candidates.append({"id": project["id"], "changed": changed})
            if apply and changed:
                self.save("manual_import", project["id"], payload, previous.get("revision", 0))
        return {"applied": apply, "candidates": candidates, "skipped": skipped}
