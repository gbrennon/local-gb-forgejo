#!/bin/bash

FORGEJO_URL="${FORGEJO_URL:-https://forgejo:3000}"
FORGEJO_TOKEN="${FORGEJO_TOKEN:-}"

get_mirror_repos() {
    local page="${1:-1}"
    local limit="${2:-50}"
    
    if [ -z "$FORGEJO_TOKEN" ]; then
        log_error "FORGEJO_TOKEN not set"
        return 1
    fi
    
    curl -sf -H "Authorization: token $FORGEJO_TOKEN" \
        "$FORGEJO_URL/api/v1/repos/search?limit=$limit&page=$page" | \
        jq -r '.data[] | select(.mirror == true) | {path: .full_name, mirror_url: .mirror_url, updated: .updated_at}'
}

get_all_mirror_repos() {
    local all_repos="[]"
    local page=1
    local repos
    
    while true; do
        repos=$(get_mirror_repos "$page" 50)
        local count=$(echo "$repos" | jq 'length')
        
        if [ "$count" -eq 0 ]; then
            break
        fi
        
        all_repos=$(echo "$all_repos" | jq --argjson r "$repos" '. + $r')
        page=$((page + 1))
    done
    
    echo "$all_repos"
}

get_repo_config() {
    local repo_owner="$1"
    local repo_name="$2"
    
    curl -sf -H "Authorization: token $FORGEJO_TOKEN" \
        "$FORGEJO_URL/api/v1/repos/$repo_owner/$repo_name" | \
        jq '{mirror: .mirror, mirror_url: .mirror_url, updated: .updated_at}'
}