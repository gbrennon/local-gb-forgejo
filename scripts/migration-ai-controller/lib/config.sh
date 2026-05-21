#!/bin/bash

load_config() {
    if [ -z "$FORGEJO_TOKEN" ]; then
        log_error "FORGEJO_TOKEN not set in environment"
        return 1
    fi
    
    if [ -z "$CODEBERG_TOKEN" ]; then
        log_error "CODEBERG_TOKEN not set in environment"
        return 1
    fi
    
    FORGEJO_URL="${FORGEJO_URL:-https://forgejo:3000}"
    OLLAMA_HOST="${OLLAMA_HOST:-http://host.containers.internal:11434}"
    OLLAMA_MODEL="${OLLAMA_MODEL:-deepseek-coder:6.7b}"
    POLL_INTERVAL="${POLL_INTERVAL:-600}"
    
    log_info "Config loaded: Forgejo=$FORGEJO_URL, Ollama=$OLLAMA_HOST, Model=$OLLAMA_MODEL"
}