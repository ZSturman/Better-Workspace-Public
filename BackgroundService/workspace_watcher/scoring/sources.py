"""Bounded, opt-in local adapters. No network outside loopback, no cloud history APIs."""
from __future__ import annotations

from datetime import datetime, timedelta, timezone
import hashlib
import json
from pathlib import Path
import re
import subprocess
from urllib.parse import urlencode, quote
from urllib.request import build_opener, ProxyHandler

from .ai import _NoRedirects

urlopen = build_opener(ProxyHandler({}), _NoRedirects()).open

from .evidence import EvidenceStore, digest, record, union_seconds
from .model import timestamp


class Attribution:
    def __init__(self, projects, root):
        self.paths = {p["id"]: (root/p["path"]).resolve() for p in projects if p["status"] == "active"}
        self.names = {p["id"]: p["name"] for p in projects if p["id"] in self.paths}

    def path(self, value):
        if not value or not isinstance(value, str) or not Path(value).is_absolute():
            return None
        path = Path(value).resolve()
        matches = [pid for pid, root in self.paths.items() if path == root or path.is_relative_to(root)]
        return (matches[0], 1.0, "explicit path") if len(matches) == 1 else None

    def event(self, data):
        for key in ("cwd", "file", "path"):
            match = self.path(data.get(key))
            if match:
                return match
        # Exact editor workspace name is stronger than a window title token.
        matches = [pid for pid,n in self.names.items() if n.casefold() == str(data.get("project", "")).casefold()]
        if len(matches) == 1:
            return matches[0], .8, "exact unique editor project name"
        title = str(data.get("title", ""))
        matches = [pid for pid,n in self.names.items() if len(n) >= 4 and re.search(r"(?<!\w)"+re.escape(n)+r"(?!\w)", title, re.I)]
        return (matches[0], .45, "unique title token; unconfirmed") if len(matches) == 1 else None


def _text(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "\n".join(str(b.get("text", "")) for b in content if isinstance(b, dict) and b.get("type") in {"text", "input_text", "output_text"})
    return ""


def ingest_jsonl(store, path, source, attribution, limit):
    source_id = f"{source}:{path.resolve()}"
    old = store.job("checkpoint", source_id) or {}
    stat = path.stat()
    with path.open("rb") as f:
        head = hashlib.sha256(f.read(min(stat.st_size, 4096))).hexdigest()
        # For append-only files, hash the same prefix length used at checkpoint.
        f.seek(0); previous_head = hashlib.sha256(f.read(old.get("head_length", 0))).hexdigest()
        offset = old.get("offset", 0)
        f.seek(max(0, offset-4096)); tail = hashlib.sha256(f.read(min(offset,4096))).hexdigest()
        reset = bool(old) and (old.get("inode") != stat.st_ino or stat.st_size < offset or
                    old.get("head") != previous_head or old.get("tail") != tail or
                    (stat.st_size == old.get("size") and stat.st_mtime_ns != old.get("mtime")))
        if reset:
            offset = 0
        if old and not reset and old.get("size") == stat.st_size and old.get("mtime") == stat.st_mtime_ns and offset == stat.st_size:
            return {"ingested": 0, "skipped": "unchanged"}
        cwd = None if reset else old.get("cwd")
        f.seek(offset)
        records = []; scanned = 0
        while len(records) < limit and scanned < limit*20:
            start = f.tell()
            line = f.readline(1024*1024+1)
            if not line:
                break
            if len(line) > 1024*1024:
                raise ValueError("conversation record exceeds 1 MiB; split/export a bounded history")
            if not line.endswith(b"\n"):
                f.seek(start); break  # a live writer has not finished this record
            scanned += 1
            try:
                row = json.loads(line)
            except ValueError:
                continue
            payload = row.get("payload", {})
            if source == "codex":
                if row.get("type") in {"session_meta", "turn_context"}:
                    cwd = payload.get("cwd", cwd)
                if row.get("type") != "response_item" or payload.get("type") != "message":
                    continue
                message = payload
            else:
                cwd = row.get("cwd", cwd)
                message = row.get("message", {})
            match = attribution.path(cwd)
            if not match or message.get("role") not in {"user", "assistant"}:
                continue
            text = _text(message.get("content"))
            if not text.strip():
                continue
            at = row.get("timestamp")
            try:
                at = timestamp(at).isoformat()
            except ValueError:
                continue
            pid, confidence, reason = match
            records.append(record(source_type=source, source_id=source_id, project_id=pid, category="conversation_excerpt",
                                  value={"text": text[:4000], "truncated": len(text)>4000, "role": message["role"], "attribution": reason},
                                  at=at, reference=f"{path.resolve()}#byte={start}", confidence=confidence,
                                  origin="human" if message["role"] == "user" else "agent", identity=str(start)))
        offset = f.tell()
        f.seek(max(0,offset-4096)); tail = hashlib.sha256(f.read(min(offset,4096))).hexdigest()
    checkpoint = {"inode": stat.st_ino, "size": stat.st_size, "mtime": stat.st_mtime_ns,
                  "file_path": str(path.resolve()), "head": head, "head_length": min(stat.st_size,4096), "tail": tail, "offset": offset, "cwd": cwd}
    store.ingest(source_id, records, reset=reset, checkpoint=checkpoint)
    return {"ingested": len(records), "scanned": scanned, "pending_bytes": stat.st_size-offset, "reset": reset}


def ingest_documents(store, root, pid, limit):
    candidates = sorted({*root.glob("README*"), *root.glob("TODO*"), *root.glob("CHANGELOG*"), *root.glob("PLAN*"),
                         *root.glob("docs/*.md")})[:limit]
    count = 0
    for path in candidates:
        if not path.is_file() or path.is_symlink() or not path.resolve().is_relative_to(root) or path.stat().st_size > 65536:
            continue
        raw = path.read_bytes()
        revision = hashlib.sha256(raw).hexdigest()
        source_id = f"document:{path.resolve()}"
        if (store.job("checkpoint", source_id) or {}).get("revision") == revision:
            continue
        text = raw.decode("utf-8", errors="replace")
        at = datetime.fromtimestamp(path.stat().st_mtime, timezone.utc).isoformat()
        r = record(source_type="documentation", source_id=source_id, project_id=pid, category="document_excerpt",
                   value={"text": text[:6000], "truncated": len(text)>6000, "file_hash": revision}, at=at,
                   reference=str(path.resolve()))
        store.ingest(source_id, [r], reset=True, checkpoint={"revision": revision, "file_path": str(path.resolve()), "size": path.stat().st_size, "mtime": path.stat().st_mtime_ns}); count += 1
    return {"ingested": count, "files_considered": len(candidates)}


def ingest_git(store, root, pid, limit):
    def git(*args):
        try:
            result = subprocess.run(["git", "--no-optional-locks", "-C", str(root), *args], capture_output=True, text=True, timeout=10)
        except subprocess.TimeoutExpired as exc:
            raise ValueError("Git evidence collection exceeded its 10-second command budget") from exc
        if result.returncode:
            raise ValueError("Git repository unavailable or has no commits")
        return result.stdout
    if Path(git("rev-parse", "--show-toplevel").strip()).resolve() != root:
        raise ValueError("project is nested in another repository; explicit association required")
    refs = git("show-ref")
    source_id = f"git:{root}"
    revision = digest([refs, limit])
    if (store.job("checkpoint", source_id) or {}).get("revision") == revision:
        return {"ingested": 0, "skipped": "unchanged refs"}
    output = git("log", "--all", f"-n{limit}", "--date=iso-strict", "--format=%x1e%H%x1f%aI%x1f%P%x1f%s", "--numstat")
    records = []
    for block in output.split("\x1e"):
        if not block.strip():
            continue
        lines = block.strip().splitlines()
        sha, at, parents, subject = lines[0].split("\x1f", 3)
        stats = [line.split("\t", 2) for line in lines[1:] if "\t" in line]
        additions = sum(int(x[0]) for x in stats if x[0].isdigit())
        deletions = sum(int(x[1]) for x in stats if x[1].isdigit())
        records.append(record(source_type="git", source_id=source_id, project_id=pid, category="git_commit",
                              value={"sha": sha, "subject": subject[:300], "merge": len(parents.split())>1,
                                     "files": len(stats), "additions": additions, "deletions": deletions,
                                     "possible_revert": subject.lower().startswith("revert"),
                                     "note": "Patch magnitude and commit count are activity, not accepted delivery."},
                              at=at, reference=f"{root}#commit={sha}", identity=sha, origin="unattributed"))
    # Bounded snapshot is replaced on ref changes: unreachable/rebased commits do not linger.
    store.ingest(source_id, records, reset=True, checkpoint={"revision": revision, "refs": refs[:12000],
                    "bounded_commit_limit": limit, "possibly_truncated": len(records)==limit})
    return {"ingested": len(records), "possibly_truncated": len(records)==limit}


def ingest_chatgpt(store, path, pid, limit):
    if path.stat().st_size > 50*1024*1024:
        raise ValueError("ChatGPT export exceeds 50 MiB; provide a smaller project-specific export")
    raw = path.read_bytes(); revision = hashlib.sha256(raw).hexdigest()
    source_id = f"chatgpt:{path.resolve()}:{pid}"
    old = store.job("checkpoint", source_id) or {}
    if old.get("revision") == revision and old.get("complete"):
        return {"ingested": 0, "skipped": "unchanged"}
    reset = old.get("revision") != revision
    offset = 0 if reset else old.get("offset", 0)
    conversations = json.loads(raw)
    if not isinstance(conversations, list):
        raise ValueError("expected ChatGPT conversations.json export array")
    records = []; index = 0
    for conv in conversations:
        for node_id, node in conv.get("mapping", {}).items():
            index += 1
            if index <= offset or len(records) >= limit:
                continue
            message = node.get("message") or {}
            role = message.get("author", {}).get("role")
            if role not in {"user", "assistant"}:
                offset = index; continue
            content = message.get("content", {})
            text = "\n".join(x for x in content.get("parts", []) if isinstance(x,str))
            if not text or not message.get("create_time"):
                offset = index; continue
            at = datetime.fromtimestamp(message["create_time"], timezone.utc).isoformat()
            records.append(record(source_type="chatgpt_export", source_id=source_id, project_id=pid,
                                  category="conversation_excerpt", value={"text": text[:4000], "truncated": len(text)>4000,
                                  "role": role, "attribution": "user-selected project-specific export"}, at=at,
                                  reference=f"{path.resolve()}#conversation={conv.get('id')}&node={node_id}",
                                  identity=f"{conv.get('id')}:{node_id}", origin="human" if role=="user" else "agent"))
            offset = index
    store.ingest(source_id, records, reset=reset, checkpoint={"revision": revision, "offset": offset, "complete": offset>=index, "file_path": str(path.resolve()), "size": path.stat().st_size, "mtime": path.stat().st_mtime_ns})
    return {"ingested": len(records), "complete": offset>=index}


def ingest_activitywatch(store, attribution, limit):
    def get(route):
        with urlopen("http://127.0.0.1:5600/api/0/"+route, timeout=3) as response:
            return json.load(response)
    buckets = get("buckets/")
    afk = {}; results = []; unmatched = 0
    # Host-specific AFK avoids using another machine's presence as evidence.
    for key, bucket in buckets.items():
        if bucket.get("type") == "afkstatus":
            afk[bucket.get("hostname", key.removeprefix("aw-watcher-afk_"))] = get("buckets/"+quote(key,safe="")+"/events?"+urlencode({"limit":limit}))
    for key, bucket in buckets.items():
        if bucket.get("type") not in {"currentwindow", "app.editor.activity", "web.tab.current"}:
            continue
        events = get("buckets/"+quote(key,safe="")+"/events?"+urlencode({"limit":limit}))
        presence = afk.get(bucket.get("hostname"), [])
        source_id = f"activitywatch:{key}"
        revision = digest([events,presence])
        if (store.job("checkpoint", source_id) or {}).get("revision") == revision:
            continue
        records = []
        for event in events:
            match = attribution.event(event.get("data", {}))
            if not match:
                unmatched += 1; continue
            pid, confidence, reason = match
            start = timestamp(event["timestamp"])
            end = start+timedelta(seconds=max(0,float(event.get("duration",0))))
            intervals = []
            for a in presence:
                if a.get("data",{}).get("status") == "not-afk":
                    lo = timestamp(a["timestamp"]); hi = lo+timedelta(seconds=max(0,float(a.get("duration",0))))
                    if min(end,hi)>max(start,lo):
                        intervals.append((max(start,lo),min(end,hi)))
            records.append(record(source_type="activitywatch", source_id=source_id, project_id=pid, category="attention_interval",
                                  value={"start": start.isoformat(), "end": end.isoformat(), "app": event.get("data",{}).get("app"),
                                         "not_afk_intervals": [[a.isoformat(),b.isoformat()] for a,b in intervals],
                                         "not_afk_seconds": union_seconds(intervals) if presence else None,
                                         "attribution": reason, "bounded_snapshot": True}, at=start.isoformat(),
                                  confidence=confidence, reference=f"{source_id}/events/{event.get('id')}", identity=str(event.get("id")), origin="human_presence_proxy"))
        store.ingest(source_id, records, reset=True, checkpoint={"revision":revision,"limit":limit})
        results.append({"bucket":key,"ingested":len(records),"possibly_truncated":len(events)==limit})
    return {"buckets": results, "unattributed": unmatched,
            "note": "Bounded snapshots. AFK intersections are partial observations; never added to Watcher hours."}


def ingest_source(service, source, *, path=None, project_id=None, limit=100):
    if not 1 <= limit <= 500:
        raise ValueError("limit must be 1–500")
    projects = service.ensure_write_safe()
    attribution = Attribution(projects, service.root)
    store = EvidenceStore(service.store.path)
    if source == "activitywatch":
        return ingest_activitywatch(store, attribution, limit)
    if source in {"git", "documents", "chatgpt"}:
        if project_id not in attribution.paths:
            raise ValueError("an active --project-id is required")
        if source == "git":
            return ingest_git(store, attribution.paths[project_id], project_id, limit)
        if source == "documents":
            return ingest_documents(store, attribution.paths[project_id], project_id, limit)
        if path is None:
            raise ValueError("ChatGPT needs an explicit project-specific export --path; no local history API assumed")
        return ingest_chatgpt(store, path, project_id, limit)
    root = path or (Path.home()/('.claude/projects' if source == 'claude' else '.codex/sessions'))
    files = [root] if root.is_file() else sorted(root.glob("**/*.jsonl"), key=lambda p:p.stat().st_mtime, reverse=True)
    results = []; remaining = limit
    # Files are scanned incrementally. Bound file opens and emitted excerpts per job.
    for file in files[:50]:
        if remaining <= 0:
            break
        result = ingest_jsonl(store,file,source,attribution,remaining)
        remaining -= result["ingested"]
        results.append(result)
    return {"files_considered":len(results),"ingested":limit-remaining,"results":results,
            "note":"Only the 50 most recently modified files are considered; use --path for older history."}
