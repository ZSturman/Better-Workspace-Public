from pathlib import Path

from workspace_watcher.config import RouteConfig, default_config
from workspace_watcher.routing import Router


def test_universal_route_always_applies():
    cfg = default_config(Path("/tmp/x"))
    cfg.routes = [RouteConfig(area_kind="*", handlers=["log_event", "persist_event"])]
    router = Router.from_config(cfg)
    names = [n for n, _ in router.handlers_for("resources")]
    assert names == ["log_event", "persist_event"]


def test_specific_route_is_merged_on_top_of_universal():
    cfg = default_config(Path("/tmp/x"))
    cfg.routes = [
        RouteConfig(area_kind="*", handlers=["log_event", "persist_event"]),
        RouteConfig(area_kind="projects", handlers=["emit_event"]),
    ]
    router = Router.from_config(cfg)
    names = [n for n, _ in router.handlers_for("projects")]
    assert names == ["log_event", "persist_event", "emit_event"]


def test_duplicate_handler_names_are_deduplicated():
    cfg = default_config(Path("/tmp/x"))
    cfg.routes = [
        RouteConfig(area_kind="*", handlers=["log_event"]),
        RouteConfig(area_kind="inbox", handlers=["log_event", "emit_event"]),
    ]
    router = Router.from_config(cfg)
    names = [n for n, _ in router.handlers_for("inbox")]
    assert names == ["log_event", "emit_event"]


def test_unknown_handler_name_is_silently_skipped():
    cfg = default_config(Path("/tmp/x"))
    cfg.routes = [RouteConfig(area_kind="*", handlers=["log_event", "totally_made_up"])]
    router = Router.from_config(cfg)
    names = [n for n, _ in router.handlers_for("resources")]
    assert names == ["log_event"]
