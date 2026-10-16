# Privacy-safe local terminal metadata for Workspace Watcher.
#
# Source from ~/.zshrc after interactive-shell setup. It never records command
# text, arguments, or output: only cwd, inferred repository root, and a broad
# command category. Telemetry ingests this append-only producer stream.

typeset -g WORKSPACE_WATCHER_TERMINAL_JOURNAL="${WORKSPACE_WATCHER_TERMINAL_JOURNAL:-${WORKLOG_TERMINAL_JOURNAL:-$HOME/Library/Application Support/WorkspaceTelemetry/inbox/terminal-events.jsonl}}"

_workspace_watcher_command_category() {
  local first="${1%%[[:space:]]*}"
  case "$first" in
    git) print git ;;
    python|python3|node|npm|pnpm|yarn|bun|swift|xcodebuild|make|just) print build ;;
    rg|grep|find|sed|awk|cat|less|head|tail) print inspect ;;
    *) print shell ;;
  esac
}

_workspace_watcher_preexec() {
  [[ -o interactive ]] || return 0
  local command_category repo_root timestamp directory
  command_category="$(_workspace_watcher_command_category "$1")"
  directory="$PWD"
  repo_root="$(command git -C "$PWD" rev-parse --show-toplevel 2>/dev/null)"
  timestamp="$(command date -u +%Y-%m-%dT%H:%M:%SZ)"
  command mkdir -p "${WORKSPACE_WATCHER_TERMINAL_JOURNAL:h}" 2>/dev/null || return 0
  command printf '{"timestamp":"%s","cwd":%s,"repo_root":%s,"category":"%s"}\n' \
    "$timestamp" "$(print -rn -- "$directory" | command python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')" \
    "$(print -rn -- "$repo_root" | command python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')" "$command_category" \
    >> "$WORKSPACE_WATCHER_TERMINAL_JOURNAL" 2>/dev/null
}

autoload -Uz add-zsh-hook
add-zsh-hook preexec _workspace_watcher_preexec
