#!/bin/bash

CODEBERG_URL="${CODEBERG_URL:-https://codeberg.org}"
CODEBERG_TOKEN="${CODEBERG_TOKEN:-}"

get_open_pulls() {
    local owner="$1"
    local repo="$2"
    
    if [ -z "$CODEBERG_TOKEN" ]; then
        log_error "CODEBERG_TOKEN not set for $owner/$repo"
        return 1
    fi
    
    curl -sf -H "Authorization: token $CODEBERG_TOKEN" \
        "$CODEBERG_URL/api/v1/repos/$owner/$repo/pulls?state=open"
}

get_pull_diff() {
    local owner="$1"
    local repo="$2"
    local pr_number="$3"
    
    curl -sf -H "Authorization: token $CODEBERG_TOKEN" \
        "$CODEBERG_URL/api/v1/repos/$owner/$repo/pulls/$pr_number.diff"
}

get_pull_info() {
    local owner="$1"
    local repo="$2"
    local pr_number="$3"
    
    curl -sf -H "Authorization: token $CODEBERG_TOKEN" \
        "$CODEBERG_URL/api/v1/repos/$owner/$repo/pulls/$pr_number"
}

post_pull_comment() {
    local owner="$1"
    local repo="$2"
    local pr_number="$3"
    local body="$4"
    
    curl -sf -X POST \
        -H "Authorization: token $CODEBERG_TOKEN" \
        -H "Content-Type: application/json" \
        "$CODEBERG_URL/api/v1/repos/$owner/$repo/issues/$pr_number/comments" \
        -d "{\"body\": \"$body\"}"
}

extract_codeberg_info() {
    local mirror_url="$1"
    
    if [[ "$mirror_url" =~ codeberg\.org ]]; then
        local path=$(echo "$mirror_url" | sed -E 's|.*codeberg\.org/||' | sed -E 's|\.git$||')
        local owner=$(echo "$path" | cut -d'/' -f1)
        local repo=$(echo "$path" | cut -d'/' -f2)
        echo "$owner $repo"
    else
        return 1
    fi
}