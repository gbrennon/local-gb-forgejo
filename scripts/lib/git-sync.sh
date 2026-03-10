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
# _forgejo_git_url <owner/repo>
# Returns the authenticated Forgejo HTTP git URL for pushing.
# Credentials are URL-encoded so special characters in passwords (# @ $ etc.)
# do not break the URL parser.
# ---------------------------------------------------------------------------
_forgejo_git_url() {
  local owner_repo="$1"
  local user pass
  user=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1],safe=''))" "$FORGEJO_ADMIN_USER")
  pass=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1],safe=''))" "$FORGEJO_ADMIN_PASSWORD")
  echo "${FORGEJO_HOST/http:\/\//http://${user}:${pass}@}/${owner_repo}.git"
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
    git -C "$cache_dir" remote add forgejo "$forgejo_url"
  else
    git -C "$cache_dir" remote set-url origin "$github_url" 2>/dev/null || true
    git -C "$cache_dir" remote set-url forgejo "$forgejo_url" 2>/dev/null || \
      git -C "$cache_dir" remote add forgejo "$forgejo_url"
    git -C "$cache_dir" fetch --all --prune --quiet
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

  # Lines starting with '=' are up-to-date; ' ' or '*' are updates/new branches.
  local changed=0 total=0
  while IFS= read -r line; do
    case "$line" in
      "="*) total=$((total + 1)) ;;
      " "*|"*"*) changed=$((changed + 1)); total=$((total + 1)) ;;
    esac
  done <<< "$push_out"

  if [[ $changed -gt 0 ]]; then
    echo "${changed}/${total} branch(es) updated"
  else
    echo "all ${total} branch(es) up to date"
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
    git -C "$cache_dir" remote add forgejo "$forgejo_url"
  else
    info "Updating local git cache..."
    git -C "$cache_dir" remote set-url origin "$github_url" 2>/dev/null || true
    git -C "$cache_dir" remote set-url forgejo "$forgejo_url" 2>/dev/null || \
      git -C "$cache_dir" remote add forgejo "$forgejo_url"
    git -C "$cache_dir" fetch --all --prune --quiet
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
