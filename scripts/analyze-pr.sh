#!/usr/bin/env bash
# analyze-pr.sh — Analyzes a PR using local Ollama.
# Usage: ./analyze-pr.sh <owner/repo> <pr_number>
# Output: JSON with issues, suggestions, summary

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Load env
source "${REPO_ROOT}/.env" 2>/dev/null || true
FORGEJO_HOST="${FORGEJO_HOST:-https://localhost:1234}"
AUTH="${FORGEJO_ADMIN_USER}:${FORGEJO_ADMIN_PASSWORD}"

# Load libs
source "${SCRIPT_DIR}/lib/ollama-client.sh"

usage() {
  echo "Usage: $(basename "$0") <owner/repo> <pr_number>"
  echo ""
  echo "Analyzes a PR diff using local Ollama."
  echo "Outputs JSON with issues, suggestions, and summary."
  exit 1
}

[[ $# -lt 2 ]] && usage

OWNER_REPO="$1"
PR_NUMBER="$2"

echo "[$(date '+%H:%M:%S')] Analyzing PR ${OWNER_REPO}#${PR_NUMBER}..."

# Get PR details to find the head SHA
local pr_info
pr_info=$(curl -sf -u "${AUTH}" "${FORGEJO_HOST}/api/v1/repos/${OWNER_REPO}/pulls/${PR_NUMBER}")

local pr_sha
pr_sha=$(echo "$pr_info" | python3 -c "import sys,json; print(json.load(sys.stdin).get('head',{}).get('sha',''))" 2>/dev/null || true)

if [[ -z "$pr_sha" ]]; then
  echo "ERROR: Could not get PR SHA" >&2
  exit 1
fi

echo "[$(date '+%H:%M:%S')] PR SHA: ${pr_sha:0:7}"

# Get diff
echo "[$(date '+%H:%M:%S')] Fetching diff..."
local diff
diff=$(curl -sf -u "${AUTH}" "${FORGEJO_HOST}/api/v1/repos/${OWNER_REPO}/pulls/${PR_NUMBER}.diff")

if [[ -z "$diff" ]] || [[ ${#diff} -lt 100 ]]; then
  echo "ERROR: Failed to get diff for PR ${OWNER_REPO}#${PR_NUMBER}" >&2
  exit 1
fi

echo "[$(date '+%H:%M:%S')] Diff size: ${#diff} chars"

# Check Ollama
if ! ollama_available; then
  echo "ERROR: Ollama not available" >&2
  exit 1
fi

# Send to Ollama
echo "[$(date '+%H:%M:%S')] Sending to Ollama (${OLLAMA_MODEL})..."

# Build prompt
local review_prompt
review_prompt='You are a code reviewer. Review the following git diff and provide constructive feedback. Focus on bugs, security issues, code quality, and potential improvements. 

Output ONLY valid JSON (no markdown, no explanation):

{
  "issues": [
    {"line": "line number or file", "severity": "high|medium|low", "description": "issue description"}
  ],
  "suggestions": [
    {"line": "line number or file", "description": "suggestion"}
  ],
  "summary": "one sentence overall assessment"
}

DIFF:
'"$diff"

local response
response=$(curl -sf -X POST "$(resolve_ollama_host)/api/generate" \
  -H "Content-Type: application/json" \
  -d "{
    \"model\": \"${OLLAMA_MODEL}\",
    \"prompt\": \"${review_prompt//\"/\\\\\"}\",
    \"stream\": false
  }" 2>&1) || {
    echo "ERROR: Ollama request failed: $response" >&2
    exit 1
  }

local review
review=$(echo "$response" | python3 -c "import sys,json; print(json.load(sys.stdin).get('response',''))" 2>/dev/null || true)

if [[ -z "$review" ]]; then
  echo "ERROR: No review from Ollama" >&2
  exit 1
fi

echo "[$(date '+%H:%M:%S')] Review generated"

# Output the review
echo "$review"