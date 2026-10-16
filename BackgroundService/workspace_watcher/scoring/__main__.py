"""Explicit local tooling; normal scoring reads never ingest sources or call a model."""
import argparse
import json
from pathlib import Path
from .service import ScoringService


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--database", type=Path, required=True)
    p.add_argument("--workspace-root", type=Path, required=True)
    sub = p.add_subparsers(dest="command", required=True)
    sub.add_parser("catalog")
    query = sub.add_parser("query")
    query.add_argument("--view")
    query.add_argument("--profile-id")
    imp = sub.add_parser("import-manual")
    imp.add_argument("cache", type=Path)
    imp.add_argument("--configuration", type=Path)
    imp.add_argument("--apply", action="store_true")
    save = sub.add_parser("save")
    save.add_argument("kind", choices=["inputs", "profile"])
    save.add_argument("id")
    save.add_argument("payload", type=Path)
    save.add_argument("--expected-revision", type=int, default=0)
    # Optional sources run only as explicit bounded jobs, never in GET handlers.
    ingest = sub.add_parser("ingest")
    ingest.add_argument("source", choices=["git", "documents", "claude", "codex", "chatgpt", "activitywatch"])
    ingest.add_argument("--path", type=Path)
    ingest.add_argument("--project-id")
    ingest.add_argument("--limit", type=int, default=100)
    ai = sub.add_parser("ai")
    ai.add_argument("operation", choices=["extract", "compare"])
    ai.add_argument("--model", required=True)
    ai.add_argument("--endpoint", default="http://127.0.0.1:1234/v1")
    # A local model with a large evidence payload can genuinely need longer
    # than the default; a timeout is a failed job, not a wrong answer.
    ai.add_argument("--timeout", type=float, default=90.0)
    ai.add_argument("--profile-id", default="work-on")
    ai.add_argument("--limit", type=int, default=3)
    args = p.parse_args()
    service = ScoringService(args.database, args.workspace_root)
    try:
        if args.command == "catalog":
            result = service.catalog()
        elif args.command == "query":
            result = service.projects(view=args.view, profile_id=args.profile_id)
        elif args.command == "import-manual":
            config = json.loads(args.configuration.read_text()) if args.configuration else None
            result = service.import_manual_cache(args.cache, apply=args.apply, configuration=config)
        elif args.command == "save":
            result = service.save(args.kind, args.id, json.loads(args.payload.read_text()), args.expected_revision)
        elif args.command == "ingest":
            from .sources import ingest_source
            result = ingest_source(service, args.source, path=args.path, project_id=args.project_id, limit=args.limit)
        else:
            from .ai import LocalProvider, run_job
            result = run_job(service, LocalProvider(args.endpoint, args.model, timeout=args.timeout), args.operation, args.profile_id, args.limit)
        print(json.dumps(result, indent=2, allow_nan=False))
    except (ValueError, OSError, KeyError) as exc:
        p.exit(2, f"Scoring: {exc}\n")


if __name__ == "__main__":
    main()
