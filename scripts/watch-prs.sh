#!/usr/bin/env bash
# watch-prs.sh — Daemon that watches repos for new/updated PRs and posts AI reviews.
#
# Flow:
#   1. Poll all repos for open PRs
#   2. Check SHA against pr-state.json
#   3. If new/updated: delegate to analyze-pr.sh → post-review.sh
#
# Usage:
#   ./watch-prs.sh                    # daemon mode, 60s interval
#   ./watch-prs.sh -i 30             # custom interval
#   ./watch-prs.sh -r owner/repo     # watch specific repo
#   ./watch-prs.sh --once             # single cycle

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Lock
WATCHER_LOCK_FILE="${REPO_ROOT}/watcher-prs.lock"
WATCHER_PID_FILE="${REPO_ROOT}/watcher-prs.pid"
exec 9>"$WATCHER_LOCK_FILE"
if ! flock -n 9; then
  echo "watch-prs.sh is already running. Exiting." >&2
  exit 1
fi
echo $$ > "$WATCHER_PID_FILE"

trap 'rm -f "$WATCHER_PID_FILE"' EXIT INT TERM

# Hot-reload support
source "${SCRIPT_DIR}/lib/hot-reload.sh"
init_hot_reload "$REPO_ROOT"

# Load env
source "${REPO_ROOT}/.env" 2>/dev/null || true
FORGEJO_HOST="${FORGEJO_HOST:-https://localhost:1234}"
AUTH="${FORGEJO_ADMIN_USER}:${FORGEJO_ADMIN_PASSWORD}"

# Config
INTERVAL="${POLL_INTERVAL:-60}"
REPOS_FILTER=""
RUN_ONCE=false
STATE_FILE="${REPO_ROOT}/runner-data/pr-reviews.json"

# Ollama settings
source "${SCRIPT_DIR}/lib/ollama-client.sh"

# Also set env from .env if not already set (for backward compatibility)
OLLAMA_HOST="${OLLAMA_HOST:-http://localhost:11434}"

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Watch repos for new/updated PRs and post AI reviews via local Ollama.

Options:
  -i <seconds>      Poll interval (default: ${INTERVAL})
  -r <repo>         Watch specific repo
  --once            Single cycle
  -h, --help        This help

Environment:
  POLL_INTERVAL      Interval in seconds (default: 60)
  CODEBERG_TOKEN    API token for Codeberg
  GITHUB_PAT        API token for GitHub
  OLLAMA_HOST       Ollama endpoint
  OLLAMA_MODEL      Model to use

State:
  ${STATE_FILE}
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -i) INTERVAL="$2"; shift 2 ;;
    -r) REPOS_FILTER="$2"; shift 2 ;;
    --once) RUN_ONCE=true; shift ;;
    -h|--help) usage ;;
    *) echo "Unknown: $1" >&2; usage ;;
  esac
done

# Init state
init_state() {
  mkdir -p "$(dirname "$STATE_FILE")"
  if [[ ! -f "$STATE_FILE" ]]; then
    echo '{"reviewed":{}}' > "$STATE_FILE"
  fi
}

# Load state
load_state() {
  if [[ -f "$STATE_FILE" ]]; then
    cat "$STATE_FILE"
  else
    echo '{"reviewed":{}}'
  fi
}

# Check if PR already reviewed with same SHA
is_reviewed() {
  local owner_repo="$1"
  local pr_number="$2"
  local sha="$3"
  
  local state
  state=$(load_state)
  
  python3 -c "
import sys, json
try:
    d = json.loads('${state}')
except:
    print('false')
    sys.exit(0)

key = '${owner_repo}/${pr_number}'
entry = d.get('reviewed', {}).get(key, {})
if entry.get('sha') == '${sha}':
    print('true')
else:
    print('false')
" 2>/dev/null || echo "false"
}

# Get all repos
get_repos() {
  if [[ -n "$REPOS_FILTER" ]]; then
    echo "$REPOS_FILTER"
    return
  fi
  
  curl -sf -u "${AUTH}" "${FORGEJO_HOST}/api/v1/repos/search?limit=50" \
    | python3 -c "
import sys, json
data = json.load(sys.stdin)
repos = data.get('data', [])
for r in repos:
    print(r['full_name'])
" 2>/dev/null || true
}

# Get repo info to determine if it's a mirror
get_repo_info() {
  local repo="$1"
  
  curl -sf -u "${AUTH}" "${FORGEJO_HOST}/api/v1/repos/${repo}" \
    | python3 -c "
import sys, json, re
r = json.load(sys.stdin)
is_mirror = r.get('mirror', False)
original_url = r.get('original_url', '')
website = r.get('website', '')

# Determine platform and original slug
platform = 'unknown'
original_slug = ''

if 'codeberg.org' in original_url or 'codeberg.org' in website:
    platform = 'codeberg'
    m = re.search(r'codeberg\.org[/:]([^/]+/[^/]+)', original_url or website)
    if m: original_slug = m.group(1)
elif 'github.com' in original_url or 'github.com' in website:
    platform = 'github'
    m = re.search(r'github\.com[/:]([^/]+/[^/]+)', original_url or website)
    if m: original_slug = m.group(1)

print(f'{is_mirror}|{platform}|{original_slug}')
" 2>/dev/null || echo "false|unknown|"
}

# Get open PRs for a repo - handles both local and mirrored repos
get_open_prs() {
  local repo="$1"
  local debug_log=""
  
  # First try local Forgejo
  local prs
  prs=$(curl -sf -u "${AUTH}" "${FORGEJO_HOST}/api/v1/repos/${repo}/pulls?state=open&limit=20" \
    | python3 -c "
import sys, json
data = json.load(sys.stdin)
prs = data if isinstance(data, list) else data.get('data', [])
for pr in prs:
    num = pr.get('number', '')
    title = pr.get('title', '')
    sha = pr.get('head', {}).get('sha', '')
    if num and sha:
        print(f'{num}|{sha}|{title}')
" 2>/dev/null || true)
  
  # If no PRs locally, check if it's a mirror and fetch from original platform
  if [[ -z "$prs" ]]; then
    debug_log="No local PRs, checking mirror..."
    local repo_info
    repo_info=$(get_repo_info "$repo")
    local is_mirror platform original_slug
    is_mirror=$(echo "$repo_info" | cut -d'|' -f1)
    platform=$(echo "$repo_info" | cut -d'|' -f2)
    original_slug=$(echo "$repo_info" | cut -d'|' -f3)
    
    if [[ "$is_mirror" == "True" ]] && [[ "$platform" != "unknown" ]] && [[ -n "$original_slug" ]]; then
      # Fetch PRs from original platform (public repos work without auth)
      case "$platform" in
        github)
          prs=$(curl -sf \
            "https://api.github.com/repos/${original_slug}/pulls?state=open&per_page=20" \
            | python3 -c "
import sys, json
data = json.load(sys.stdin)
for pr in data:
    num = pr.get('number', '')
    title = pr.get('title', '')
    sha = pr.get('head', {}).get('sha', '')
    if num and sha:
        print(f'{num}|{sha}|{title}')
" 2>/dev/null || true)
          ;;
        codeberg)
          prs=$(curl -sf \
            "https://codeberg.org/api/v1/repos/${original_slug}/pulls?state=open&limit=20" \
            | python3 -c "
import sys, json
data = json.load(sys.stdin)
prs = data if isinstance(data, list) else data.get('data', [])
for pr in prs:
    num = pr.get('number', '')
    title = pr.get('title', '')
    sha = pr.get('head', {}).get('sha', '')
    if num and sha:
        print(f'{num}|{sha}|{title}')
" 2>/dev/null || true)
          ;;
      esac
    fi
  fi
  
  # Print debug info only if we have no PRs
  if [[ -z "$prs" ]]; then
    echo "$debug_log" >&2
  fi
  
  echo "$prs"
}

# Process a PR
process_pr() {
  local repo="$1"
  local pr_number="$2"
  local pr_sha="$3"
  local pr_title="$4"
  
  echo "  Checking PR #${pr_number}: ${pr_title:0:50}..."
  
  # Check if already reviewed
  if [[ "$(is_reviewed "$repo" "$pr_number" "$pr_sha")" == "true" ]]; then
    echo "    -> already reviewed (SHA: ${pr_sha:0:7})"
    return 0
  fi
  
  echo "    -> NEW/UPDATED, analyzing..."
  
  # Check Ollama available
  if ! ollama_available; then
    echo "    -> ERROR: Ollama not available"
    return 1
  fi
  
  # Get diff - try multiple endpoints
  local diff
  diff=$(curl -sf -u "${AUTH}" "${FORGEJO_HOST}/api/v1/repos/${repo}/pulls/${pr_number}.diff" 2>/dev/null)
  
  # If diff endpoint is empty, try compare endpoint (local)
  if [[ -z "$diff" ]] || [[ ${#diff} -lt 50 ]]; then
    local base_sha head_sha
    base_sha=$(curl -sf -u "${AUTH}" "${FORGEJO_HOST}/api/v1/repos/${repo}/pulls/${pr_number}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('base',{}).get('sha',''))" 2>/dev/null)
    head_sha=$(curl -sf -u "${AUTH}" "${FORGEJO_HOST}/api/v1/repos/${repo}/pulls/${pr_number}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('head',{}).get('sha',''))" 2>/dev/null)
    
    if [[ -n "$base_sha" && -n "$head_sha" ]]; then
      diff=$(curl -sf -u "${AUTH}" "${FORGEJO_HOST}/api/v1/repos/${repo}/compare/${base_sha}...${head_sha}" | python3 -c "
import sys,json
d = json.load(sys.stdin)
files = d.get('files', [])
output = []
for f in files:
    output.append(f'--- a/{f.get(\"filename\")}')
    output.append(f'+++ b/{f.get(\"filename\")}')
    for h in f.get('patch','').split('\n'):
        output.append(h)
print('\n'.join(output))
" 2>/dev/null || true)
    fi
  fi
  
  # If still no diff, try getting from original platform (for mirrored repos)
  if [[ -z "$diff" ]] || [[ ${#diff} -lt 50 ]]; then
    local repo_info
    repo_info=$(get_repo_info "$repo")
    local is_mirror platform original_slug
    is_mirror=$(echo "$repo_info" | cut -d'|' -f1)
    platform=$(echo "$repo_info" | cut -d'|' -f2)
    original_slug=$(echo "$repo_info" | cut -d'|' -f3)
    
    if [[ "$is_mirror" == "True" ]] && [[ "$platform" != "unknown" ]] && [[ -n "$original_slug" ]]; then
      echo "    -> Fetching diff from $platform..."
      
      # Try diff endpoint first (works without auth for public repos)
      case "$platform" in
        github)
          diff=$(curl -sf \
            "https://api.github.com/repos/${original_slug}/pulls/${pr_number}.diff" 2>/dev/null || true)
          ;;
        codeberg)
          diff=$(curl -sf \
            "https://codeberg.org/api/v1/repos/${original_slug}/pulls/${pr_number}.diff" 2>/dev/null || true)
          ;;
      esac
        
        # If still no diff, try compare endpoint
        if [[ -z "$diff" ]] || [[ ${#diff} -lt 50 ]]; then
          # Get base and head SHAs from PR
          local pr_data base head
          case "$platform" in
            github)
              pr_data=$(curl -sf \
                "https://api.github.com/repos/${original_slug}/pulls/${pr_number}")
              base=$(echo "$pr_data" | python3 -c "import sys,json; print(json.load(sys.stdin).get('base',{}).get('sha',''))" 2>/dev/null)
              head=$(echo "$pr_data" | python3 -c "import sys,json; print(json.load(sys.stdin).get('head',{}).get('sha',''))" 2>/dev/null)
              ;;
            codeberg)
              pr_data=$(curl -sf \
                "https://codeberg.org/api/v1/repos/${original_slug}/pulls/${pr_number}")
              base=$(echo "$pr_data" | python3 -c "import sys,json; print(json.load(sys.stdin).get('base',{}).get('sha',''))" 2>/dev/null)
              head=$(echo "$pr_data" | python3 -c "import sys,json; print(json.load(sys.stdin).get('head',{}).get('sha',''))" 2>/dev/null)
              ;;
          esac
          
          if [[ -n "$base" && -n "$head" ]]; then
            case "$platform" in
              github)
                diff=$(curl -sf \
                  "https://api.github.com/repos/${original_slug}/compare/${base}...${head}" | python3 -c "
import sys,json
d = json.load(sys.stdin)
files = d.get('files', [])
output = []
for f in files:
    output.append(f'--- a/{f.get(\"filename\")}')
    output.append(f'+++ b/{f.get(\"filename\")}')
    for h in f.get('patch','').split('\n'):
        output.append(h)
print('\n'.join(output))
" 2>/dev/null || true)
                ;;
              codeberg)
                diff=$(curl -sf \
                  "https://codeberg.org/api/v1/repos/${original_slug}/compare/${base}...${head}" | python3 -c "
import sys,json
d = json.load(sys.stdin)
files = d.get('files', [])
output = []
for f in files:
    output.append(f'--- a/{f.get(\"filename\")}')
    output.append(f'+++ b/{f.get(\"filename\")}')
    for h in f.get('patch','').split('\n'):
        output.append(h)
print('\n'.join(output))
" 2>/dev/null || true)
                ;;
            esac
          fi
        fi
      fi
    fi
  
  if [[ -z "$diff" ]] || [[ ${#diff} -lt 50 ]]; then
    echo "    -> SKIP: No diff available (PR may have no changes or already merged)"
    return 0
  fi
  
  echo "    -> Sending to Ollama (model: ${OLLAMA_MODEL})..."
  
  # Generate review using the prompt approach
  local review_prompt
  review_prompt=$(DIFF_CONTENT="$diff" python3 "${SCRIPT_DIR}/lib/build-prompt.py")

  local ollama_host
  ollama_host=$(resolve_ollama_host)
  
  # Build JSON properly using python to avoid escaping issues
  local response
  response=$(python3 -c "
import json
import os
import sys

data = {
    'model': os.environ.get('OLLAMA_MODEL', 'qwen2.5-coder:14b'),
    'prompt': sys.stdin.read(),
    'stream': False
}
print(json.dumps(data))
" <<< "$review_prompt" | curl -sf -X POST "${ollama_host}/api/generate" \
    -H "Content-Type: application/json" \
    -d @- 2>&1) || {
      echo "    -> ERROR: Ollama request failed"
      return 1
    }
  
  local review
  review=$(echo "$response" | python3 -c "import sys,json; print(json.load(sys.stdin).get('response',''))" 2>/dev/null || true)
  
  if [[ -z "$review" ]]; then
    echo "    -> ERROR: No review from Ollama"
    return 1
  fi
  
  echo "    -> Posting to original platform..."
  
  # Post to original platform
  local platform original_slug
  
  # Detect platform from repo website
  source "${SCRIPT_DIR}/lib/platform-detect.sh"
  platform=$(detect_platform "${repo}")
  original_slug=$(get_original_slug "${repo}")
  
  if [[ "$platform" == "unknown" ]] || [[ -z "$original_slug" ]]; then
    echo "    -> ERROR: Could not detect original platform"
    return 1
  fi
  
  # Get API token
  local api_token
  case "$platform" in
    github) api_token="${GITHUB_PAT}" ;;
    codeberg) api_token="${CODEBERG_TOKEN:-${GITHUB_PAT}}" ;;
  esac
  
  if [[ -z "$api_token" ]]; then
    echo "    -> ERROR: No API token for $platform"
    return 1
  fi
  
  # Build comment and get verdict
  local verdict comment_body
  local build_output
  build_output=$(REVIEW_JSON="$review" OLLAMA_MODEL="$OLLAMA_MODEL" python3 "${SCRIPT_DIR}/lib/build-comment.py")
  
  # First line is verdict, rest is comment body
  verdict=$(echo "$build_output" | head -1)
  comment_body=$(echo "$build_output" | tail -n +2)
  
  echo "    -> Verdict: ${verdict}"

  # Post comment
  local api_url
  case "$platform" in
    github)
      api_url="https://api.github.com/repos/${original_slug}/issues/${pr_number}/comments"
      ;;
    codeberg)
      api_url="https://codeberg.org/api/v1/repos/${original_slug}/issues/${pr_number}/comments"
      ;;
  esac
  
  local post_result
  local escaped_body
  escaped_body=$(echo "$comment_body" | python3 "${SCRIPT_DIR}/lib/json-escape.py")
  post_result=$(curl -sf -X POST "$api_url" \
    -H "Authorization: token $api_token" \
    -H "Content-Type: application/json" \
    -d "{\"body\": ${escaped_body}}" 2>&1) || true
  
  if [[ -n "$post_result" ]]; then
    echo "    -> Review comment posted to ${platform}!"
    
    # Post formal review (approve or request changes)
    local review_api_url review_payload
    case "$platform" in
      github)
        review_api_url="https://api.github.com/repos/${original_slug}/pulls/${pr_number}/reviews"
        review_payload="{\"event\":\"${verdict^^}\",\"body\":${escaped_body}}"
        ;;
      codeberg)
        review_api_url="https://codeberg.org/api/v1/repos/${original_slug}/pulls/${pr_number}/reviews"
        review_payload="{\"type\":\"${verdict}\",\"body\":${escaped_body}}"
        ;;
    esac
    
    local review_result
    review_result=$(curl -sf -X POST "$review_api_url" \
      -H "Authorization: token $api_token" \
      -H "Content-Type: application/json" \
      -d "$review_payload" 2>&1) || true
    
    if [[ -n "$review_result" ]]; then
      echo "    -> Review (${verdict}) submitted to ${platform}!"
    else
      echo "    -> Could not submit formal review (API may not support this)"
    fi
    
    # Update state
    local state
    state=$(load_state)
    STATE_JSON="$state" REPO="$repo" PR_NUMBER="$pr_number" PR_SHA="$pr_sha" python3 "${SCRIPT_DIR}/lib/update-state.py" > "$STATE_FILE"
    
    echo "    -> State updated"
  else
    echo "    -> ERROR: Failed to post to ${platform}"
    return 1
  fi
  
  return 0
}

# Main cycle
cycle() {
  local cycle_num="$1"
  echo ""
  echo "=== Cycle #${cycle_num} ==="
  
  local repos
  repos=$(get_repos)
  
  if [[ -z "$repos" ]]; then
    echo "No repos found"
    return
  fi
  
  local repo_count
  repo_count=$(echo "$repos" | wc -l)
  echo "Watching ${repo_count} repo(s)"
  
  # Skip auto-review for this project if disabled
  local skip_repo=""
  if [[ "${AUTO_REVIEW_DISABLED:-false}" == "true" ]]; then
    skip_repo="gbrennon/local-gb-forgejo"
  fi

  echo "$repos" | while read -r repo; do
    [[ -z "$repo" ]] && continue
    if [[ "$repo" == "$skip_repo" ]]; then
      echo "  Skipping ${repo} (auto-review disabled)"
      continue
    fi
    
    echo ""
    echo "Repo: $repo"
    
    local prs
    prs=$(get_open_prs "$repo")
    
    if [[ -z "$prs" ]]; then
      echo "  No open PRs"
      continue
    fi
    
    echo "$prs" | while IFS='|' read -r pr_number pr_sha pr_title; do
      process_pr "$repo" "$pr_number" "$pr_sha" "$pr_title" || true
    done
  done
}

# Main
init_state

# Check Ollama at startup
if ! ollama_available; then
  echo "WARNING: Ollama not available. PR reviews will fail."
fi

echo "==> AI PR Review Watcher"
echo "    Forgejo: ${FORGEJO_HOST}"
echo "    Interval: ${INTERVAL}s"
echo "    Repos: ${REPOS_FILTER:-all}"
echo "    Ollama: $(resolve_ollama_host)"
echo "    Model: ${OLLAMA_MODEL}"
echo "    Hot-reload: ENABLED (send SIGHUP to reload .env)"
echo "    Ctrl+C to stop"

cycle_num=0

while true; do
  cycle_num=$((cycle_num + 1))
  cycle "$cycle_num" || true
  
  if [[ "$RUN_ONCE" == true ]]; then
    break
  fi
  
  interruptible_sleep "$INTERVAL"
done