"""Built-in handlers.

A handler receives a fully-formed `NormalizedEvent` and does something with
it. Handlers never see watchdog internals and are never required to
understand each other -- routing decides which handlers run for which
events (see routing.py / config.toml `[[routes]]`).

Core bookkeeping (fs_entries, project identity, active-project inference)
happens in watcher.py before routing, not here -- that state has to exist
regardless of which handlers a given area is configured to run. Handlers
are for what happens *because of* a fact, not for recording the fact
itself.

A handler that raises is caught by the dispatcher, logged to both the log
file and the `handler_errors` table, and does not stop other handlers from
running for the same event (see watcher.py `_dispatch`).
"""

from __future__ import annotations

import json
import logging
import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Optional

from .config import RunCommandConfig
from .events import NormalizedEvent
from .store import WorkspaceStore


@dataclass
class HandlerContext:
    store: WorkspaceStore
    logger: logging.Logger
    outbox_path: Path
    run_command_config: RunCommandConfig


Handler = Callable[[NormalizedEvent, HandlerContext], None]


def log_event(event: NormalizedEvent, ctx: HandlerContext) -> None:
    level = logging.INFO if event.meaningful else logging.DEBUG
    ctx.logger.log(level, event.summary())


def persist_event(event: NormalizedEvent, ctx: HandlerContext) -> None:
    ctx.store.insert_event(event)


def emit_event(event: NormalizedEvent, ctx: HandlerContext) -> None:
    """Append the event as one JSON line to the outbox file. This exists so
    an external consumer (a Hammerspoon poller, a future sync daemon) can
    `tail -f` a plain file without touching SQLite at all."""
    ctx.outbox_path.parent.mkdir(parents=True, exist_ok=True)
    with ctx.outbox_path.open("a", encoding="utf-8") as fh:
        fh.write(event.to_json() + "\n")


def run_command(event: NormalizedEvent, ctx: HandlerContext) -> None:
    cfg = ctx.run_command_config
    if not cfg.enabled or not cfg.command:
        return
    subprocess.run(
        cfg.command,
        input=event.to_json().encode("utf-8"),
        timeout=30,
        check=True,
    )


def noop(event: NormalizedEvent, ctx: HandlerContext) -> None:
    return None


BUILTIN_HANDLERS: dict[str, Handler] = {
    "log_event": log_event,
    "persist_event": persist_event,
    "emit_event": emit_event,
    "run_command": run_command,
    "noop": noop,
    "ignore": noop,
}
