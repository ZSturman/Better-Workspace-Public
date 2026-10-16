"""Configuration loading.

Config lives in a TOML file (default: config.toml next to this package).
Everything has a sensible built-in default so the watcher runs out of the
box against the real Workspace layout without requiring any config at all.
"""

from __future__ import annotations

import re
import tomllib
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Optional

from .durations import parse_duration_seconds

DEFAULT_IGNORE_PATTERNS: list[str] = [
    # VCS / package managers / dependency trees
    ".git", ".hg", ".svn",
    "node_modules", "bower_components",
    ".venv", "venv", ".virtualenv", "__pycache__", "*.pyc", "*.pyo",
    ".tox", ".mypy_cache", ".pytest_cache", ".ruff_cache",
    ".uv-cache", ".uv-python",
    "Pods", ".gradle", "target",
    # Build artifacts / generated output
    "dist", "build", ".build", ".next", ".nuxt", ".vinext", ".wrangler",
    # Local dev-server runtime state. Observed in production writing to
    # `.sites-runtime/wrangler/dev-registry/*` every few seconds for as long
    # as a dev server stayed up, which both inflated that project's observed
    # hours and repeatedly stole "active project" from whatever was really
    # being worked on.
    ".sites-runtime",
    "DerivedData", "*.xcuserstate", "xcuserdata", ".swiftpm/configuration",
    ".firebase", "out", "*.tsbuildinfo",
    # Caches / local IDE + tool state
    ".cache", ".idea", ".vscode", ".DS_Store", ".Trash",
    # Editor / atomic-save transient files (also handled by the coalescer,
    # listed here too so they never even reach persistence if the rename
    # heuristic misses them)
    "*.swp", "*.swo", "*.swx", "*~", ".#*", "#*#", "*.tmp", "*.temp",
    "*.crdownload", "*.part", "*.crswap", ".~lock.*#", "~$*",
    # Logs (generic log churn is noisy; explicit Logs/ workspace area
    # still gets classified, just not treated as "meaningful" by default)
    "*.log",
]

# Never watched meaningfully, regardless of user config: this is where the
# watcher keeps its own database/log/outbox. Without this the watcher would
# observe its own writes and feed itself an infinite stream of "activity".
SELF_EXCLUDE_DEFAULT = "Logs/workspace-watcher"
DEFAULT_CONFIG_PATH = Path(__file__).resolve().parents[1] / "config.toml"


@dataclass
class AreaConfig:
    name: str            # display name, e.g. "Projects"
    path: str            # workspace-root-relative path, e.g. "Projects"
    kind: str            # e.g. "projects", "inbox", "ideas", "generic"
    recursive: bool = True
    ignore: list[str] = field(default_factory=list)  # extra, area-specific ignores


@dataclass
class RouteConfig:
    area_kind: str                 # "*" matches every area
    handlers: list[str] = field(default_factory=list)


@dataclass
class RunCommandConfig:
    enabled: bool = False
    command: list[str] = field(default_factory=list)


@dataclass
class WatcherSettings:
    debounce_seconds: float = 1.5
    burst_window_seconds: float = 5.0
    burst_threshold: int = 20
    idle_session_gap_minutes: float = 30.0
    active_project_recency_minutes: float = 20.0
    active_project_min_events: int = 3
    active_project_window_minutes: float = 120.0
    startup_reconcile: bool = True
    log_level: str = "INFO"
    log_summary_interval_seconds: float = 300.0


@dataclass
class DataConfig:
    dir: str = "Logs/workspace-watcher"
    db_file: str = "events.db"
    log_file: str = "watcher.log"
    outbox_file: str = "outbox.jsonl"


@dataclass
class IntelligenceSettings:
    """Master switch for downstream activity intelligence.

    Turning this off intentionally leaves the watcher, the normalized event
    stream, project registry, and active-project inference unchanged.
    """

    enabled: bool = True
    telemetry_enabled: bool = True


@dataclass
class SessionSettings:
    enabled: bool = True
    inactivity_timeout_minutes: float = 20.0
    merge_nearby_minutes: float = 45.0
    minimum_events: int = 3
    minimum_active_seconds: float = 120.0
    event_active_seconds: float = 60.0
    event_span_seconds: float = 90.0
    burst_gap_minutes: float = 5.0
    minimum_confidence: float = 0.55
    git_metadata_enabled: bool = True


@dataclass
class NotionSettings:
    """Settings for the optional cache backed by the existing Projects DB."""

    enabled: bool = False
    refresh_minutes: float = 30.0
    refresh_on_start: bool = False
    # A local dotenv-style file used only for this optional integration.
    # Relative paths are resolved from the Watcher project directory, not the
    # monitored workspace.  The operating-system environment takes precedence.
    env_file: str = ".env"
    token_env: str = "NOTION_API_KEY"
    projects_database_id: str = "304aec94-4d3c-80a8-82f6-fd7ff4d2b607"
    work_log_database_id: str = "304aec94-4d3c-803f-9e54-ffda217f9426"
    timeout_seconds: float = 30.0


@dataclass
class FragmentationSettings:
    enabled: bool = True
    window_minutes: float = 30.0
    short_stint_minutes: float = 5.0
    snapshot_interval_minutes: float = 5.0


@dataclass
class PrioritySettings:
    enabled: bool = True
    analysis_window_hours: float = 24.0
    top_project_count: int = 3
    low_priority_ratio: float = 0.5
    dominant_activity_ratio: float = 0.65
    snapshot_interval_minutes: float = 15.0


@dataclass
class WorkLogSettings:
    enabled: bool = True
    minimum_session_confidence: float = 0.55
    merge_by_project_day: bool = True
    notion_sync: bool = False
    llm_summary: bool = False
    llm_endpoint: str = "http://localhost:1234/v1"
    llm_model: str = ""
    llm_timeout_seconds: float = 20.0


@dataclass
class RelevanceSettings:
    """Optional downstream ranking; no setting changes filesystem sensing."""

    enabled: bool = False
    minimum_score: float = 0.18
    cooldown_hours: float = 72.0
    max_results: int = 5
    source_limit: int = 500


@dataclass
class StatusSettings:
    """Explainable folder-state policy, independent of Finder presentation."""

    enabled: bool = True
    active_minutes: float = 20.0
    recent_days: float = 1.0
    stale_days: float = 45.0
    error_failure_threshold: int = 3
    apply_finder_tags: bool = True
    # Earlier entries win when a folder has more than one applicable state.
    precedence: list[str] = field(default_factory=lambda: [
        "error", "attention", "blocked", "unknown", "active", "recent",
        "stale", "completed", "reference", "normal",
    ])
    # Top-level folder meaning is separate from project lifecycle. Projects
    # and TEMP have dynamic rollups; these are stable semantic defaults.
    root_semantics: dict[str, str] = field(default_factory=lambda: {
        "Articles": "reference", "Assets": "normal", "Backups": "normal",
        "Closed": "completed", "Ideas": "reference", "Inspiration": "reference",
        "Logs": "normal", "Utilities": "normal",
    })


@dataclass
class NudgeRuleSettings:
    enabled: bool = True
    cooldown_minutes: float = 180.0


@dataclass
class IntentFolderLMStudioSettings:
    classify: bool = False
    summarize: bool = False


@dataclass
class IntentFolderNotifications:
    contextual_matches: bool = False
    due: bool = False


@dataclass
class IntentFolderConfig:
    """One configured semantic ("intent") folder, e.g. "For Inspiration".

    Matched purely by directory *name* (case-insensitive, plus ``aliases``)
    at any depth under the configured ``[intent]`` scope -- see
    ``workspace_watcher/intent.py``. This is deliberately independent of
    ``[[areas]]``: an intent folder can live at the Workspace root, nested
    inside Ideas/Resources/Inspiration, or inside an individual project.
    """

    name: str
    aliases: list[str] = field(default_factory=list)
    category: str = "actionable"  # "actionable" | "contextual" | "state"
    semantic_type: str = ""       # free-form grouping, e.g. "inspiration"; defaults to a slug of name
    tags: bool = True
    indexing: bool = True
    lm_studio: IntentFolderLMStudioSettings = field(default_factory=IntentFolderLMStudioSettings)
    notifications: IntentFolderNotifications = field(default_factory=IntentFolderNotifications)
    actions: list[str] = field(default_factory=lambda: ["open"])
    auto_move: bool = False           # whether the watcher may ever move items on its own -- default never
    requires_confirmation: bool = True
    default_snooze: str = ""          # duration string, e.g. "30d"; empty = none
    notion_sync: bool = False
    archive_destination: str = ""     # workspace-root-relative path; empty = none configured
    priority: str = "normal"          # "low" | "normal" | "high"
    inactivity_threshold: str = ""    # duration string, e.g. "90d"; empty = none


@dataclass
class IntentSettings:
    enabled: bool = True
    # Empty = anywhere under workspace.root (bounded by max_depth). Otherwise,
    # a list of workspace-root-relative prefixes to restrict matching to.
    roots: list[str] = field(default_factory=list)
    max_depth: int = 8
    # LM Studio tag/summary inference for items shares the same local server
    # as [work_logs] (one endpoint, one loaded model) -- see docs/lm-studio.md.
    # This just bounds how many items get one inference call per tick, so a
    # large backlog is processed incrementally instead of as one CPU spike.
    lm_batch_size: int = 3


@dataclass
class NudgeSettings:
    # Disabled by default: detection and its audit trail remain active, but
    # the watcher never interrupts someone just because it was installed.
    enabled: bool = False
    dry_run: bool = False
    log_only: bool = False
    delivery: str = "macos"
    daily_limit: int = 4
    global_cooldown_minutes: float = 120.0
    per_project_cooldown_minutes: float = 240.0
    quiet_hours_start: str = "22:00"
    quiet_hours_end: str = "08:00"
    minimum_confidence: float = 0.75
    context_switch_project_threshold: int = 5
    context_switch_threshold: int = 5
    priority_drift_minimum_events: int = 8
    low_sustained_project_threshold: int = 3
    context_switching: NudgeRuleSettings = field(
        default_factory=lambda: NudgeRuleSettings(enabled=True, cooldown_minutes=180.0)
    )
    priority_drift: NudgeRuleSettings = field(
        default_factory=lambda: NudgeRuleSettings(enabled=True, cooldown_minutes=240.0)
    )
    low_sustained_activity: NudgeRuleSettings = field(
        default_factory=lambda: NudgeRuleSettings(enabled=True, cooldown_minutes=240.0)
    )
    return_to_priority: NudgeRuleSettings = field(
        default_factory=lambda: NudgeRuleSettings(enabled=True, cooldown_minutes=360.0)
    )
    session_continuation: NudgeRuleSettings = field(
        default_factory=lambda: NudgeRuleSettings(enabled=False, cooldown_minutes=240.0)
    )


@dataclass
class Config:
    workspace_root: Path
    areas: list[AreaConfig]
    routes: list[RouteConfig]
    ignore_patterns: list[str]
    watcher: WatcherSettings
    data: DataConfig
    run_command: RunCommandConfig
    intelligence: IntelligenceSettings = field(default_factory=IntelligenceSettings)
    sessions: SessionSettings = field(default_factory=SessionSettings)
    notion: NotionSettings = field(default_factory=NotionSettings)
    fragmentation: FragmentationSettings = field(default_factory=FragmentationSettings)
    priorities: PrioritySettings = field(default_factory=PrioritySettings)
    work_logs: WorkLogSettings = field(default_factory=WorkLogSettings)
    relevance: RelevanceSettings = field(default_factory=RelevanceSettings)
    status: StatusSettings = field(default_factory=StatusSettings)
    nudges: NudgeSettings = field(default_factory=NudgeSettings)
    intent: IntentSettings = field(default_factory=IntentSettings)
    intent_folders: list[IntentFolderConfig] = field(default_factory=list)

    @property
    def data_dir(self) -> Path:
        return self.workspace_root / self.data.dir

    @property
    def db_path(self) -> Path:
        return self.data_dir / self.data.db_file

    @property
    def log_path(self) -> Path:
        return self.data_dir / self.data.log_file

    @property
    def outbox_path(self) -> Path:
        return self.data_dir / self.data.outbox_file

    def area_for_top_segment(self, top_segment: str) -> Optional[AreaConfig]:
        for area in self.areas:
            if area.path.strip("/").lower() == top_segment.lower():
                return area
        return None

    def validate(self) -> None:
        """Raise a small, actionable error for invalid intelligence settings."""

        booleans = {
            "intelligence.enabled": self.intelligence.enabled,
            "intelligence.telemetry_enabled": self.intelligence.telemetry_enabled,
            "sessions.enabled": self.sessions.enabled,
            "sessions.git_metadata_enabled": self.sessions.git_metadata_enabled,
            "notion.enabled": self.notion.enabled,
            "notion.refresh_on_start": self.notion.refresh_on_start,
            "fragmentation.enabled": self.fragmentation.enabled,
            "priorities.enabled": self.priorities.enabled,
            "work_logs.enabled": self.work_logs.enabled,
            "work_logs.merge_by_project_day": self.work_logs.merge_by_project_day,
            "work_logs.notion_sync": self.work_logs.notion_sync,
            "work_logs.llm_summary": self.work_logs.llm_summary,
            "relevance.enabled": self.relevance.enabled,
            "status.enabled": self.status.enabled,
            "status.apply_finder_tags": self.status.apply_finder_tags,
            "nudges.enabled": self.nudges.enabled,
            "nudges.dry_run": self.nudges.dry_run,
            "nudges.log_only": self.nudges.log_only,
        }
        booleans.update({
            f"nudges.{name}.enabled": getattr(self.nudges, name).enabled
            for name in ("context_switching", "priority_drift", "low_sustained_activity", "return_to_priority", "session_continuation")
        })
        invalid_flags = [name for name, value in booleans.items() if not isinstance(value, bool)]
        if invalid_flags:
            raise ValueError("Configuration values must be true or false: " + ", ".join(invalid_flags))
        positive = {
            "sessions.inactivity_timeout_minutes": self.sessions.inactivity_timeout_minutes,
            "sessions.merge_nearby_minutes": self.sessions.merge_nearby_minutes,
            "sessions.minimum_events": self.sessions.minimum_events,
            "sessions.minimum_active_seconds": self.sessions.minimum_active_seconds,
            "sessions.event_active_seconds": self.sessions.event_active_seconds,
            "sessions.event_span_seconds": self.sessions.event_span_seconds,
            "fragmentation.window_minutes": self.fragmentation.window_minutes,
            "fragmentation.short_stint_minutes": self.fragmentation.short_stint_minutes,
            "fragmentation.snapshot_interval_minutes": self.fragmentation.snapshot_interval_minutes,
            "notion.refresh_minutes": self.notion.refresh_minutes,
            "notion.timeout_seconds": self.notion.timeout_seconds,
            "priorities.analysis_window_hours": self.priorities.analysis_window_hours,
            "priorities.top_project_count": self.priorities.top_project_count,
            "priorities.snapshot_interval_minutes": self.priorities.snapshot_interval_minutes,
            "nudges.daily_limit": self.nudges.daily_limit,
            "nudges.context_switch_project_threshold": self.nudges.context_switch_project_threshold,
            "nudges.context_switch_threshold": self.nudges.context_switch_threshold,
            "nudges.priority_drift_minimum_events": self.nudges.priority_drift_minimum_events,
            "nudges.low_sustained_project_threshold": self.nudges.low_sustained_project_threshold,
            "work_logs.llm_timeout_seconds": self.work_logs.llm_timeout_seconds,
            "relevance.cooldown_hours": self.relevance.cooldown_hours,
            "relevance.max_results": self.relevance.max_results,
            "relevance.source_limit": self.relevance.source_limit,
            "status.active_minutes": self.status.active_minutes,
            "status.recent_days": self.status.recent_days,
            "status.stale_days": self.status.stale_days,
            "status.error_failure_threshold": self.status.error_failure_threshold,
        }
        invalid = [
            name for name, value in positive.items()
            if isinstance(value, bool) or not isinstance(value, (int, float)) or value <= 0
        ]
        if invalid:
            raise ValueError("Configuration values must be numeric and greater than zero: " + ", ".join(invalid))
        nonnegative = {
            "nudges.global_cooldown_minutes": self.nudges.global_cooldown_minutes,
            "nudges.per_project_cooldown_minutes": self.nudges.per_project_cooldown_minutes,
            **{
                f"nudges.{name}.cooldown_minutes": getattr(self.nudges, name).cooldown_minutes
                for name in ("context_switching", "priority_drift", "low_sustained_activity", "return_to_priority", "session_continuation")
            },
        }
        invalid_nonnegative = [
            name for name, value in nonnegative.items()
            if isinstance(value, bool) or not isinstance(value, (int, float)) or value < 0
        ]
        if invalid_nonnegative:
            raise ValueError("Configuration values must be numeric and zero or greater: " + ", ".join(invalid_nonnegative))
        if isinstance(self.sessions.minimum_confidence, bool) or not isinstance(self.sessions.minimum_confidence, (int, float)) or not 0 <= self.sessions.minimum_confidence <= 1:
            raise ValueError("sessions.minimum_confidence must be between 0 and 1")
        if isinstance(self.nudges.minimum_confidence, bool) or not isinstance(self.nudges.minimum_confidence, (int, float)) or not 0 <= self.nudges.minimum_confidence <= 1:
            raise ValueError("nudges.minimum_confidence must be between 0 and 1")
        if isinstance(self.relevance.minimum_score, bool) or not isinstance(self.relevance.minimum_score, (int, float)) or not 0 <= self.relevance.minimum_score <= 1:
            raise ValueError("relevance.minimum_score must be between 0 and 1")
        if isinstance(self.priorities.low_priority_ratio, bool) or not isinstance(self.priorities.low_priority_ratio, (int, float)) or not 0 < self.priorities.low_priority_ratio <= 1:
            raise ValueError("priorities.low_priority_ratio must be between 0 (exclusive) and 1")
        if isinstance(self.priorities.dominant_activity_ratio, bool) or not isinstance(self.priorities.dominant_activity_ratio, (int, float)) or not 0 < self.priorities.dominant_activity_ratio <= 1:
            raise ValueError("priorities.dominant_activity_ratio must be between 0 (exclusive) and 1")
        if self.nudges.delivery not in {"macos", "none"}:
            raise ValueError("nudges.delivery must be 'macos' or 'none'")
        known_statuses = {"error", "attention", "blocked", "unknown", "active", "recent", "stale", "completed", "reference", "normal"}
        if not isinstance(self.status.precedence, list) or set(self.status.precedence) != known_statuses:
            raise ValueError("status.precedence must contain each supported status exactly once")
        if not isinstance(self.status.root_semantics, dict) or any(value not in known_statuses for value in self.status.root_semantics.values()):
            raise ValueError("status.root_semantics values must be supported statuses")
        if not isinstance(self.notion.token_env, str) or not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", self.notion.token_env):
            raise ValueError("notion.token_env must be an environment-variable name, such as NOTION_API_KEY")
        if not isinstance(self.notion.env_file, str) or not self.notion.env_file.strip():
            raise ValueError("notion.env_file must be a non-empty path")
        for name, value in {
            "nudges.quiet_hours_start": self.nudges.quiet_hours_start,
            "nudges.quiet_hours_end": self.nudges.quiet_hours_end,
        }.items():
            try:
                hour, minute = (int(part) for part in value.split(":", 1))
            except (ValueError, AttributeError):
                raise ValueError(f"{name} must use 24-hour HH:MM format") from None
            if not 0 <= hour <= 23 or not 0 <= minute <= 59:
                raise ValueError(f"{name} must use 24-hour HH:MM format")
        if isinstance(self.intent.enabled, bool) is False:
            raise ValueError("intent.enabled must be true or false")
        if isinstance(self.intent.max_depth, bool) or not isinstance(self.intent.max_depth, int) or self.intent.max_depth <= 0:
            raise ValueError("intent.max_depth must be a positive integer")
        if isinstance(self.intent.lm_batch_size, bool) or not isinstance(self.intent.lm_batch_size, int) or self.intent.lm_batch_size <= 0:
            raise ValueError("intent.lm_batch_size must be a positive integer")
        names_seen: set[str] = set()
        for folder in self.intent_folders:
            key = folder.name.strip().casefold()
            if not key:
                raise ValueError("Every [[intent_folders]] entry needs a non-empty name")
            if key in names_seen:
                raise ValueError(f"Duplicate [[intent_folders]] name: {folder.name}")
            names_seen.add(key)
            if folder.category not in {"actionable", "contextual", "state"}:
                raise ValueError(f"intent_folders[{folder.name}].category must be actionable, contextual, or state")
            if folder.priority not in {"low", "normal", "high"}:
                raise ValueError(f"intent_folders[{folder.name}].priority must be low, normal, or high")
            for field_name, value in (("default_snooze", folder.default_snooze), ("inactivity_threshold", folder.inactivity_threshold)):
                if value and parse_duration_seconds(value) is None:
                    raise ValueError(f"intent_folders[{folder.name}].{field_name} must look like '30d', '12h', or '2w'")


def _default_areas() -> list[AreaConfig]:
    # Reflects the Workspace layout as it exists today. New top-level
    # directories that aren't listed here are still watched and reported
    # (area_kind="generic") -- nothing here is required for the watcher to
    # notice a new area, it just won't get specialized treatment yet.
    defs = [
        ("Projects", "Projects", "projects"),
        ("Unsorted", "Unsorted", "inbox"),
        ("Ideas", "Ideas", "ideas"),
        ("Resources", "Resources", "resources"),
        ("Experiments", "Experiments", "experiments"),
        ("Collections", "Collections", "collections"),
        ("Inspiration", "Inspiration", "inspiration"),
        ("Closed", "Closed", "closed"),
        ("Automations", "Automations", "automations"),
        ("Utilities", "Utilities", "utilities"),
        ("Backups", "Backups", "backups"),
        ("TEMP", "TEMP", "scratch"),
        ("Logs", "Logs", "logs"),
    ]
    return [AreaConfig(name=n, path=p, kind=k) for n, p, k in defs]


def _actionable_folder(name: str, semantic_type: str, **overrides: Any) -> IntentFolderConfig:
    base = dict(
        name=name, category="actionable", semantic_type=semantic_type, tags=True, indexing=True,
        actions=["open", "done", "defer", "archive", "cancel"],
        notifications=IntentFolderNotifications(due=True),
        requires_confirmation=True, default_snooze="7d",
    )
    base.update(overrides)
    return IntentFolderConfig(**base)


def _contextual_folder(name: str, semantic_type: str, **overrides: Any) -> IntentFolderConfig:
    base = dict(
        name=name, category="contextual", semantic_type=semantic_type, tags=True, indexing=True,
        lm_studio=IntentFolderLMStudioSettings(classify=True, summarize=False),
        notifications=IntentFolderNotifications(contextual_matches=True),
        actions=["open", "use", "not_related", "defer", "archive"],
        requires_confirmation=True, default_snooze="30d",
    )
    base.update(overrides)
    return IntentFolderConfig(**base)


def _default_intent_folders() -> list[IntentFolderConfig]:
    """The catalog described in docs/intent-folders.md.

    Every entry can be overridden or removed by supplying [[intent_folders]]
    in config.toml -- see ``load_config``, which replaces this whole list
    when the key is present rather than merging entry-by-entry.
    """
    return [
        # -- Actionable -------------------------------------------------
        _actionable_folder("To Review", "review"),
        _actionable_folder("To Test", "test"),
        _actionable_folder("To Fix", "fix", priority="high"),
        _actionable_folder("To Finish", "finish"),
        _actionable_folder(
            "To Archive", "archive_candidate", tags=False,
            actions=["open", "archive", "defer", "cancel"],
            inactivity_threshold="90d", archive_destination="Closed",
        ),
        _actionable_folder("To Organize", "organize", tags=False),
        _actionable_folder("To Document", "document"),
        _actionable_folder("To Publish", "publish"),
        _actionable_folder("To Merge", "merge"),
        _actionable_folder("To Migrate", "migrate"),
        _actionable_folder("To Explore", "explore", default_snooze="14d"),
        _actionable_folder("To Decide", "decide", priority="high"),
        _actionable_folder("To Revisit", "revisit", default_snooze="30d", inactivity_threshold="60d"),
        _actionable_folder("To Compare", "compare"),
        _actionable_folder("To Extract", "extract"),
        # -- Contextual / reference ---------------------------------------
        _contextual_folder("For Reference", "reference"),
        _contextual_folder("For Inspiration", "inspiration", lm_studio=IntentFolderLMStudioSettings(classify=True, summarize=True)),
        _contextual_folder("For Learning", "learning"),
        _contextual_folder("For Research", "research", lm_studio=IntentFolderLMStudioSettings(classify=True, summarize=True)),
        _contextual_folder("For Examples", "examples"),
        _contextual_folder("For Testing", "testing_reference"),
        _contextual_folder("For Templates", "templates"),
        _contextual_folder("For Later", "later", notifications=IntentFolderNotifications(contextual_matches=True, due=False)),
        _contextual_folder("For Article", "article"),
        _contextual_folder("For Portfolio", "portfolio"),
        # -- State-like -----------------------------------------------------
        IntentFolderConfig(
            name="Waiting For", category="state", semantic_type="waiting", tags=True, indexing=True,
            notifications=IntentFolderNotifications(due=True), actions=["open", "resolve", "defer"],
            requires_confirmation=False, inactivity_threshold="14d",
        ),
        IntentFolderConfig(
            name="On Hold", category="state", semantic_type="on_hold", tags=True, indexing=True,
            notifications=IntentFolderNotifications(due=False), actions=["open", "resume", "archive"],
            requires_confirmation=True, inactivity_threshold="60d",
        ),
        IntentFolderConfig(
            name="In Progress", category="state", semantic_type="in_progress", tags=True, indexing=True,
            notifications=IntentFolderNotifications(due=False), actions=["open", "done", "defer"],
            requires_confirmation=False,
        ),
        IntentFolderConfig(
            name="Done", category="state", semantic_type="done", tags=False, indexing=True,
            notifications=IntentFolderNotifications(due=False), actions=["open", "archive"],
            requires_confirmation=True,
        ),
    ]


def _default_routes() -> list[RouteConfig]:
    return [
        RouteConfig(area_kind="*", handlers=["log_event", "persist_event"]),
        RouteConfig(area_kind="projects", handlers=["emit_event"]),
        RouteConfig(area_kind="inbox", handlers=["emit_event"]),
        RouteConfig(area_kind="scratch", handlers=["noop"]),
        RouteConfig(area_kind="backups", handlers=["noop"]),
    ]


def default_config(workspace_root: Path) -> Config:
    return Config(
        workspace_root=workspace_root,
        areas=_default_areas(),
        routes=_default_routes(),
        ignore_patterns=list(DEFAULT_IGNORE_PATTERNS),
        watcher=WatcherSettings(),
        data=DataConfig(),
        run_command=RunCommandConfig(),
        intent_folders=_default_intent_folders(),
    )


# A key a configuration written before 2026-09-30 can still contain, accepted and
# ignored so such a file keeps loading: `client_source` pointed at the Task
# Management checkout the Notion client used to be loaded from (now `notion_api`).
# The retired `[external_task_sync]` table needs nothing here: unknown tables are
# not read.
RETIRED_KEYS = {"notion": {"client_source"}}


def _without_retired(section_name: str, values: Any) -> Any:
    if not isinstance(values, dict):
        return values
    retired = RETIRED_KEYS.get(section_name, set())
    return {key: value for key, value in values.items() if key not in retired}


def _apply_settings(section_name: str, target: Any, values: Any) -> None:
    """Apply known TOML keys and reject typos instead of silently ignoring them."""

    if not values:
        return
    if not isinstance(values, dict):
        raise ValueError(f"[{section_name}] must be a TOML table")
    unknown = sorted(str(key) for key in values if not hasattr(target, key))
    if unknown:
        raise ValueError(f"Unknown configuration key(s) in [{section_name}]: {', '.join(unknown)}")
    for key, value in values.items():
        setattr(target, key, value)


def _load_nudge_rule(section_name: str, current: NudgeRuleSettings, raw: Any) -> NudgeRuleSettings:
    if not raw:
        return current
    if not isinstance(raw, dict):
        raise ValueError(f"[{section_name}] must be a TOML table")
    unknown = sorted(str(key) for key in raw if key not in {"enabled", "cooldown_minutes"})
    if unknown:
        raise ValueError(f"Unknown configuration key(s) in [{section_name}]: {', '.join(unknown)}")
    return NudgeRuleSettings(
        enabled=raw.get("enabled", current.enabled),
        cooldown_minutes=raw.get("cooldown_minutes", current.cooldown_minutes),
    )


def _load_intent_folder(raw: Any) -> IntentFolderConfig:
    if not isinstance(raw, dict) or "name" not in raw:
        raise ValueError("Every [[intent_folders]] entry needs at least a 'name'")
    known = {
        "name", "aliases", "category", "semantic_type", "tags", "indexing", "lm_studio",
        "notifications", "actions", "auto_move", "requires_confirmation", "default_snooze",
        "notion_sync", "archive_destination", "priority", "inactivity_threshold",
    }
    unknown = sorted(str(key) for key in raw if key not in known)
    if unknown:
        raise ValueError(f"Unknown key(s) in [[intent_folders]] '{raw.get('name')}': {', '.join(unknown)}")
    lm_raw = raw.get("lm_studio", {}) or {}
    if not isinstance(lm_raw, dict) or (set(lm_raw) - {"classify", "summarize"}):
        raise ValueError(f"intent_folders[{raw.get('name')}].lm_studio must only set classify/summarize")
    notif_raw = raw.get("notifications", {}) or {}
    if not isinstance(notif_raw, dict) or (set(notif_raw) - {"contextual_matches", "due"}):
        raise ValueError(f"intent_folders[{raw.get('name')}].notifications must only set contextual_matches/due")
    return IntentFolderConfig(
        name=str(raw["name"]),
        aliases=[str(a) for a in raw.get("aliases", [])],
        category=raw.get("category", "actionable"),
        semantic_type=str(raw.get("semantic_type", "")),
        tags=bool(raw.get("tags", True)),
        indexing=bool(raw.get("indexing", True)),
        lm_studio=IntentFolderLMStudioSettings(
            classify=bool(lm_raw.get("classify", False)), summarize=bool(lm_raw.get("summarize", False)),
        ),
        notifications=IntentFolderNotifications(
            contextual_matches=bool(notif_raw.get("contextual_matches", False)), due=bool(notif_raw.get("due", False)),
        ),
        actions=[str(a) for a in raw.get("actions", ["open"])],
        auto_move=bool(raw.get("auto_move", False)),
        requires_confirmation=bool(raw.get("requires_confirmation", True)),
        default_snooze=str(raw.get("default_snooze", "")),
        notion_sync=bool(raw.get("notion_sync", False)),
        archive_destination=str(raw.get("archive_destination", "")),
        priority=raw.get("priority", "normal"),
        inactivity_threshold=str(raw.get("inactivity_threshold", "")),
    )


def load_config(path: Optional[Path], workspace_root_override: Optional[Path] = None) -> Config:
    """Load config.toml if present, layered on top of the built-in defaults.

    Any key omitted from the file falls back to the default. This keeps the
    shipped config.toml small and lets a user override just what they care
    about.
    """
    selected_path = path or DEFAULT_CONFIG_PATH
    raw: dict[str, Any] = {}
    if selected_path.exists():
        with selected_path.open("rb") as fh:
            raw = tomllib.load(fh)

    workspace_section = raw.get("workspace", {})
    root = workspace_root_override or Path(
        workspace_section.get("root", str(Path(__file__).resolve().parents[3]))
    ).expanduser()

    cfg = default_config(root)

    if "areas" in raw:
        cfg.areas = [
            AreaConfig(
                name=a["name"],
                path=a["path"],
                kind=a.get("kind", "generic"),
                recursive=a.get("recursive", True),
                ignore=list(a.get("ignore", [])),
            )
            for a in raw["areas"]
        ]

    if "routes" in raw:
        cfg.routes = [
            RouteConfig(area_kind=r["area_kind"], handlers=list(r.get("handlers", [])))
            for r in raw["routes"]
        ]

    _apply_settings("intent", cfg.intent, raw.get("intent", {}))

    if "intent_folders" in raw:
        cfg.intent_folders = [_load_intent_folder(entry) for entry in raw["intent_folders"]]

    ignore_section = raw.get("ignore", {})
    if "patterns" in ignore_section:
        cfg.ignore_patterns = list(ignore_section["patterns"])
    if ignore_section.get("extend"):
        cfg.ignore_patterns = list(cfg.ignore_patterns) + list(ignore_section["extend"])

    watcher_section = raw.get("watcher", {})
    _apply_settings("watcher", cfg.watcher, watcher_section)

    data_section = raw.get("data", {})
    _apply_settings("data", cfg.data, data_section)

    run_command_section = raw.get("handlers", {}).get("run_command", {})
    if run_command_section:
        cfg.run_command = RunCommandConfig(
            enabled=run_command_section.get("enabled", False),
            command=list(run_command_section.get("command", [])),
        )

    _apply_settings("intelligence", cfg.intelligence, raw.get("intelligence", {}))
    _apply_settings("sessions", cfg.sessions, raw.get("sessions", {}))
    _apply_settings("notion", cfg.notion, _without_retired("notion", raw.get("notion", {})))
    _apply_settings("fragmentation", cfg.fragmentation, raw.get("fragmentation", {}))
    _apply_settings("priorities", cfg.priorities, raw.get("priorities", {}))
    _apply_settings("work_logs", cfg.work_logs, raw.get("work_logs", {}))
    _apply_settings("relevance", cfg.relevance, raw.get("relevance", {}))
    _apply_settings("status", cfg.status, raw.get("status", {}))

    nudges_section = raw.get("nudges", {})
    if nudges_section and not isinstance(nudges_section, dict):
        raise ValueError("[nudges] must be a TOML table")
    nudge_rules = {
        "context_switching", "priority_drift", "low_sustained_activity",
        "return_to_priority", "session_continuation",
    }
    _apply_settings(
        "nudges", cfg.nudges,
        {key: value for key, value in (nudges_section or {}).items() if key not in nudge_rules},
    )
    for rule_name in nudge_rules:
        setattr(
            cfg.nudges,
            rule_name,
            _load_nudge_rule(
                f"nudges.{rule_name}",
                getattr(cfg.nudges, rule_name),
                (nudges_section or {}).get(rule_name),
            ),
        )

    cfg.validate()

    return cfg
