#!/usr/bin/env bash
# platform-detect.sh — Detect external platform (GitHub/Codeberg) from repo.

detect_platform() {
  local repo="$1"
  
  local website
  website=$(curl -sf -u "${AUTH}" "${FORGEJO_HOST}/api/v1/repos/${repo}" \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('website',''))" 2>/dev/null || true)
  
  if [[ -z "$website" ]]; then
    # Check original_url for pull mirrors
    website=$(curl -sf -u "${AUTH}" "${FORGEJO_HOST}/api/v1/repos/${repo}" \
      | python3 -c "import sys,json; print(json.load(sys.stdin).get('original_url',''))" 2>/dev/null || true)
  fi
  
  if [[ "$website" =~ github\.com ]]; then
    echo "github"
  elif [[ "$website" =~ codeberg\.org ]]; then
    echo "codeberg"
  else
    echo "unknown"
  fi
}

get_original_slug() {
  local repo="$1"
  
  local website
  website=$(curl -sf -u "${AUTH}" "${FORGEJO_HOST}/api/v1/repos/${repo}" \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('website',''))" 2>/dev/null || true)
  
  if [[ -z "$website" ]]; then
    website=$(curl -sf -u "${AUTH}" "${FORGEJO_HOST}/api/v1/repos/${repo}" \
      | python3 -c "import sys,json; print(json.load(sys.stdin).get('original_url',''))" 2>/dev/null || true)
  fi
  
  # Extract owner/repo from URL
  echo "$website" | python3 -c "
import sys, re
url = sys.stdin.read().strip()
# Handle git@ URLs
url = re.sub(r'git@[^:]+:', 'https://', url)
# Handle .git suffix
url = re.sub(r'\.git$', '', url)
m = re.search(r'(github|codeberg)\.org[/:]([^/]+/[^/]+)', url)
if m:
    print(m.group(2))
"
}