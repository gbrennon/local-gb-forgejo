#!/usr/bin/env bash
# post-review.sh — Posts review to original platform (GitHub/Codeberg).
# Usage: ./post-review.sh <owner/repo> <pr_number> <review_json>
# Or: cat review.json | ./post-review.sh <owner/repo> <pr_number> 

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Load env
source "${REPO_ROOT}/.env" 2>/dev/null || true
FORGEJO_HOST="${FORGEJO_HOST:-https://localhost:1234}"
AUTH="${FORGEJO_ADMIN_USER}:${FORGEJO_ADMIN_PASSWORD}"

# Load libs
source "${SCRIPT_DIR}/lib/platform-detect.sh"

usage() {
  echo "Usage: $(basename "$0") <owner/repo> <pr_number> [review_json]"
  echo "   or: cat review.json | $(basename "$0") <owner/repo> <pr_number>"
  echo ""
  echo "Posts AI review to original GitHub/Codeberg PR."
  exit 1
}

[[ $# -lt 2 ]] && usage

OWNER_REPO="$1"
PR_NUMBER="$2"

# Read review from arg or stdin
local review_json
if [[ -n "${3:-}" ]]; then
  review_json="$3"
else
  review_json=$(cat)
fi

echo "[$(date '+%H:%M:%S')] Posting review to PR ${OWNER_REPO}#${PR_NUMBER}..."

# Detect platform
local platform
platform=$(detect_platform "$OWNER_REPO")

local original_slug
original_slug=$(get_original_slug "$OWNER_REPO")

echo "[$(date '+%H:%M:%S')] Platform: $platform, Original: $original_slug"

if [[ "$platform" == "unknown" ]]; then
  echo "ERROR: Could not detect original platform for ${OWNER_REPO}" >&2
  exit 1
fi

# Build comment body
local comment_body
comment_body=$(python3 -c "
import sys, json

try:
    review = json.loads('${review_json}')
except:
    print('ERROR: Invalid JSON review')
    sys.exit(1)

issues = review.get('issues', [])
suggestions = review.get('suggestions', [])
summary = review.get('summary', '')

body = '## AI Code Review\n\n'

if issues:
    body += '### Issues Found\n'
    for i in issues:
        sev = i.get('severity', 'medium')
        emoji = '🔴' if sev == 'high' else ('🟡' if sev == 'medium' else '🟢')
        body += f'- {emoji} Line {i.get(\"line\",\"?\")}: {i.get(\"description\",\"\")}\n'
    body += '\n'

if suggestions:
    body += '### Suggestions\n'
    for s in suggestions:
        body += f'- Line {s.get(\"line\",\"?\")}: {s.get(\"description\",\"\")}\n'
    body += '\n'

if summary:
    body += f'### Summary\n{summary}\n'

body += '\n---\n*Review by AI via local Forgejo watcher*'

print(body)
")

# Get API token for the platform
local api_token
case "$platform" in
  github)
    api_token="${GITHUB_PAT}"
    ;;
  codeberg)
    api_token="${CODEBERG_TOKEN:-}"
    ;;
esac

if [[ -z "$api_token" ]]; then
  echo "ERROR: No API token for $platform. Set GITHUB_PAT or CODEBERG_TOKEN in .env" >&2
  exit 1
fi

# Split original_slug into owner/repo
local original_owner="${original_slug%%/*}"
local original_repo="${original_slug#*/}"

# Post comment
local api_url comment_response
case "$platform" in
  github)
    api_url="https://api.github.com/repos/${original_slug}/issues/${PR_NUMBER}/comments"
    comment_response=$(curl -sf -X POST "$api_url" \
      -H "Authorization: token $api_token" \
      -H "Accept: application/vnd.github+json" \
      -H "Content-Type: application/json" \
      -d "{\"body\": $(echo "$comment_body" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')}")
    ;;
  codeberg)
    api_url="https://codeberg.org/api/v1/repos/${original_slug}/issues/${PR_NUMBER}/comments"
    comment_response=$(curl -sf -X POST "$api_url" \
      -H "Authorization: token $api_token" \
      -H "Content-Type: application/json" \
      -d "{\"body\": $(echo "$comment_body" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')}")
    ;;
esac

if [[ $? -eq 0 ]] || [[ -n "$comment_response" ]]; then
  echo "[$(date '+%H:%M:%S')] Review posted successfully to ${platform}!"
  
  # Update state file
  local state_file="${REPO_ROOT}/runner-data/pr-reviews.json"
  mkdir -p "$(dirname "$state_file")"
  
  # Load existing state
  local state
  if [[ -f "$state_file" ]]; then
    state=$(cat "$state_file")
  else
    state='{"reviewed":{}}'
  fi
  
  # Get PR SHA for state
  local pr_sha
  pr_sha=$(curl -sf -u "${AUTH}" "${FORGEJO_HOST}/api/v1/repos/${OWNER_REPO}/pulls/${PR_NUMBER}" \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('head',{}).get('sha',''))" 2>/dev/null || true)
  
  # Update state
  echo "$state" | python3 -c "
import sys, json
state = json.load(sys.stdin)
key = '${OWNER_REPO}/${PR_NUMBER}'
if 'reviewed' not in state:
    state['reviewed'] = {}
state['reviewed'][key] = {
    'sha': '${pr_sha}',
    'reviewed_at': '$(date -u +%Y-%m-%dT%H:%SZ)'
}
print(json.dumps(state))
" > "$state_file"
  
  echo "[$(date '+%H:%M:%S')] State updated"
else
  echo "ERROR: Failed to post comment to ${platform}" >&2
  echo "Response: $comment_response" >&2
  exit 1
fi