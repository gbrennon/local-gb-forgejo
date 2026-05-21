#!/bin/bash

OLLAMA_HOST="${OLLAMA_HOST:-http://host.containers.internal:11434}"
OLLAMA_MODEL="${OLLAMA_MODEL:-code-review}"

generate_review() {
    local diff_content="$1"

    local prompt="You are a code reviewer. Review the following git diff and provide constructive feedback. Focus on bugs, security issues, code quality, and potential improvements. Output in markdown format with these sections:

## Issues Found
- (line/section) - issue description

## Suggestions
- (line/section) - suggestion

## Summary
One sentence overall assessment.

DIFF:
$diff_content"

    local response=$(curl -sf -X POST "$OLLAMA_HOST/api/generate" \
        -H "Content-Type: application/json" \
        -d "{
            \"model\": \"$OLLAMA_MODEL\",
            \"prompt\": \"$prompt\",
            \"stream\": false
        }")

    echo "$response" | jq -r '.response // empty'
}

check_ollama_health() {
    curl -sf "$OLLAMA_HOST/api/tags" > /dev/null 2>&1
}

get_available_models() {
    curl -sf "$OLLAMA_HOST/api/tags" | jq -r '.models[].name'
}
