# Background service

The headless half of Better Workspace: filesystem observation, work sessions, the work
log, idea metadata and resurfacing, notification delivery. See
`../docs/BACKGROUND_SERVICE.md` for what it owns and how the app talks to it.

Idea planning now stores priority, shared project ratings and a potential destination
in private item records. `/v1/ideas/register` registers an immediate Ideas file/folder
without adding sidecars; planning updates check original values. `/v1/ideas/{id}/relocate`
acknowledges a confirmed same-volume move made by the Mac, retaining private decisions
and remote links. It does not move files or archive Notion pages. Background indexing
commits current private decisions and the read model together to preserve API edits.
Update the bundled service through the updated Mac's Settings before using these APIs.
See [project and idea controls](../docs/PROJECT_CONTROL.md) for usage and targeted tests.

## Provenance

`workspace_watcher/` and `tests/` were moved here verbatim from the Workspace Watcher
repository at commit `a835dc6` (2026-09-30). That repository is now an archive; change
the service here. The package keeps its name so its database, events and API are
untouched. Edits since the move are ordinary commits in this repository; the first two
were five Notion-sync test modules now searching upward for the `Task Management`
checkout instead of assuming a fixed depth, and `startup install` refusing to install
the service from a source directory (Better Workspace installs it).

## Layout once installed

Better Workspace bundles this directory (without tests) and installs it into
`~/Library/Application Support/BetterWorkspace/BackgroundService/`:

| Path | What | Replaced on update |
|---|---|---|
| `app/workspace_watcher/`, `app/requirements.txt` | the code | yes |
| `run.sh` | the launcher launchd runs | yes |
| `venv/` | its Python environment, rebuilt when `requirements.txt` changes | when needed |
| `config.toml`, `rules.toml` | configuration, migrated once from the old checkout | never |
| `.env` | the Notion token for work-log/idea sync, migrated once, mode 0600 | never |

Data stays in `~/Workspace/Logs/workspace-watcher/`. Item metadata now lives in
`core.db`, without sidecars. See [cleanup and migration](../docs/BACKGROUND_SERVICE.md#item-metadata-without-sidecars)
for the dry-run CLI, byte-preserving archive, and folder-move limitations.

## Testing

```sh
python3 -m venv .venv && .venv/bin/pip install -r requirements.txt pytest
.venv/bin/python -m pytest -q
```

Requires Python 3.11 or later (`tomllib`). Nothing outside this directory is needed:
the Notion client the service uses (`workspace_watcher/notion_api.py`) was moved in from
the Task Management project on 2026-09-30, unchanged, and the service no longer loads
code from any other checkout.
