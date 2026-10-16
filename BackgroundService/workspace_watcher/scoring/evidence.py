"""Reusable local evidence ledger, source checkpoints and cached AI results.

Evidence never updates deterministic outcomes, ratings or observed session time.
"""
from __future__ import annotations

from datetime import datetime, timezone
from contextlib import closing, contextmanager
import hashlib
import json
from pathlib import Path
import sqlite3

from .model import number, timestamp


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, allow_nan=False, separators=(",", ":")).encode()).hexdigest()


class EvidenceStore:
    def __init__(self, path: Path):
        self.path = Path(path)

    @contextmanager
    def _write(self):
        self.path.parent.mkdir(parents=True, exist_ok=True)
        conn = sqlite3.connect(self.path, timeout=5)
        conn.execute("CREATE TABLE IF NOT EXISTS scoring_records (kind TEXT NOT NULL,key TEXT NOT NULL,payload TEXT NOT NULL,revision INTEGER NOT NULL,updated_at TEXT NOT NULL,PRIMARY KEY(kind,key))")
        conn.execute("CREATE TABLE IF NOT EXISTS scoring_evidence (id TEXT PRIMARY KEY,source_id TEXT NOT NULL,project_id TEXT NOT NULL,payload TEXT NOT NULL)")
        conn.execute("CREATE INDEX IF NOT EXISTS scoring_evidence_project ON scoring_evidence(project_id)")
        conn.execute("CREATE TABLE IF NOT EXISTS scoring_jobs (kind TEXT NOT NULL,key TEXT NOT NULL,payload TEXT NOT NULL,PRIMARY KEY(kind,key))")
        try:
            with conn:
                yield conn
        finally:
            conn.close()

    def _read(self, sql, params=()):
        if not self.path.exists():
            return []
        with closing(sqlite3.connect(self.path.as_uri()+"?mode=ro", uri=True)) as conn:
            tables = {r[0] for r in conn.execute("SELECT name FROM sqlite_master WHERE type='table'")}
            if "scoring_evidence" not in tables:
                return []
            return conn.execute(sql, params).fetchall()

    def records(self, project_id=None):
        rows = self._read("SELECT payload FROM scoring_evidence" + (" WHERE project_id=?" if project_id else ""), (project_id,) if project_id else ())
        return sorted((json.loads(r[0]) for r in rows), key=lambda e: (e["timestamp"], e["id"]))

    def job(self, kind, key):
        rows = self._read("SELECT payload FROM scoring_jobs WHERE kind=? AND key=?", (kind,key))
        return json.loads(rows[0][0]) if rows else None

    def save_job(self, kind, key, payload):
        with self._write() as conn:
            conn.execute("INSERT INTO scoring_jobs VALUES (?,?,?) ON CONFLICT(kind,key) DO UPDATE SET payload=excluded.payload", (kind,key,json.dumps(payload, allow_nan=False)))

    def ingest(self, source_id, records, *, reset=False, checkpoint=None):
        for r in records:
            if r.get("source_id") != source_id or not r.get("project_id"):
                raise ValueError("evidence requires source and project identity")
            timestamp(r["timestamp"])
            number(r["confidence"], maximum=1)
            if r.get("provenance") not in {"observed", "deterministic", "manual", "llm_extracted", "llm_inference"}:
                raise ValueError("invalid provenance")
        with self._write() as conn:
            if reset:
                conn.execute("DELETE FROM scoring_evidence WHERE source_id=?", (source_id,))
            for r in records:
                conn.execute("INSERT INTO scoring_evidence VALUES (?,?,?,?) ON CONFLICT(id) DO UPDATE SET source_id=excluded.source_id,project_id=excluded.project_id,payload=excluded.payload",
                             (r["id"],source_id,r["project_id"],json.dumps(r, allow_nan=False)))
            if checkpoint is not None:
                conn.execute("INSERT INTO scoring_jobs VALUES ('checkpoint',?,?) ON CONFLICT(kind,key) DO UPDATE SET payload=excluded.payload", (source_id,json.dumps(checkpoint)))
        return len(records)

    def summary(self):
        records = self.records()
        # Derived evidence retains the exact source revision and becomes stale if it changes.
        checkpoints = {key: json.loads(payload) for key,payload in self._read("SELECT key,payload FROM scoring_jobs WHERE kind='checkpoint'")}
        changed_sources = set()
        for source, checkpoint in checkpoints.items():
            if checkpoint.get("file_path"):
                try:
                    stat = Path(checkpoint["file_path"]).stat()
                    if stat.st_size != checkpoint.get("size") or stat.st_mtime_ns != checkpoint.get("mtime"):
                        changed_sources.add(source)
                except OSError:
                    changed_sources.add(source)
        revisions = {r["id"]: r["revision"] for r in records if r["provenance"] not in {"llm_extracted", "llm_inference"} and r["source_id"] not in changed_sources}
        for row in records:
            dependencies = row.get("dependencies", {})
            row["stale"] = row["source_id"] in changed_sources or any(revisions.get(k) != v for k,v in dependencies.items())
        comparisons = [json.loads(r[0]) for r in self._read("SELECT payload FROM scoring_jobs WHERE kind='comparison'")]
        return {"records": records, "comparisons": comparisons}


def record(*, source_type, source_id, project_id, category, value, at, reference,
           confidence=1.0, origin="automatic", provenance="observed", model=None,
           identity=None, dependencies=None):
    revision = digest({"value": value, "at": at, "reference": reference})
    return {"id": digest([source_id, identity or reference, category, project_id]),
            "source_type": source_type, "source_id": source_id, "timestamp": at,
            "project_id": project_id, "category": category, "value": value,
            "confidence": confidence, "origin": origin, "provenance": provenance,
            "source_reference": reference, "extraction_model": model,
            "extraction_version": "1", "revision": revision,
            "dependencies": dependencies or {}, "recorded_at": datetime.now(timezone.utc).isoformat()}


def union_seconds(intervals):
    """Union of [start,end] intervals, never sum overlapping sensors/windows."""
    merged = []
    for start, end in sorted(intervals):
        if end <= start:
            continue
        if merged and start <= merged[-1][1]:
            merged[-1] = (merged[-1][0], max(end, merged[-1][1]))
        else:
            merged.append((start,end))
    return sum((b-a).total_seconds() for a,b in merged)
