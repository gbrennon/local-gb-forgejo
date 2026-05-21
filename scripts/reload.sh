#!/usr/bin/env bash
# reload.sh — Send SIGHUP to all running watchers to reload .env configuration.
#
# Usage:
#   ./scripts/reload.sh          # reload all watchers
#   ./scripts/reload.sh --status # check reload status
#
# This script sends SIGHUP to all hot-reloadable daemons, causing them to
# re-read the .env file without restarting. Variables that can be changed:
#   - OLLAMA_MODEL
#   - OLLAMA_HOST
#   - POLL_INTERVAL / INTERVAL
#   - FORGEJO_HOST
#   - GITHUB_PAT
#   - CODEBERG_TOKEN
#   - FORGEJO_TOKEN
#
# The daemons check for reload requests during their sleep cycle, so changes
# take effect on the next poll cycle (within INTERVAL seconds).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# PID files to check
PID_FILES=(
  "runner-data/watch-prs.pid"
  "watcher-prs.pid"
  "runner-data/watch-mirrors.pid"
  "watcher.pid"
  "runner-data/migration-ai-controller.pid"
)

log_info() {
  echo "[reload] $*"
}

log_error() {
  echo "[reload] ERROR: $*" >&2
}

log_skip() {
  echo "[reload] SKIP: $*"
}

# Check if a process is running
check_pid() {
  local pidfile="$1"
  local full_path="$REPO_ROOT/$pidfile"
  
  if [[ ! -f "$full_path" ]]; then
    return 1
  fi
  
  local pid
  pid=$(cat "$full_path" 2>/dev/null)
  
  if [[ -z "$pid" ]]; then
    return 1
  fi
  
  if kill -0 "$pid" 2>/dev/null; then
    return 0
  fi
  
  return 1
}

# Send SIGHUP to a process
send_sighup() {
  local pidfile="$1"
  local full_path="$REPO_ROOT/$pidfile"
  local pid
  
  pid=$(cat "$full_path" 2>/dev/null)
  
  if kill -HUP "$pid" 2>/dev/null; then
    log_info "Sent SIGHUP to $(basename "$pidfile" .pid) (PID: $pid)"
    return 0
  else
    log_error "Failed to send SIGHUP to PID $pid"
    return 1
  fi
}

# Show status of reloadable processes
show_status() {
  log_info "Hot-reloadable processes:"
  echo ""
  
  local found_any=false
  
  for pidfile in "${PID_FILES[@]}"; do
    local full_path="$REPO_ROOT/$pidfile"
    local name
    name=$(basename "$pidfile" .pid)
    
    if [[ -f "$full_path" ]]; then
      local pid
      pid=$(cat "$full_path" 2>/dev/null || echo "unknown")
      
      if kill -0 "$pid" 2>/dev/null; then
        echo "  ✓ $name: running (PID $pid)"
        found_any=true
      else
        echo "  ✗ $name: not running (stale PID file)"
      fi
    else
      echo "  - $name: not running"
    fi
  done
  
  echo ""
  if [[ "$found_any" == false ]]; then
    log_info "No reloadable processes currently running."
    log_info "Run './scripts/autostart/autostart.sh' to start them."
  fi
}

# Main
main() {
  local action="reload"
  
  for arg in "$@"; do
    case "$arg" in
      -h|--help)
        echo "Usage: $(basename "$0") [options]"
        echo ""
        echo "Options:"
        echo "  --status   Show status of reloadable processes"
        echo "  -h, --help  Show this help"
        echo ""
        echo "Send SIGHUP to all running watchers to reload .env configuration."
        exit 0
        ;;
      --status)
        action="status"
        ;;
    esac
  done
  
  case "$action" in
    status)
      show_status
      ;;
    reload)
      log_info "Reloading all watchers..."
      echo ""
      
      local reloaded=0
      local skipped=0
      
      for pidfile in "${PID_FILES[@]}"; do
        if check_pid "$pidfile"; then
          send_sighup "$pidfile" && ((reloaded++)) || ((skipped++))
        else
          log_skip "$(basename "$pidfile" .pid): not running"
          ((skipped++))
        fi
      done
      
      echo ""
      log_info "Reload complete: $reloaded signaled, $skipped skipped"
      ;;
  esac
}

main "$@"
