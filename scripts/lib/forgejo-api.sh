#!/usr/bin/env bash
# Forgejo API client functions.

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
    local page_output
    page_output=$(curl -sf \
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

    echo "$page_output" | grep -v '__END__\|__MORE__' || true
    echo "$page_output" | grep -q '__END__' && break
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

  local full_name api_error_msg
  full_name=$(echo "$response" | python3 -c "import sys,json; print(json.load(sys.stdin).get('full_name',''))" 2>/dev/null || true)
  api_error_msg=$(echo "$response" | python3 -c "import sys,json; print(json.load(sys.stdin).get('message',''))" 2>/dev/null || true)

  if [[ -n "$full_name" ]]; then
    echo "$full_name"
  elif echo "$api_error_msg" | grep -qi "already exist"; then
    echo "exists"
  else
    die "Failed to create mirror for ${org}/${repo}. Response: ${response}"
  fi
}
# ---------------------------------------------------------------------------
# forgejo_enable_actions <owner/repo>
# Enables Forgejo Actions for a repository. Must be called after mirror
# creation because the migrate API does not expose this setting.
# Safe to call on repos that already have Actions enabled.
# ---------------------------------------------------------------------------
forgejo_enable_actions() {
  local owner_repo="$1"
  curl -sf -X PATCH \
    -u "${AUTH}" \
    -H "Content-Type: application/json" \
    "${FORGEJO_HOST}/api/v1/repos/${owner_repo}" \
    -d '{"has_actions": true}' >/dev/null
}

# ---------------------------------------------------------------------------
# forgejo_ensure_user <username>
# Creates a Forgejo user if one does not already exist.
# Used so repos can be created under the same namespace as the GitHub org.
# ---------------------------------------------------------------------------
forgejo_ensure_user() {
  local username="$1"
  if curl -sf -u "${AUTH}" "${FORGEJO_HOST}/api/v1/users/${username}" >/dev/null 2>&1; then
    return 0
  fi
  local password
  password=$(python3 -c "import secrets; print(secrets.token_urlsafe(16))")
  curl -sf -X POST \
    -u "${AUTH}" \
    -H "Content-Type: application/json" \
    "${FORGEJO_HOST}/api/v1/admin/users" \
    -d "{
      \"username\": \"${username}\",
      \"email\": \"${username}@local.forgejo\",
      \"password\": \"${password}\",
      \"must_change_password\": false
    }" >/dev/null
}

# ---------------------------------------------------------------------------
# forgejo_create_push_repo <owner> <repo_name>
# Creates a regular (non-mirror) Forgejo repo owned by <owner>.
# Uses the admin API so the repo is created under the specified user,
# not the admin account. Calls forgejo_ensure_user first so the owner
# is created automatically if they don't exist yet.
# Stores the GitHub URL as the repo website field so git_push_sync and
# forgejo_list_push_repos can discover it without a separate registry file.
# Prints the full_name of the created repo, or "exists" if already present.
# ---------------------------------------------------------------------------
forgejo_create_push_repo() {
  local org="$1"
  local repo="$2"

  forgejo_ensure_user "$org" || true

  local response
  response=$(curl -s -X POST \
    -u "${AUTH}" \
    -H "Content-Type: application/json" \
    "${FORGEJO_HOST}/api/v1/admin/users/${org}/repos" \
    -d "{
      \"name\": \"${repo}\",
      \"description\": \"Sync of github.com/${org}/${repo}\",
      \"private\": false,
      \"auto_init\": false
    }")

  local full_name api_error_msg
  full_name=$(echo "$response" | python3 -c "import sys,json; print(json.load(sys.stdin).get('full_name',''))" 2>/dev/null || true)
  api_error_msg=$(echo "$response" | python3 -c "import sys,json; print(json.load(sys.stdin).get('message',''))" 2>/dev/null || true)

  if [[ -n "$full_name" ]]; then
    curl -sf -X PATCH \
      -u "${AUTH}" \
      -H "Content-Type: application/json" \
      "${FORGEJO_HOST}/api/v1/repos/${full_name}" \
      -d "{\"website\": \"https://github.com/${org}/${repo}\"}" >/dev/null
    echo "$full_name"
  elif echo "$api_error_msg" | grep -qi "already exist"; then
    echo "exists"
  else
    die "Failed to create repo for ${org}/${repo}. Response: ${response}"
  fi
}

# ---------------------------------------------------------------------------
# forgejo_list_push_repos
# Prints "owner/repo" for every repo whose website field contains github.com.
# These are repos managed by the push-sync workflow (not Forgejo pull mirrors).
# ---------------------------------------------------------------------------
forgejo_list_push_repos() {
  local page=1
  while true; do
    local page_output
    page_output=$(curl -sf \
      -u "${AUTH}" \
      "${FORGEJO_HOST}/api/v1/repos/search?limit=50&page=${page}" \
      | python3 -c "
import sys, json
result = json.load(sys.stdin)
repos = result.get('data', [])
for r in repos:
    if not r.get('mirror') and 'github.com' in r.get('website', ''):
        print(r['full_name'])
print('__END__' if len(repos) < 50 else '__MORE__')
" 2>/dev/null || true)

    echo "$page_output" | grep -v '__END__\|__MORE__' || true
    echo "$page_output" | grep -q '__END__' && break
    page=$((page + 1))
  done
}

# ---------------------------------------------------------------------------
# forgejo_delete_repo <owner/repo>
# Permanently deletes a Forgejo repository. Used to convert pull mirrors to
# push-based repos (delete mirror, recreate as regular repo, then push).
# ---------------------------------------------------------------------------
forgejo_delete_repo() {
  local owner_repo="$1"
  local owner="${owner_repo%%/*}"
  local repo="${owner_repo#*/}"

  # Try regular delete first
  local resp code body
  resp=$(curl -s -w "\n%{http_code}" -X DELETE -u "${AUTH}" "${FORGEJO_HOST}/api/v1/repos/${owner_repo}" || true)
  code=$(echo "$resp" | tail -n1)
  body=$(echo "$resp" | sed '$d')
  if [[ "$code" =~ ^2 ]]; then
    return 0
  fi

  # Fallback: try admin delete endpoint
  resp=$(curl -s -w "\n%{http_code}" -X DELETE -u "${AUTH}" "${FORGEJO_HOST}/api/v1/admin/repos/${owner}/${repo}" || true)
  code=$(echo "$resp" | tail -n1)
  body=$(echo "$resp" | sed '$d')
  if [[ "$code" =~ ^2 ]]; then
    return 0
  fi

  # Could not delete; print server response for diagnostics and return non-zero
  echo "failed to delete ${owner_repo}: HTTP ${code} - ${body}" >&2
  return 1
}

# ---------------------------------------------------------------------------
# forgejo_convert_mirror_to_push <owner/repo>
# Converts a Forgejo pull mirror to a regular push-based repo IN PLACE:
#   1. Records the GitHub source URL from the mirror's clone_addr/original_url
#   2. Deletes the pull mirror
#   3. Recreates the repo under the SAME owner using the admin API
#   4. Sets the website field to the GitHub URL (used by forgejo_list_push_repos)
#   5. Enables Actions
# Prints the github slug ("org/repo") to stdout on success.
# Prints an error message to stderr and returns non-zero on failure.
# ---------------------------------------------------------------------------
forgejo_convert_mirror_to_push() {
  local owner_repo="$1"
  local owner="${owner_repo%%/*}"
  local repo="${owner_repo#*/}"

  local github_slug
  github_slug=$(forgejo_get_mirror_source "$owner_repo")
  if [[ -z "$github_slug" ]]; then
    echo "cannot determine GitHub source for ${owner_repo}" >&2
    return 1
  fi

  forgejo_delete_repo "$owner_repo" || {
    echo "failed to delete pull mirror ${owner_repo}" >&2
    return 1
  }

  # Use admin API to recreate the repo under the original owner's namespace.
  local response
  response=$(curl -s -X POST \
    -u "${AUTH}" \
    -H "Content-Type: application/json" \
    "${FORGEJO_HOST}/api/v1/admin/users/${owner}/repos" \
    -d "{
      \"name\": \"${repo}\",
      \"description\": \"Sync of github.com/${github_slug}\",
      \"private\": false,
      \"auto_init\": false
    }")

  local full_name api_err
  full_name=$(echo "$response" | python3 -c "import sys,json; print(json.load(sys.stdin).get('full_name',''))" 2>/dev/null || true)
  api_err=$(echo "$response" | python3 -c "import sys,json; print(json.load(sys.stdin).get('message',''))" 2>/dev/null || true)

  if [[ -z "$full_name" ]]; then
    echo "failed to recreate ${owner_repo}: ${api_err:-${response}}" >&2
    return 1
  fi

  # Set website so forgejo_list_push_repos and forgejo_get_mirror_source can find it.
  curl -sf -X PATCH \
    -u "${AUTH}" \
    -H "Content-Type: application/json" \
    "${FORGEJO_HOST}/api/v1/repos/${full_name}" \
    -d "{\"website\": \"https://github.com/${github_slug}\"}" >/dev/null

  forgejo_enable_actions "$full_name" || true

  echo "$github_slug"
}


# ---------------------------------------------------------------------------
# forgejo_repo_exists <owner/repo>
# Returns 0 if repo exists, non-zero otherwise.
# ---------------------------------------------------------------------------
forgejo_repo_exists() {
  local owner_repo="$1"
  curl -sf -u "${AUTH}" "${FORGEJO_HOST}/api/v1/repos/${owner_repo}" >/dev/null 2>&1
}


# ---------------------------------------------------------------------------
# forgejo_trigger_sync <owner/repo>
# Requests an immediate mirror sync. Accepts full "owner/repo" path.
# Returns: prints API response body on success; non-zero exit on failure and
# prints API error body to stderr for logging.
# ---------------------------------------------------------------------------
forgejo_trigger_sync() {
  local owner_repo="$1"
  local resp
  resp=$(curl -s -w "\n%{http_code}" -X POST \
    -u "${AUTH}" \
    "${FORGEJO_HOST}/api/v1/repos/${owner_repo}/mirror-sync" || true)

  local code
  code=$(echo "$resp" | tail -n1)
  local body
  body=$(echo "$resp" | sed '$d')

  if [[ "$code" =~ ^2 ]]; then
    # Success: print body (may be empty) for callers to examine
    if [[ -n "$body" ]]; then
      echo "$body"
    else
      echo "ok"
    fi
    return 0
  else
    # Failure: print body (or generic message) to stderr and return failure
    if [[ -n "$body" ]]; then
      echo "$body" >&2
    else
      echo "mirror-sync failed with HTTP ${code}" >&2
    fi
    return 1
  fi
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
# forgejo_list_workflow_files <owner/repo> [path]
# Prints names of workflow files found at the given path.
# Defaults to .github/workflows if no path is given.
# ---------------------------------------------------------------------------
forgejo_list_workflow_files() {
  local owner_repo="$1"
  local workflows_path="${2:-.github/workflows}"
  curl -sf \
    -u "${AUTH}" \
    "${FORGEJO_HOST}/api/v1/repos/${owner_repo}/contents/${workflows_path}" \
    | python3 -c "
import sys, json
fs = json.load(sys.stdin)
[print(f['name']) for f in (fs if isinstance(fs, list) else [])]
" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# forgejo_list_recent_runs <owner/repo> [limit]
# Prints the most recent Actions run per (name, branch) pair.
# Format: "<status>\t<name>\t<branch>\t<sha>\t<run_url>"
# Uses /actions/tasks endpoint (Forgejo v11+; /actions/runs is not implemented).
# Deduplicates: only the latest run per (workflow name + branch) is returned,
# so stale pre-fix failures on old branches don't shadow current results.
# ---------------------------------------------------------------------------
forgejo_list_recent_runs() {
  local owner_repo="$1"
  local limit="${2:-20}"
  curl -sf \
    -u "${AUTH}" \
    "${FORGEJO_HOST}/api/v1/repos/${owner_repo}/actions/tasks?limit=${limit}" \
    | python3 -c "
import sys, json
data = json.load(sys.stdin)
runs = data.get('workflow_runs', [])
if not runs:
    print('no_runs')
    sys.exit(0)
# Deduplicate: keep only the first (most recent) run per (name, branch) pair.
seen = set()
for r in runs:
    status = r.get('status', 'unknown')
    conclusion = r.get('conclusion', '')
    name = r.get('name', r.get('display_title', '?'))
    branch = r.get('head_branch', '?')
    sha = r.get('head_sha', '')
    run_url = r.get('url', '')
    final_status = conclusion if conclusion else status
    key = (name, branch)
    if key in seen:
        continue
    seen.add(key)
    print(f'{final_status}\t{name}\t{branch}\t{sha}\t{run_url}')
" 2>/dev/null || echo "no_runs"
}

# ---------------------------------------------------------------------------
# forgejo_get_mirror_source <owner/repo>
# Returns the GitHub "owner/repo" slug. Checks original_url (pull mirrors)
# then website (push repos created by forgejo_create_push_repo).
# Returns empty string if no GitHub source is found.
# ---------------------------------------------------------------------------
forgejo_get_mirror_source() {
  local owner_repo="$1"
  curl -sf \
    -u "${AUTH}" \
    "${FORGEJO_HOST}/api/v1/repos/${owner_repo}" \
    | python3 -c "
import sys,json,re
try:
    d=json.load(sys.stdin)
except Exception:
    print('')
    sys.exit(0)
# Try known URL fields first
for field in ('original_url','website'):
    url=(d.get(field) or '').strip()
    if not url:
        continue
    url_norm=re.sub(r'^git@github\.com:', 'https://github.com/', url)
    m=re.search(r'github\.com[:/]+([^/]+/[^/]+?)(?:\.git)?(?:/|$)', url_norm)
    if m:
        print(m.group(1))
        sys.exit(0)
# Fallback: if the repo's full_name is present, use it (owner/repo)
full = (d.get('full_name') or '').strip()
if '/' in full:
    print(full)
else:
    print('')
" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# forgejo_report_missing_secrets <owner/repo>
# Clones the mirror locally, scans .github/workflows/ for secrets.* references,
# and prints the curl commands needed to register each missing secret.
# Admin credentials are used so all repos are accessible regardless of owner.
# ---------------------------------------------------------------------------
forgejo_report_missing_secrets() {
  local owner_repo="$1"
  local repo="${owner_repo#*/}"

  local tmp_clone
  tmp_clone=$(mktemp -d)
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp_clone}'" RETURN

  git clone --quiet \
    "http://${FORGEJO_ADMIN_USER}:${FORGEJO_ADMIN_PASSWORD}@localhost:1234/${owner_repo}.git" \
    "${tmp_clone}/${repo}" 2>/dev/null || true

  local workflow_dirs=(".github/workflows" ".forgejo/workflows")
  local found_workflows=false
  for wf_dir in "${workflow_dirs[@]}"; do
    if [[ -d "${tmp_clone}/${repo}/${wf_dir}" ]]; then
      found_workflows=true
    fi
  done

  if ! $found_workflows; then
    info "No workflow directories found (.forgejo/workflows/ or .github/workflows/)"
    return
  fi

  local referenced_secrets=""
  for wf_dir in "${workflow_dirs[@]}"; do
    if [[ -d "${tmp_clone}/${repo}/${wf_dir}" ]]; then
      local dir_secrets
      dir_secrets=$(grep -r 'secrets\.' "${tmp_clone}/${repo}/${wf_dir}/" \
        | grep -o 'secrets\.[A-Za-z_][A-Za-z0-9_]*' || true)
      referenced_secrets="${referenced_secrets}${dir_secrets}"$'\n'
    fi
  done
  referenced_secrets=$(echo "$referenced_secrets" | sort -u | grep -v '^$' || true)

  if [[ -n "$referenced_secrets" ]]; then
    warn "Secrets referenced in workflow files — register them in Forgejo:"
    while IFS= read -r s; do
      local secret_name="${s#secrets.}"
      info "  curl -s -X PUT -u '${AUTH}' -H 'Content-Type: application/json' \\"
      info "    '${FORGEJO_HOST}/api/v1/repos/${owner_repo}/actions/secrets/${secret_name}' \\"
      info "    -d '{\"data\": \"YOUR_VALUE\"}'"
    done <<< "$referenced_secrets"
  else
    ok "No secrets.* references found in workflow files"
  fi
}
