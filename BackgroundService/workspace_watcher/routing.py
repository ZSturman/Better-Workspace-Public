"""Routes a normalized event to the handlers configured for its area.

The universal route (`area_kind = "*"`) always applies. Handlers from the
route matching the event's specific area_kind are added on top, de-duplicated
by name. This means a new area added to config.toml only needs to list the
handlers it wants *in addition to* the defaults -- it doesn't have to repeat
"log_event" and "persist_event" every time.
"""

from __future__ import annotations

from dataclasses import dataclass

from .config import Config, RouteConfig
from .handlers import BUILTIN_HANDLERS, Handler


@dataclass
class Router:
    routes: list[RouteConfig]
    handlers: dict[str, Handler]

    @classmethod
    def from_config(cls, config: Config, extra_handlers: dict[str, Handler] | None = None) -> "Router":
        handlers = dict(BUILTIN_HANDLERS)
        if extra_handlers:
            handlers.update(extra_handlers)
        return cls(routes=config.routes, handlers=handlers)

    def handlers_for(self, area_kind: str) -> list[tuple[str, Handler]]:
        names: list[str] = []
        for route in self.routes:
            if route.area_kind in ("*", area_kind):
                for name in route.handlers:
                    if name not in names:
                        names.append(name)
        resolved = []
        for name in names:
            handler = self.handlers.get(name)
            if handler is not None:
                resolved.append((name, handler))
        return resolved
