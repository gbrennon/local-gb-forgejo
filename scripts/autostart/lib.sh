#!/usr/bin/env bash
# lib.sh — Shared utilities for autostart scripts.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

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

log_skip() {
  printf '[autostart] [SKIP] %s\n' "$1"
}

log_start() {
  printf '[autostart] [START] %s\n' "$1"
}

log_done() {
  printf '[autostart] [DONE] %s\n' "$1"
}

log_warn() {
  printf '[autostart] [WARN] %s\n' "$1"
}

log_error() {
  printf '[autostart] [ERROR] %s\n' "$1"
}

# ---------------------------------------------------------------------------
# Process management
# ---------------------------------------------------------------------------
is_running() {
  local pid_file="$1"
  if [[ -f "$pid_file" ]]; then
    local pid
    pid=$(cat "$pid_file" 2>/dev/null)
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      return 0
    fi
  fi
  return 1
}

get_pid() {
  local pid_file="$1"
  if [[ -f "$pid_file" ]]; then
    cat "$pid_file"
  fi
}

# ---------------------------------------------------------------------------
# Run script in background with lock file
# ---------------------------------------------------------------------------
run_background() {
  local script="$1"
  local pid_file="$2"
  local name="$3"
  local logs="${4:-/dev/null}"

  # Check if already running
  if is_running "$pid_file"; then
    log_skip "$name already running (PID $(get_pid "$pid_file"))"
    return 0
  fi

  # Stop any stale PID file
  rm -f "$pid_file"

  # Ensure log dir exists
  if [[ "$logs" != "/dev/null" ]]; then
    mkdir -p "$(dirname "$logs")"
  fi

  # Start in background
  log_start "$name"
  nohup bash "$script" >> "$logs" 2>&1 &
  local new_pid=$!
  echo "$new_pid" > "$pid_file"

  log_done "$name started (PID $new_pid)"
  return 0
}

# ---------------------------------------------------------------------------
# Stop script by PID file
# ---------------------------------------------------------------------------
stop_background() {
  local pid_file="$1"
  local name="$2"

  if is_running "$pid_file"; then
    local pid
    pid=$(get_pid "$pid_file")
    log "Stopping $name (PID $pid)..."
    kill "$pid" 2>/dev/null || true
    sleep 1
    rm -f "$pid_file"
    log_done "$name stopped"
  else
    log_skip "$name not running"
  fi
}

# ---------------------------------------------------------------------------
# Check if command exists
# ---------------------------------------------------------------------------
require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    log_error "$1 not found"
    return 1
  }
}

# ---------------------------------------------------------------------------
# Wait for service to be ready
# ---------------------------------------------------------------------------
wait_for_service() {
  local url="$1"
  local name="$2"
  local timeout="${3:-30}"
  local interval="${4:-2}"

  log "Waiting for $name at $url..."

  local i=0
  while [[ $i -lt $timeout ]]; do
    if curl -sf "$url" >/dev/null 2>&1; then
      log_done "$name is ready"
      return 0
    fi
    sleep "$interval"
    i=$((i + interval))
  done

  log_error "$name not ready after ${timeout}s"
  return 1
}