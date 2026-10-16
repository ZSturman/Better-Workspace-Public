"""Workspace Watcher: background filesystem awareness for the Workspace.

See README.md for architecture and usage. Downstream consumers should
import `workspace_watcher.client.WorkspaceWatcherClient` (or query the
SQLite database directly) rather than reaching into watcher internals.
"""

__version__ = "0.1.0"
