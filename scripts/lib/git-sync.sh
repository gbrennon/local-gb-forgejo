#!/usr/bin/env bash
# git-sync.sh — Push-based repository synchronization.
#
# Maintains persistent local bare clones and pushes new commits to Forgejo,
# which fires real push events and triggers Forgejo Actions workflows.
#
# Pull mirrors (forgejo_trigger_sync) do NOT fire push events — this is the
# correct approach to get Actions to run on synced commits.

# shellcheck source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

GIT_CACHE_DIR="${REPO_ROOT}/runner-data/git-cache"

# ---------------------------------------------------------------------------
# _forgejo_user_push_token <username>
# Returns a PAT for <username> suitable for git push authentication.
# Tokens are cached in FORGEJO_TOKEN_CACHE_DIR and reused across cycles.
# On first use (or cache miss) a new token is created via the admin API.
# ---------------------------------------------------------------------------
_FORGEJO_TOKEN_CACHE_DIR="${REPO_ROOT}/runner-data/push-tokens"

_forgejo_user_push_token() {
  local username="$1"
  local cache_file="${_FORGEJO_TOKEN_CACHE_DIR}/${username}"

  mkdir -p "$_FORGEJO_TOKEN_CACHE_DIR"
  chmod 700 "$_FORGEJO_TOKEN_CACHE_DIR"

  # Validate cached token with a lightweight API call before trusting it.
  if [[ -f "$cache_file" ]]; then
    local cached_token
    cached_token=$(cat "$cache_file")
    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" \
      -H "Authorization: token ${cached_token}" \
      "${FORGEJO_HOST}/api/v1/user" 2>/dev/null || echo "000")
    if [[ "$http_code" == "200" ]]; then
      echo "$cached_token"
      return 0
    fi
    # Token is stale — remove cache and fall through to re-create.
    rm -f "$cache_file"
  fi

  # Delete any existing token with this name before creating a fresh one.
  local existing_id
  existing_id=$(curl -sf \
    -u "${AUTH}" \
    "${FORGEJO_HOST}/api/v1/users/${username}/tokens" \
    | python3 -c "
import sys,json
for t in json.load(sys.stdin):
    if t.get('name') == 'watcher-push':
        print(t['id']); break
" 2>/dev/null || true)
  if [[ -n "$existing_id" ]]; then
    curl -sf -X DELETE \
      -u "${AUTH}" \
      "${FORGEJO_HOST}/api/v1/users/${username}/tokens/${existing_id}" \
      >/dev/null 2>&1 || true
  fi

  local token
  token=$(curl -sf -X POST \
    -u "${AUTH}" \
    -H "Content-Type: application/json" \
    "${FORGEJO_HOST}/api/v1/users/${username}/tokens" \
    -d '{"name":"watcher-push","scopes":["write:repository"]}' \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['sha1'])" 2>/dev/null || true)

  if [[ -z "$token" ]]; then
    # Fall back to admin credentials if token creation fails.
    echo "$FORGEJO_ADMIN_PASSWORD"
    return 0
  fi

  echo "$token" > "$cache_file"
  chmod 600 "$cache_file"
  echo "$token"
}

# ---------------------------------------------------------------------------
# _forgejo_git_url <owner/repo>
# Returns the authenticated Forgejo HTTP git URL for pushing.
# Uses a PAT belonging to the repo owner so pushes are attributed correctly.
# Credentials are URL-encoded so special characters do not break the URL.
# ---------------------------------------------------------------------------
_forgejo_git_url() {
  local owner_repo="$1"
  local owner="${owner_repo%%/*}"

  local token
  token=$(_forgejo_user_push_token "$owner")

  local user_enc token_enc
  user_enc=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1],safe=''))" "$owner")
  token_enc=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1],safe=''))" "$token")
  echo "${FORGEJO_HOST/http:\/\//http://${user_enc}:${token_enc}@}/${owner_repo}.git"
}

# ---------------------------------------------------------------------------
# _github_git_url <github_slug>
# Returns the authenticated GitHub HTTPS git URL for cloning/fetching.
# GITHUB_PAT is URL-encoded to handle special characters safely.
# ---------------------------------------------------------------------------
_github_git_url() {
  local slug="$1"
  local pat
  pat=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1],safe=''))" "$GITHUB_PAT")
  echo "https://${pat}@github.com/${slug}.git"
}

# ---------------------------------------------------------------------------
# git_push_sync <forgejo_owner/repo>
# Fetches latest commits from GitHub and pushes all branches + tags to
# Forgejo via HTTP. Forgejo fires real push events → Actions workflows run.
# Maintains a persistent bare clone in GIT_CACHE_DIR.
# Returns 0 on success, 1 on failure.
# Requires: AUTH, FORGEJO_HOST, GITHUB_PAT, forgejo_get_mirror_source()
# ---------------------------------------------------------------------------
git_push_sync() {
  local forgejo_repo="$1"
  local repo_name="${forgejo_repo##*/}"
  local cache_dir="${GIT_CACHE_DIR}/${repo_name}"

  local github_slug
  github_slug=$(forgejo_get_mirror_source "$forgejo_repo")
  if [[ -z "$github_slug" ]]; then
    warn "git_push_sync: no GitHub source found for ${forgejo_repo}" >&2
    return 1
  fi

  local github_url forgejo_url
  github_url=$(_github_git_url "$github_slug")
  forgejo_url=$(_forgejo_git_url "$forgejo_repo")

  mkdir -p "$GIT_CACHE_DIR"

  if [[ ! -d "$cache_dir" ]]; then
    git clone --bare --quiet "$github_url" "$cache_dir"
    # Ensure origin maps all remote branches into local refs/heads/* so that
    # git push --all sends every branch to Forgejo.
    git -C "$cache_dir" config remote.origin.fetch '+refs/heads/*:refs/heads/*'
    git -C "$cache_dir" remote add forgejo "$forgejo_url"
  else
    git -C "$cache_dir" remote set-url origin "$github_url" 2>/dev/null || true
    # Ensure fetch refspec is correct — bare clones can lose it if the remote
    # was re-added or manipulated. Without this, fetch only updates FETCH_HEAD
    # and refs/heads/* stay stale, causing "all branches up to date" false positives.
    git -C "$cache_dir" config remote.origin.fetch '+refs/heads/*:refs/heads/*'
    git -C "$cache_dir" remote set-url forgejo "$forgejo_url" 2>/dev/null || \
      git -C "$cache_dir" remote add forgejo "$forgejo_url" 2>/dev/null || true
    git -C "$cache_dir" fetch origin --prune --quiet
  fi

  local push_out
  # Attempt push with a few retries to handle transient connection resets
  local attempt=0
  push_out=""
  while [[ $attempt -lt 3 ]]; do
    push_out=$(git -C "$cache_dir" push forgejo --all --force --porcelain 2>&1) && break || true
    attempt=$((attempt + 1))
    sleep $((attempt * 2))
  done
  if [[ -z "$push_out" ]]; then
    # Last attempt failed — return failure with output from last try
    push_out=$(git -C "$cache_dir" push forgejo --all --force --porcelain 2>&1) || return 1
  fi
  git -C "$cache_dir" push forgejo --tags --force --quiet 2>/dev/null || true

  # Total branch count from the local cache (authoritative — not from push output
  # which can omit branches when the remote is already in sync).
  local total
  total=$(git -C "$cache_dir" show-ref --heads 2>/dev/null | wc -l | tr -d ' ')

  # Parse porcelain: flag is the single first character of each ref line.
  #   '=' → up to date   ' ' → fast-forward   '+' → forced   '*' → new ref
  # Avoid bash case globs by slicing the first character explicitly.
  local changed=0
  local ref_field branch_name
  local changed_branches=()
  while IFS= read -r line; do
    local flag="${line:0:1}"
    case "$flag" in
      ' '|'+'|'*')
        changed=$((changed + 1))
        # Extract branch name: field 2 of tab-separated output, left side of ':'
        ref_field=$(echo "$line" | awk -F'\t' '{print $2}')
        branch_name="${ref_field%%:*}"
        branch_name="${branch_name##refs/heads/}"
        if [[ -n "$branch_name" ]]; then
          changed_branches+=("$branch_name")
        fi
        ;;
    esac
  done <<< "$push_out"

  if [[ $changed -gt 0 ]]; then
    echo "${changed}/${total} branch(es) updated"
  else
    echo "all ${total} branch(es) up to date"
  fi

  # Emit changed branch names for the caller (one per line, prefixed).
  if [[ ${#changed_branches[@]} -gt 0 ]]; then
    for b in "${changed_branches[@]}"; do
      echo "CHANGED:${b}"
    done
  fi
}

# ---------------------------------------------------------------------------
# git_init_push <forgejo_owner/repo> <github_slug>
# Performs the initial clone + push when registering a new repo.
# Prints progress to stdout (intended for interactive use in mirror-repo.sh).
# Requires: AUTH, FORGEJO_HOST, GITHUB_PAT
# ---------------------------------------------------------------------------
git_init_push() {
  local forgejo_repo="$1"
  local github_slug="$2"
  local repo_name="${forgejo_repo##*/}"
  local cache_dir="${GIT_CACHE_DIR}/${repo_name}"

  local github_url forgejo_url
  github_url=$(_github_git_url "$github_slug")
  forgejo_url=$(_forgejo_git_url "$forgejo_repo")

  mkdir -p "$GIT_CACHE_DIR"

  if [[ ! -d "$cache_dir" ]]; then
    info "Cloning from GitHub (may take a moment for large repos)..."
    git clone --bare --quiet "$github_url" "$cache_dir"
    git -C "$cache_dir" config remote.origin.fetch '+refs/heads/*:refs/heads/*'
    git -C "$cache_dir" remote add forgejo "$forgejo_url"
  else
    info "Updating local git cache..."
    git -C "$cache_dir" remote set-url origin "$github_url" 2>/dev/null || true
    git -C "$cache_dir" config remote.origin.fetch '+refs/heads/*:refs/heads/*'
    git -C "$cache_dir" remote set-url forgejo "$forgejo_url" 2>/dev/null || \
      git -C "$cache_dir" remote add forgejo "$forgejo_url" 2>/dev/null || true
    git -C "$cache_dir" fetch origin --prune --quiet
  fi

  # Retry initial push to handle transient network/service restarts
  local attempts=0
  local pushed=1
  while [[ $attempts -lt 3 ]]; do
    if git -C "$cache_dir" push forgejo --all --force --quiet; then
      pushed=0
      break
    fi
    attempts=$((attempts + 1))
    sleep $((attempts * 2))
  done
  if [[ $pushed -ne 0 ]]; then
    # last try (to capture error output)
    git -C "$cache_dir" push forgejo --all --force --porcelain || return 1
  fi
  git -C "$cache_dir" push forgejo --tags --force --quiet || true
}
