#!/bin/bash

process_repo() {
    local repo_owner="$1"
    local repo_name="$2"
    
    log_info "Processing: $repo_owner/$repo_name"
    
    local mirror_info=$(get_repo_config "$repo_owner" "$repo_name")
    local mirror_url=$(echo "$mirror_info" | jq -r '.mirror_url // empty')
    
    if [ -z "$mirror_url" ]; then
        log_error "Could not get mirror URL for $repo_owner/$repo_name"
        return 1
    fi
    
    log_info "Mirror URL: $mirror_url"
    
    local codeberg_info=$(extract_codeberg_info "$mirror_url")
    if [ -z "$codeberg_info" ]; then
        log_error "Could not extract Codeberg info from $mirror_url"
        return 1
    fi
    
    CODEBERG_OWNER=$(echo "$codeberg_info" | cut -d' ' -f1)
    CODEBERG_REPO=$(echo "$codeberg_info" | cut -d' ' -f2)
    
    log_info "Codeberg repo: $CODEBERG_OWNER/$CODEBERG_REPO"
    
    local open_prs=$(get_open_pulls "$CODEBERG_OWNER" "$CODEBERG_REPO")
    local pr_count=$(echo "$open_prs" | jq 'length')
    
    log_info "Found $pr_count open PRs on Codeberg"
    
    if [ "$pr_count" = "0" ]; then
        return 0
    fi
    
    for i in $(seq 0 $((pr_count - 1))); do
        local pr=$(echo "$open_prs" | jq -r ".[$i]")
        local pr_number=$(echo "$pr" | jq -r '.number')
        local pr_title=$(echo "$pr" | jq -r '.title')
        local pr_sha=$(echo "$pr" | jq -r '.head.sha')
        
        log_info "Checking PR #$pr_number: $pr_title (SHA: $pr_sha)"
        
        if is_pr_reviewed "$CODEBERG_OWNER" "$CODEBERG_REPO" "$pr_number" "$pr_sha"; then
            log_info "PR #$pr_number already reviewed with same SHA - skipping"
            continue
        fi
        
        log_info "New commit detected - generating review for PR #$pr_number"
        
        local diff_content=$(get_pull_diff "$CODEBERG_OWNER" "$CODEBERG_REPO" "$pr_number")
        
        if [ $(echo "$diff_content" | wc -c) -lt 100 ]; then
            log_error "Failed to get diff for PR #$pr_number: $diff_content"
            continue
        fi
        
        if ! check_ollama_health; then
            log_error "Ollama is not reachable at $OLLAMA_HOST"
            continue
        fi
        
        log_info "Sending diff to Ollama..."
        local review_body=$(generate_review "$diff_content")
        
        if [ -z "$review_body" ]; then
            log_error "Failed to generate review for PR #$pr_number"
            continue
        fi
        
        local comment="## AI Code Review

$review_body

---
*Reviewed by $OLLAMA_MODEL via Migration AI Controller*"
        
        local comment_result=$(post_pull_comment "$CODEBERG_OWNER" "$CODEBERG_REPO" "$pr_number" "$comment")
        
        if echo "$comment_result" | jq -e '.id' > /dev/null 2>&1; then
            log_info "Successfully posted review to PR #$pr_number"
            
            local reviewed_at=$(date -Iseconds)
            update_repo_state "$CODEBERG_OWNER" "$CODEBERG_REPO" "$pr_number" "$pr_sha" "$reviewed_at"
        else
            log_error "Failed to post comment to PR #$pr_number: $comment_result"
        fi
    done
}