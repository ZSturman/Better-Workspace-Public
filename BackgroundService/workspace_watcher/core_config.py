"""Configuration for the replacement core, isolated from legacy settings."""

from __future__ import annotations

import tomllib
from dataclasses import dataclass, field
from pathlib import Path

from .config import DEFAULT_IGNORE_PATTERNS, SELF_EXCLUDE_DEFAULT
from .intents import IntentFolderSettings


@dataclass(frozen=True)
class HammerspoonInboxSettings:
    """A durable, idempotent inbox for macOS-level signals a Hammerspoon (or
    other local) producer appends to. The producer never needs Workspace
    Watcher online at the moment an event happens -- see hammerspoon_inbox.py."""

    enabled: bool = False
    path: Path = Path("inbox/hammerspoon-events.jsonl")
    stale_after_minutes: float = 20.0


@dataclass(frozen=True)
class ProjectsSettings:
    """v2's own project identity: immediate child directories of a configured
    Projects root, tracked by (device, inode) so identity survives a rename.
    See ``projects_v2.py``."""

    enabled: bool = True
    root: str = "Projects"  # workspace-root-relative
    # Write and maintain Better Projects' Project.betterproject in each project
    # folder. Off: Better Workspace no longer needs it (see projects_v2).
    write_documents: bool = False


@dataclass(frozen=True)
class SessionsSettings:
    """v2's own work-session inference, keyed off ``ProjectsSettings``'s
    project identity. Time-based inactivity and hard-duration boundaries --
    deliberately independent of any Hammerspoon idle signal. Field names/defaults mirror
    v1's ``config.SessionSettings`` (same proven tuning), but this is its own
    independent setting: v2 never reads v1's ``[sessions]`` table. See
    ``sessions_v2.py``."""

    enabled: bool = True
    inactivity_timeout_minutes: float = 20.0
    max_duration_minutes: float = 480.0
    merge_nearby_minutes: float = 45.0
    minimum_events: int = 3
    minimum_active_seconds: float = 120.0
    event_active_seconds: float = 60.0
    event_span_seconds: float = 90.0
    burst_gap_minutes: float = 5.0
    minimum_confidence: float = 0.55
    git_metadata_enabled: bool = True


@dataclass(frozen=True)
class NotionSettings:
    """v2's own Notion integration settings -- a distinct namespace
    (``[workspace_watcher.notion]``) from v1's top-level ``[notion]`` table
    in ``config.py``; v2 never reads that one, and v1 never reads this one.
    Field names/semantics mirror v1's ``config.NotionSettings`` deliberately
    (same real Notion databases and ``notion_api`` client), but
    ownership is explicit and independent -- see ``notion_cache_v2.py`` and
    ``work_logs_v2.py``, and the Phase 3 section of the migration plan for
    why this isn't shared with v1."""

    enabled: bool = False
    refresh_minutes: float = 30.0
    env_file: str = ".env"
    token_env: str = "NOTION_API_KEY"
    projects_database_id: str = "304aec94-4d3c-80a8-82f6-fd7ff4d2b607"
    work_log_database_id: str = "304aec94-4d3c-803f-9e54-ffda217f9426"
    ideas_database_id: str = "304aec94-4d3c-8071-aae2-c18130d0e8e5"
    timeout_seconds: float = 30.0


@dataclass(frozen=True)
class WorkLogsSettings:
    """v2's own Work Log generation, built on ``SessionsSettings``'s
    sessions. ``notion_sync`` is the master safety switch for actually
    writing to Notion -- OFF by default, same caution as v1's
    ``[work_logs].notion_sync = false`` default, and independent of both
    ``NotionSettings.enabled`` (which only gates reading/caching Notion
    Projects) and v1's own ``[work_logs]`` table, which this never reads.
    See ``work_logs_v2.py``."""

    enabled: bool = True
    minimum_session_confidence: float = 0.55
    merge_by_project_day: bool = True
    notion_sync: bool = False
    # Third independent gate, alongside `notion_sync` and `NotionSettings.enabled`
    # above: which system is currently allowed to be the one writing real
    # Work Log pages to the shared Notion database. Three writers already
    # exist for this workspace (Hammerspoon's `work_sessions.service`, the
    # separately-scheduled `workspace_telemetry.worklog.WorklogPipeline`,
    # and this one) -- none of them coordinate with each other, so this
    # setting exists purely to make a human say "v2" on purpose before v2's
    # `notion_sync=true` can ever actually write, even if that flag alone
    # got flipped by mistake. "legacy" (the default) means v1/Hammerspoon's
    # systems are still the writer of record; `sync_pending()` in
    # `work_logs_v2.py` refuses to write unless this is exactly "v2".
    authoritative_writer: str = "legacy"


@dataclass(frozen=True)
class IdeasSettings:
    """The Ideas tab's own tuning, independent of the generic intent-folder
    indexing that already discovers `[[Ideas]]` (see intents.py/core_engine.py --
    an idea is just an intent-item whose containing folder is named "Ideas").
    `notion_sync` defaults to False, matching the same off-by-default caution
    as `WorkLogsSettings.notion_sync`: reading/organizing ideas locally never
    depends on this, only pushing/pulling the optional Notion mirror does."""

    enabled: bool = True
    notion_sync: bool = False
    resurfacing_max_results: int = 5
    resurfacing_minimum_days: int = 7


@dataclass(frozen=True)
class LMStudioSettings:
    """v2's optional LLM enrichment layer for Work Log drafts -- see
    ``lm_enrichment_v2.py``. Strictly a post-hoc enrichment on top of
    already-generated deterministic evidence; disabled by default, and
    deterministic Work Log generation works identically whether this is on
    or off. Reuses ``lm_studio.py``'s generic, store-agnostic
    ``LMStudioClient`` (v1's own -- no second OpenAI-compatible client)."""

    enabled: bool = False
    endpoint: str = "http://localhost:1234/v1"
    model: str = ""
    timeout_seconds: float = 8.0
    # Below this confidence, an extra "why is this low-confidence" pass
    # runs; a normal, confident session gets no such note at all.
    low_confidence_threshold: float = 0.6


@dataclass(frozen=True)
class CoreConfig:
    workspace_root: Path
    database_path: Path
    intent_settings: IntentFolderSettings
    config_path: Path
    rules_path: Path
    debounce_seconds: float = 0.5
    hammerspoon_inbox: HammerspoonInboxSettings = field(default_factory=HammerspoonInboxSettings)
    projects: ProjectsSettings = field(default_factory=ProjectsSettings)
    sessions: SessionsSettings = field(default_factory=SessionsSettings)
    notion: NotionSettings = field(default_factory=NotionSettings)
    work_logs: WorkLogsSettings = field(default_factory=WorkLogsSettings)
    ideas: IdeasSettings = field(default_factory=IdeasSettings)
    lm_studio: LMStudioSettings = field(default_factory=LMStudioSettings)
    # Shared with v1's `[ignore]` section (see DEFAULT_IGNORE_PATTERNS in
    # config.py). Without this the v2 runtime treats generated/background
    # writes as real work -- see `CoreRuntime._on_settled`.
    ignore_patterns: list[str] = field(default_factory=lambda: list(DEFAULT_IGNORE_PATTERNS))
    # ``None`` means "derive from ``database_path``" (see
    # ``CoreConfig.self_exclude_relpath``). Self-exclusion is a safety
    # invariant, not a preference, so it is computed rather than configured:
    # without it the watcher observes its own writes and feeds itself an
    # endless stream of activity.
    self_exclude_override: str | None = None

    @property
    def self_exclude_relpath(self) -> str:
        try:
            return self.self_exclude_override or self.database_path.parent.relative_to(self.workspace_root).as_posix()
        except ValueError:
            # A database outside the workspace cannot be observed by the
            # watcher at all, so nothing needs excluding.
            return self.self_exclude_override or SELF_EXCLUDE_DEFAULT


def load_core_config(path: Path | None = None, workspace_root: Path | None = None) -> CoreConfig:
    path = path or (Path(__file__).resolve().parents[1] / "config.toml")
    raw: dict = {}
    if path.exists():
        with path.open("rb") as stream:
            raw = tomllib.load(stream)
    core = raw.get("workspace_watcher", {})
    root = (workspace_root or Path(core.get("workspace_root") or raw.get("workspace", {}).get("root") or Path.cwd())).expanduser().resolve()
    storage = core.get("storage", {})
    db = Path(storage.get("database", root / "Logs/workspace-watcher/core.db")).expanduser()
    if not db.is_absolute():
        db = root / db
    intent = core.get("intent_folders", {})
    roots = [root / item for item in intent.get("search_roots", [".", "Temporary", "Projects"])]
    excludes = [root / item for item in intent.get("excluded_roots", ["Logs/workspace-watcher"])]
    rules_value = core.get("rules_file", "rules.toml")
    rules_path = Path(rules_value).expanduser()
    if not rules_path.is_absolute():
        rules_path = path.parent / rules_path
    watcher = core.get("watcher", {})
    hammerspoon = core.get("hammerspoon_inbox", {})
    inbox_path = Path(hammerspoon.get("path", "inbox/hammerspoon-events.jsonl")).expanduser()
    if not inbox_path.is_absolute():
        inbox_path = db.parent / inbox_path
    projects_raw = core.get("projects", {})
    sessions_raw = core.get("sessions", {})
    notion_raw = core.get("notion", {})
    work_logs_raw = core.get("work_logs", {})
    ideas_raw = core.get("ideas", {})
    lm_studio_raw = core.get("lm_studio", {})
    # `[ignore]` is a top-level section shared with v1 so one workspace has a
    # single answer to "what is generated noise?" -- `patterns` replaces the
    # built-in list, `extend` adds to whichever list is in effect.
    ignore_section = raw.get("ignore", {})
    ignore_patterns = list(ignore_section["patterns"]) if "patterns" in ignore_section else list(DEFAULT_IGNORE_PATTERNS)
    ignore_patterns += list(ignore_section.get("extend") or [])
    return CoreConfig(
        root,
        db.resolve(),
        IntentFolderSettings(
            search_roots=tuple(roots),
            excluded_roots=tuple(excludes),
            follow_symlinks=bool(intent.get("follow_symlinks", False)),
            allow_nested=bool(intent.get("allow_nested", False)),
            declared=tuple((root / folder, str(name)) for folder, name in (intent.get("declared") or {}).items()),
        ),
        path.resolve(),
        rules_path.resolve(),
        float(watcher.get("debounce_seconds", 0.5)),
        HammerspoonInboxSettings(
            enabled=bool(hammerspoon.get("enabled", False)),
            path=inbox_path,
            stale_after_minutes=float(hammerspoon.get("stale_after_minutes", 20.0)),
        ),
        ProjectsSettings(
            enabled=bool(projects_raw.get("enabled", True)),
            root=str(projects_raw.get("root", "Projects")),
            write_documents=bool(projects_raw.get("write_documents", False)),
        ),
        SessionsSettings(
            enabled=bool(sessions_raw.get("enabled", True)),
            inactivity_timeout_minutes=float(sessions_raw.get("inactivity_timeout_minutes", 20.0)),
            max_duration_minutes=float(sessions_raw.get("max_duration_minutes", 480.0)),
            merge_nearby_minutes=float(sessions_raw.get("merge_nearby_minutes", 45.0)),
            minimum_events=int(sessions_raw.get("minimum_events", 3)),
            minimum_active_seconds=float(sessions_raw.get("minimum_active_seconds", 120.0)),
            event_active_seconds=float(sessions_raw.get("event_active_seconds", 60.0)),
            event_span_seconds=float(sessions_raw.get("event_span_seconds", 90.0)),
            burst_gap_minutes=float(sessions_raw.get("burst_gap_minutes", 5.0)),
            minimum_confidence=float(sessions_raw.get("minimum_confidence", 0.55)),
            git_metadata_enabled=bool(sessions_raw.get("git_metadata_enabled", True)),
        ),
        NotionSettings(
            enabled=bool(notion_raw.get("enabled", False)),
            refresh_minutes=float(notion_raw.get("refresh_minutes", 30.0)),
            env_file=str(notion_raw.get("env_file", ".env")),
            token_env=str(notion_raw.get("token_env", "NOTION_API_KEY")),
            projects_database_id=str(notion_raw.get("projects_database_id", "304aec94-4d3c-80a8-82f6-fd7ff4d2b607")),
            work_log_database_id=str(notion_raw.get("work_log_database_id", "304aec94-4d3c-803f-9e54-ffda217f9426")),
            ideas_database_id=str(notion_raw.get("ideas_database_id", "304aec94-4d3c-8071-aae2-c18130d0e8e5")),
            timeout_seconds=float(notion_raw.get("timeout_seconds", 30.0)),
        ),
        WorkLogsSettings(
            enabled=bool(work_logs_raw.get("enabled", True)),
            minimum_session_confidence=float(work_logs_raw.get("minimum_session_confidence", 0.55)),
            merge_by_project_day=bool(work_logs_raw.get("merge_by_project_day", True)),
            notion_sync=bool(work_logs_raw.get("notion_sync", False)),
            authoritative_writer=str(work_logs_raw.get("authoritative_writer", "legacy")),
        ),
        IdeasSettings(
            enabled=bool(ideas_raw.get("enabled", True)),
            notion_sync=bool(ideas_raw.get("notion_sync", False)),
            resurfacing_max_results=int(ideas_raw.get("resurfacing_max_results", 5)),
            resurfacing_minimum_days=int(ideas_raw.get("resurfacing_minimum_days", 7)),
        ),
        LMStudioSettings(
            enabled=bool(lm_studio_raw.get("enabled", False)),
            endpoint=str(lm_studio_raw.get("endpoint", "http://localhost:1234/v1")),
            model=str(lm_studio_raw.get("model", "")),
            timeout_seconds=float(lm_studio_raw.get("timeout_seconds", 8.0)),
            low_confidence_threshold=float(lm_studio_raw.get("low_confidence_threshold", 0.6)),
        ),
        ignore_patterns=ignore_patterns,
    )
