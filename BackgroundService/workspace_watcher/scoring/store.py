"""Independent local persistence. Reads never create a file or run a migration.

Only explicit profile/input/import operations write. Scores are disposable read
models, not writes into project folders. CoreStore and macOS schemas stay intact.
"""
from __future__ import annotations

from contextlib import closing
import json
import sqlite3
from pathlib import Path
from datetime import datetime, timezone

from .model import validate_inputs, validate_profile

DEFAULT_PROFILES = [
    {"id": "work-on", "name": "What Should I Work On?", "weights": {"importance": 30, "urgency": 15, "finishability": 15, "momentum_30d": 15, "neglect": 10, "potential": 15}},
    {"id": "quick-win", "name": "Best Quick Win", "weights": {"near_done": 40, "finishability": 60}},
    {"id": "opportunity", "name": "Highest Opportunity", "weights": {"potential": 50, "importance": 30, "momentum_30d": 20}},
]


class ScoringStore:
    def __init__(self, path: Path):
        self.path = Path(path)

    def records(self, kind: str) -> dict:
        if not self.path.exists():
            return {}
        with closing(sqlite3.connect(self.path.as_uri()+"?mode=ro", uri=True)) as conn:
            return {key: {"payload": json.loads(payload), "revision": revision, "updated_at": updated}
                    for key, payload, revision, updated in conn.execute(
                        "SELECT key,payload,revision,updated_at FROM scoring_records WHERE kind=?", (kind,))}

    def profiles(self):
        profiles = {p["id"]: validate_profile(p) for p in DEFAULT_PROFILES}
        profiles.update({key: row["payload"] for key, row in self.records("profile").items()})
        return profiles

    def put(self, kind, key, payload, *, expected_revision=0):
        if kind not in {"profile", "inputs", "manual_import"}:
            raise ValueError("unsupported record kind")
        if not isinstance(key, str) or not key:
            raise ValueError("record key required")
        if kind == "profile":
            payload = validate_profile(payload)
            if payload["id"] != key:
                raise ValueError("profile id mismatch")
        if kind == "inputs":
            validate_inputs(payload)
        encoded = json.dumps(payload, allow_nan=False, sort_keys=True)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        with closing(sqlite3.connect(self.path, timeout=5)) as conn, conn:
            conn.execute("CREATE TABLE IF NOT EXISTS scoring_records (kind TEXT NOT NULL,key TEXT NOT NULL,payload TEXT NOT NULL,revision INTEGER NOT NULL,updated_at TEXT NOT NULL,PRIMARY KEY(kind,key))")
            conn.execute("BEGIN IMMEDIATE")
            row = conn.execute("SELECT revision FROM scoring_records WHERE kind=? AND key=?", (kind,key)).fetchone()
            revision = row[0] if row else 0
            if revision != expected_revision:
                raise ValueError(f"revision conflict: expected {expected_revision}, current {revision}")
            conn.execute("INSERT INTO scoring_records VALUES (?,?,?,?,?) ON CONFLICT(kind,key) DO UPDATE SET payload=excluded.payload,revision=excluded.revision,updated_at=excluded.updated_at",
                         (kind, key, encoded, revision+1, datetime.now(timezone.utc).isoformat()))
        return {"id": key, "revision": revision+1}
