#!/usr/bin/env bash
# 20-watch-prs.sh — Start AI PR reviewer watcher.

# shellcheck source=lib.sh
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

# Configuration
WATCH_PR_SCRIPT="${SCRIPT_DIR}/../watch-prs.sh"
PID_FILE="${REPO_ROOT}/runner-data/watch-prs.pid"
LOG_FILE="${REPO_ROOT}/watch-prs.log"

start() {
  # Skip if script doesn't exist
  if [[ ! -f "$WATCH_PR_SCRIPT" ]]; then
    log_warn "watch-prs.sh not found at ${WATCH_PR_SCRIPT}"
    return 0
  fi

  # Skip if Ollama not available
  if ! curl -sf "${OLLAMA_HOST:-http://host.containers.internal:11434}/api/tags" >/dev/null 2>&1; then
    log_warn "Ollama not available, skipping PR watcher"
    return 0
  fi

  log "Starting PR watcher (all repos)..."
  run_background "$WATCH_PR_SCRIPT" "$PID_FILE" "watch-prs" "$LOG_FILE"
}

stop() {
  stop_background "$PID_FILE" "watch-prs"
}

# Run on autostart
#start