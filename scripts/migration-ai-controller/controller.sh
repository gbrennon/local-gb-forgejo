#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${CONFIG_FILE:-$SCRIPT_DIR/config.json}"
STATE_FILE="${STATE_FILE:-$SCRIPT_DIR/state.json}"
LOG_FILE="${LOG_FILE:-$SCRIPT_DIR/controller.log}"

source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/logging.sh"
source "$SCRIPT_DIR/lib/forgejo.sh"
source "$SCRIPT_DIR/lib/codeberg.sh"
source "$SCRIPT_DIR/lib/ollama.sh"
source "$SCRIPT_DIR/lib/state.sh"
source "$SCRIPT_DIR/lib/review.sh"

# Hot-reload support
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "${REPO_ROOT}/scripts/lib/hot-reload.sh"
init_hot_reload "$REPO_ROOT"

POLL_INTERVAL="${POLL_INTERVAL:-600}"

run_cycle() {
    log_info "=== Migration AI Controller Cycle Started ==="
    
    init_state
    load_config
    load_state
    
    REPOS=$(get_all_mirror_repos)
    log_info "Found $(echo "$REPOS" | jq 'length') mirror repos"
    
    for repo in $(echo "$REPOS" | jq -r '.[].path'); do
        log_info "Processing repo: $repo"
        
        REPO_OWNER=$(echo "$repo" | cut -d'/' -f1)
        REPO_NAME=$(echo "$repo" | cut -d'/' -f2)
        
        process_repo "$REPO_OWNER" "$REPO_NAME"
    done
    
    save_state
    
    log_info "=== Migration AI Controller Cycle Finished ==="
}

log_info "Migration AI Controller started (poll interval: ${POLL_INTERVAL}s)"
log_info "Hot-reload: ENABLED (send SIGHUP to reload .env)"

cycle=0
while true; do
    cycle=$((cycle + 1))
    run_cycle
    
    log_info "Sleeping for ${POLL_INTERVAL}s... (hot-reload enabled)"
    interruptible_sleep "$POLL_INTERVAL"
done