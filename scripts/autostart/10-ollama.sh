#!/usr/bin/env bash
# 10-ollama.sh — Ensure Ollama service is ready.

# shellcheck source=lib.sh
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

# Configuration
OLLAMA_MODEL="${OLLAMA_MODEL:-deepseek-coder:6.7b}"
TIMEOUT="${OLLAMA_TIMEOUT:-60}"

PID_FILE="${REPO_ROOT}/runner-data/ollama.pid"

# Resolve Ollama URL - try localhost then host.containers.internal
resolve_ollama_host() {
  if [[ -n "${OLLAMA_HOST:-}" ]]; then
    echo "$OLLAMA_HOST"
    return
  fi
  
  # Try localhost first (docker)
  if curl -sf "http://localhost:11434/api/tags" >/dev/null 2>&1; then
    echo "http://localhost:11434"
    return
  fi
  
  # Try host.containers.internal (podman)
  if curl -sf "http://host.containers.internal:11434/api/tags" >/dev/null 2>&1; then
    echo "http://host.containers.internal:11434"
    return
  fi
  
  # No Ollama found
  echo ""
}

start() {
  local ollama_url
  ollama_url=$(resolve_ollama_host)
  
  if [[ -z "$ollama_url" ]]; then
    log_warn "Ollama not available"
    log_warn "AI PR review will not work until Ollama is running"
    log_warn "Start manually: cd ~/repos/gbrennon/gb-ollama-container && docker compose up -d"
    return 0
  fi

  log_done "Ollama available at ${ollama_url}"
  
  # Export resolved URL for other scripts
  export OLLAMA_HOST="$ollama_url"
  return 0
}

stop() {
  if is_running "$PID_FILE"; then
    stop_background "$PID_FILE" "Ollama (local)"
  fi
}

# Run on autostart
start