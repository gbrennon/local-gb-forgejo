#!/usr/bin/env bash
# Forgejo API client functions.
# Requires: AUTH, FORGEJO_HOST, FORGEJO_ADMIN_USER, GITHUB_PAT (source common.sh first).

# shellcheck source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# ---------------------------------------------------------------------------
# forgejo_list_mirrors
# Prints "owner/repo" for every mirror in Forgejo, across ALL users.
# Pages through the API automatically (50 repos per page).
# ---------------------------------------------------------------------------
forgejo_list_mirrors() {
  local page=1
  while true; do
    local chunk
    chunk=$(curl -sf \
      -u "${AUTH}" \
      "${FORGEJO_HOST}/api/v1/repos/search?limit=50&page=${page}" \
      | python3 -c "
import sys, json
result = json.load(sys.stdin)
repos = result.get('data', [])
for r in repos:
    if r.get('mirror'):
        print(r['full_name'])
print('__END__' if len(repos) < 50 else '__MORE__')
" 2>/dev/null || true)

    echo "$chunk" | grep -v '__END__\|__MORE__' || true
    echo "$chunk" | grep -q '__END__' && break
    page=$((page + 1))
  done
}

# ---------------------------------------------------------------------------
# forgejo_create_mirror <github_org> <repo_name>
# Creates a GitHub mirror in Forgejo owned by FORGEJO_ADMIN_USER.
# auth_token is the correct way to pass credentials — Forgejo stores the PAT
# in its internal DB and injects it at fetch time. Do NOT embed credentials in
# clone_addr: Forgejo v11 rejects URLs that contain credentials.
# Internal mirror_interval is set to 10m (Forgejo minimum); watcher drives the
# actual 1-min sync cadence externally via the mirror-sync API.
# Prints the full_name of the created repo, or "exists" if already present.
# ---------------------------------------------------------------------------
forgejo_create_mirror() {
  local org="$1"
  local repo="$2"

  local response
  response=$(curl -s -X POST \
    -u "${AUTH}" \
    -H "Content-Type: application/json" \
    "${FORGEJO_HOST}/api/v1/repos/migrate" \
    -d "{
      \"clone_addr\": \"https://github.com/${org}/${repo}.git\",
      \"auth_token\": \"${GITHUB_PAT}\",
      \"mirror\": true,
      \"mirror_interval\": \"10m0s\",
      \"repo_name\": \"${repo}\",
      \"repo_owner\": \"${FORGEJO_ADMIN_USER}\",
      \"service\": \"github\",
      \"private\": false
    }")

  local full_name error_msg
  full_name=$(echo "$response" | python3 -c "import sys,json; print(json.load(sys.stdin).get('full_name',''))" 2>/dev/null || true)
  error_msg=$(echo "$response" | python3 -c "import sys,json; print(json.load(sys.stdin).get('message',''))" 2>/dev/null || true)

  if [[ -n "$full_name" ]]; then
    echo "$full_name"
  elif echo "$error_msg" | grep -qi "already exist"; then
    echo "exists"
  else
    die "Failed to create mirror for ${org}/${repo}. Response: ${response}"
  fi
}

# ---------------------------------------------------------------------------
# forgejo_trigger_sync <owner/repo>
# Requests an immediate mirror sync. Accepts full "owner/repo" path.
# ---------------------------------------------------------------------------
forgejo_trigger_sync() {
  local owner_repo="$1"
  curl -sf -X POST \
    -u "${AUTH}" \
    "${FORGEJO_HOST}/api/v1/repos/${owner_repo}/mirror-sync" >/dev/null
}

# ---------------------------------------------------------------------------
# forgejo_list_branches <owner/repo>
# Prints one branch name per line.
# ---------------------------------------------------------------------------
forgejo_list_branches() {
  local owner_repo="$1"
  curl -sf \
    -u "${AUTH}" \
    "${FORGEJO_HOST}/api/v1/repos/${owner_repo}/branches" \
    | python3 -c "import sys,json; [print(b['name']) for b in json.load(sys.stdin)]" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# forgejo_list_workflow_files <owner/repo>
# Prints names of workflow files found in .github/workflows/.
# ---------------------------------------------------------------------------
forgejo_list_workflow_files() {
  local owner_repo="$1"
  curl -sf \
    -u "${AUTH}" \
    "${FORGEJO_HOST}/api/v1/repos/${owner_repo}/contents/.github/workflows" \
    | python3 -c "
import sys, json
fs = json.load(sys.stdin)
[print(f['name']) for f in (fs if isinstance(fs, list) else [])]
" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# forgejo_list_recent_runs <owner/repo> [limit]
# Prints recent Actions workflow runs: "<status>\t<name>\t<branch>\t<full_sha>"
# Uses /actions/tasks which is the correct endpoint on Forgejo v11.
# status is taken from the 'status' field (Forgejo uses it as the terminal state,
# unlike GitHub which uses 'conclusion'). Full SHA is returned so callers can
# use it directly with the GitHub Commit Status API.
# ---------------------------------------------------------------------------
forgejo_list_recent_runs() {
  local owner_repo="$1"
  local limit="${2:-5}"
  curl -sf \
    -u "${AUTH}" \
    "${FORGEJO_HOST}/api/v1/repos/${owner_repo}/actions/tasks?limit=${limit}" \
    | python3 -c "
import sys, json
data = json.load(sys.stdin)
runs = data.get('workflow_runs', [])
if not runs:
    print('no_runs')
for r in runs:
    status = r.get('status', 'unknown')
    name   = r.get('name', r.get('display_title', '?'))
    branch = r.get('head_branch', '?')
    sha    = r.get('head_sha', '')
    print(f'{status}\t{name}\t{branch}\t{sha}')
" 2>/dev/null || echo "no_runs"
}

# ---------------------------------------------------------------------------
# forgejo_get_mirror_source <owner/repo>
# Returns the GitHub "owner/repo" slug by reading the original_url field
# from the Forgejo repo metadata. Returns empty string if not a GitHub mirror.
# ---------------------------------------------------------------------------
forgejo_get_mirror_source() {
  local owner_repo="$1"
  curl -sf \
    -u "${AUTH}" \
    "${FORGEJO_HOST}/api/v1/repos/${owner_repo}" \
    | python3 -c "
import sys, json, re
d = json.load(sys.stdin)
url = d.get('original_url', '')
m = re.search(r'github\.com[:/]([^/]+/[^/.]+?)(?:\.git)?$', url)
print(m.group(1) if m else '')
" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# forgejo_scan_secrets <owner/repo>
# Clones the mirror locally, scans .github/workflows/ for secrets.* references,
# and prints the curl commands needed to register each missing secret.
# Admin credentials are used so all repos are accessible regardless of owner.
# ---------------------------------------------------------------------------
forgejo_scan_secrets() {
  local owner_repo="$1"
  local repo="${owner_repo#*/}"

  local tmp_clone
  tmp_clone=$(mktemp -d)
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp_clone}'" RETURN

  git clone --quiet \
    "http://${FORGEJO_ADMIN_USER}:${FORGEJO_ADMIN_PASSWORD}@localhost:1234/${owner_repo}.git" \
    "${tmp_clone}/${repo}" 2>/dev/null || true

  if [[ ! -d "${tmp_clone}/${repo}/.github/workflows" ]]; then
    info "No .github/workflows/ directory to scan"
    return
  fi

  local required_secrets
  required_secrets=$(grep -r 'secrets\.' "${tmp_clone}/${repo}/.github/workflows/" \
    | grep -o 'secrets\.[A-Za-z_][A-Za-z0-9_]*' \
    | sort -u || true)

  if [[ -n "$required_secrets" ]]; then
    warn "Secrets referenced in workflow files — register them in Forgejo:"
    while IFS= read -r s; do
      local secret_name="${s#secrets.}"
      info "  curl -s -X PUT -u '${AUTH}' -H 'Content-Type: application/json' \\"
      info "    '${FORGEJO_HOST}/api/v1/repos/${owner_repo}/actions/secrets/${secret_name}' \\"
      info "    -d '{\"data\": \"YOUR_VALUE\"}'"
    done <<< "$required_secrets"
  else
    ok "No secrets.* references found in workflow files"
  fi
}


# end of forgejo-api.sh
