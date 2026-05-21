#!/bin/bash

STATE_FILE="${STATE_FILE:-$SCRIPT_DIR/state.json}"
STATE='{"repos":[]}'

init_state() {
    if [ ! -f "$STATE_FILE" ]; then
        mkdir -p "$(dirname "$STATE_FILE")"
        echo '{"repos":[],"last_updated":"'"$(date -Iseconds)"'"}' > "$STATE_FILE"
    fi
}

load_state() {
    if [ -f "$STATE_FILE" ]; then
        STATE=$(cat "$STATE_FILE")
    else
        STATE='{"repos":[]}'
    fi
    export STATE
}

save_state() {
    local timestamp=$(date -Iseconds)
    echo "$STATE" | jq ".last_updated = \"$timestamp\"" > "$STATE_FILE"
}

get_repo_state() {
    local owner="$1"
    local repo="$2"
    
    echo "$STATE" | jq -r ".repos[] | select(.owner == \"$owner\" and .name == \"$repo\") // empty"
}

update_repo_state() {
    local owner="$1"
    local repo="$2"
    local pr_number="$3"
    local commit_sha="$4"
    local reviewed_at="$5"
    
    local existing=$(echo "$STATE" | jq ".repos[] | select(.owner == \"$owner\" and .name == \"$repo\") | length")
    
    if [ "$existing" = "1" ]; then
        STATE=$(echo "$STATE" | jq "
            .repos |= map(
                if .owner == \"$owner\" and .name == \"$repo\" then
                    .reviewed_prs = (.reviewed_prs // []) | map(
                        if .number == $pr_number then
                            .commit_sha = \"$commit_sha\"
                            | .reviewed_at = \"$reviewed_at\"
                        else
                            .
                        end
                    )
                else
                    .
                end
            )
        ")
    else
        local new_repo=$(jq -n \
            --arg owner "$owner" \
            --arg repo "$repo" \
            --arg pr "$pr_number" \
            --arg sha "$commit_sha" \
            --arg time "$reviewed_at" \
            '{
                owner: $owner,
                name: $repo,
                reviewed_prs: [{
                    number: ($pr | tonumber),
                    commit_sha: $sha,
                    reviewed_at: $time
                }]
            }')
        
        STATE=$(echo "$STATE" | jq ".repos += [$new_repo]")
    fi
}

is_pr_reviewed() {
    local owner="$1"
    local repo="$2"
    local pr_number="$3"
    local commit_sha="$4"
    
    local pr_state=$(get_repo_state "$owner" "$repo" | jq -r ".reviewed_prs[] | select(.number == $pr_number)")
    
    if [ -z "$pr_state" ] || [ "$pr_state" = "null" ]; then
        return 1
    fi
    
    local stored_sha=$(echo "$pr_state" | jq -r '.commit_sha')
    
    if [ "$stored_sha" = "$commit_sha" ]; then
        return 0
    else
        return 1
    fi
}