#!/bin/bash
# Better Workspace background service launcher.
#
# Installed by Better Workspace into
#   ~/Library/Application Support/BetterWorkspace/BackgroundService/
# beside the code (app/), its virtualenv (venv/) and its own config.toml,
# rules.toml and .env. launchd runs `run.sh run`; nothing here refers to a
# source checkout.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PYTHONPATH="$HERE/app"
export PYTHONNOUSERSITE=1
export PYTHONDONTWRITEBYTECODE=1
export PYTHONSAFEPATH=1
if [[ -x "$HERE/runtime/bin/python3" ]]; then
  exec "$HERE/runtime/bin/python3" -m workspace_watcher --config "$HERE/config.toml" "$@"
fi
# Older developer installations retain their existing virtualenv until upgraded.
exec "$HERE/venv/bin/python" -m workspace_watcher --config "$HERE/config.toml" "$@"
