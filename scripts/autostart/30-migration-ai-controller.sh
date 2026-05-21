#!/usr/bin/env bash
# 30-migration-ai-controller.sh — Start Migration AI Controller daemon.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

CONTROLLER_SCRIPT="${REPO_ROOT}/scripts/migration-ai-controller/controller.sh"
PID_FILE="${REPO_ROOT}/runner-data/migration-ai-controller.pid"
LOG_FILE="${REPO_ROOT}/migration-ai-controller.log"

start() {
    if [[ -z "$FORGEJO_TOKEN" ]]; then
        log_skip "FORGEJO_TOKEN not set, skipping Migration AI Controller"
        return 0
    fi

    if [[ -z "$CODEBERG_TOKEN" ]]; then
        log_skip "CODEBERG_TOKEN not set, skipping Migration AI Controller"
        return 0
    fi

    if [[ ! -f "$CONTROLLER_SCRIPT" ]]; then
        log_warn "Migration AI Controller script not found at ${CONTROLLER_SCRIPT}"
        return 0
    fi

    if ! curl -sf "${OLLAMA_HOST:-http://host.containers.internal:11434}/api/tags" >/dev/null 2>&1; then
        log_warn "Ollama not available at ${OLLAMA_HOST:-http://host.containers.internal:11434}, skipping Migration AI Controller"
        return 0
    fi

    log "Starting Migration AI Controller..."
    run_background "$CONTROLLER_SCRIPT" "$PID_FILE" "migration-ai-controller" "$LOG_FILE"
}

stop() {
    stop_background "$PID_FILE" "migration-ai-controller"
}

start