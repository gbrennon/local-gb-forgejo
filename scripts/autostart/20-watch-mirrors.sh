#!/usr/bin/env bash
# 20-watch-mirrors.sh — Start mirror sync watcher.

# shellcheck source=lib.sh
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

# Configuration
WATCH_MIRRORS_SCRIPT="${SCRIPT_DIR}/../watch-mirrors.sh"
PID_FILE="${REPO_ROOT}/runner-data/watch-mirrors.pid"
LOG_FILE="${REPO_ROOT}/watcher.log"

start() {
  # Skip if script doesn't exist
  if [[ ! -f "$WATCH_MIRRORS_SCRIPT" ]]; then
    log_warn "watch-mirrors.sh not found at ${WATCH_MIRRORS_SCRIPT}"
    return 0
  fi

  log "Starting mirror watcher..."
  run_background "$WATCH_MIRRORS_SCRIPT" "$PID_FILE" "watch-mirrors" "$LOG_FILE"
}

stop() {
  stop_background "$PID_FILE" "watch-mirrors"
}

# Run on autostart
start