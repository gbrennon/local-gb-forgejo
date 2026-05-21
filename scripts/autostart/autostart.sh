#!/usr/bin/env bash
# autostart.sh — Main entry for autostart scripts.
# Runs all scripts in priority order (NN-name.sh pattern).
#
# Usage:
#   ./autostart.sh                 # run all autostart scripts
#   ./autostart.sh --status        # show status of autostart scripts
#   ./autostart.sh --stop          # stop all autostart scripts
#   ./autostart.sh --reload        # hot-reload configuration (SIGHUP)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

ACTION="${1:-run}"

# Load environment
if [[ -f "${REPO_ROOT}/.env" ]]; then
  set -a
  # shellcheck source=../.env
  source "${REPO_ROOT}/.env"
  set +a
fi

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
log() {
  printf '[autostart] %s\n' "$1"
}

log_done() {
  printf '[autostart] [DONE] %s\n' "$1"
}

log_error() {
  printf '[autostart] [ERROR] %s\n' "$1"
}

# ---------------------------------------------------------------------------
# Run all autostart scripts
# ---------------------------------------------------------------------------
run_all() {
  log "Running autostart scripts..."

  for script in "$SCRIPT_DIR"/[0-9][0-9]-*.sh; do
    [[ -f "$script" ]] || continue
    [[ "$(basename "$script")" == "lib.sh" ]] && continue
    [[ "$(basename "$script")" == "autostart.sh" ]] && continue

    log "Running $(basename "$script")"
    
    # Source the script - it should define start() function but NOT call it
    # shellcheck source=/dev/null
    if source "$script" 2>/dev/null; then
      # Call start function if it exists
      if declare -f start >/dev/null 2>&1; then
        start
      fi
      log_done "$(basename "$script")"
    else
      log_error "$(basename "$script") failed to source"
    fi
  done

  log "Autostart complete"
}

# ---------------------------------------------------------------------------
# Show status of autostart scripts
# ---------------------------------------------------------------------------
status_all() {
  log "Autostart script status:"

  for script in "$SCRIPT_DIR"/[0-9][0-9]-*.sh; do
    [[ -f "$script" ]] || continue
    [[ "$(basename "$script")" == "lib.sh" ]] && continue
    [[ "$(basename "$script")" == "autostart.sh" ]] && continue

    local name
    name=$(basename "$script" | sed 's/[0-9][0-9]-//; s/.sh$//')

    # Check by process name
    local pid_info="stopped"
    case "$name" in
      ollama)
        if curl -sf "${OLLAMA_HOST:-http://localhost:11434}/api/tags" >/dev/null 2>&1; then
          pid_info="running (service)"
        fi
        ;;
      watch-mirrors)
        if pgrep -f "watch-mirrors.sh" >/dev/null 2>&1; then
          pid_info="running"
        fi
        ;;
      watch-prs)
        if pgrep -f "watch-prs.sh" >/dev/null 2>&1; then
          pid_info="running"
        fi
        ;;
    esac

    printf '  %-30s %s\n' "$name" "$pid_info"
  done
}

# ---------------------------------------------------------------------------
# Stop all autostart scripts
# ---------------------------------------------------------------------------
stop_all() {
  log "Stopping autostart scripts..."

  for script in "$SCRIPT_DIR"/[0-9][0-9]-*.sh; do
    [[ -f "$script" ]] || continue
    [[ "$(basename "$script")" == "lib.sh" ]] && continue
    [[ "$(basename "$script")" == "autostart.sh" ]] && continue

    # Source the script and call stop function
    # shellcheck source=/dev/null
    if source "$script" 2>/dev/null; then
      if declare -f stop >/dev/null 2>&1; then
        log "Stopping $(basename "$script")"
        stop
      fi
    fi
  done

  log "Autostart stopped"
}

# ---------------------------------------------------------------------------
# Reload configuration (hot-reload)
# ---------------------------------------------------------------------------
reload_all() {
  log "Reloading configuration via SIGHUP..."
  bash "${REPO_ROOT}/scripts/reload.sh"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
case "$ACTION" in
  --status)
    status_all
    ;;
  --stop)
    stop_all
    ;;
  --reload)
    reload_all
    ;;
  *)
    run_all
    ;;
esac