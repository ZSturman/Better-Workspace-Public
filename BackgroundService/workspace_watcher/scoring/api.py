"""Isolated HTTP integration. No inference or source ingestion in request handlers."""
from urllib.parse import urlsplit
import sqlite3
from .service import ScoringService


def dispatch(handler, config, *, body=None):
    path = urlsplit(handler.path).path
    if not path.startswith("/v1/scoring/"):
        return False
    service = ScoringService(config.database_path, config.workspace_root)
    try:
        if body is None and path == "/v1/scoring/catalog":
            result = service.catalog()
        elif body is None and path == "/v1/scoring/projects":
            result = service.projects()
        elif body is None and path == "/v1/scoring/evidence":
            from .evidence import EvidenceStore
            result = EvidenceStore(service.store.path).summary()
        elif body is not None and path == "/v1/scoring/query":
            allowed = {"query", "sort", "direction", "view", "profile_id", "include_inactive"}
            if set(body)-allowed:
                raise ValueError("unsupported query option")
            if "include_inactive" in body and not isinstance(body["include_inactive"], bool):
                raise ValueError("include_inactive must be boolean")
            result = service.projects(**body)
        elif body is not None and path in {"/v1/scoring/profiles", "/v1/scoring/inputs"}:
            kind = "profile" if path.endswith("profiles") else "inputs"
            result = service.save(kind, body["id"], body["payload"], body.get("expected_revision", 0))
        else:
            handler._reply({"error": "not found"}, 404)
            return True
        handler._reply(result)
    except (ValueError, KeyError, TypeError) as exc:
        handler._reply({"error": str(exc)}, 400)
    except (OSError, sqlite3.Error):
        handler._reply({"error": "local scoring source unavailable"}, 503)
    return True
