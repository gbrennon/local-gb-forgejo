#!/usr/bin/env bash
# GitHub API client functions.
# Requires: GITHUB_PAT, FORGEJO_HOST (source common.sh first).

# shellcheck source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

GITHUB_API="https://api.github.com"

# ---------------------------------------------------------------------------
# github_has_pat
# Returns 0 if GITHUB_PAT is set and non-empty, 1 otherwise.
# Call this before any function that talks to GitHub to allow graceful skip.
# ---------------------------------------------------------------------------
github_has_pat() {
  [[ -n "${GITHUB_PAT:-}" ]]
}

# ---------------------------------------------------------------------------
# github_post_commit_status <github_slug> <sha> <state> <context> <description>
# Posts a commit status to GitHub so it appears on commits and PRs.
#
# github_slug  — "owner/repo" on GitHub (e.g. gbrennon/stunning-palm-tree)
# sha          — full 40-char commit SHA
# state        — pending | success | failure | error
# context      — label shown in GitHub UI (e.g. "forgejo/CI — every push")
# description  — short text shown next to the status (max ~140 chars)
#
# target_url points at the Forgejo Actions page for the repo so users can
# click through to see the local runner logs.
#
# Returns 0 on HTTP 201 (created), 1 on any error.
# ---------------------------------------------------------------------------
github_post_commit_status() {
  local github_slug="$1"
  local sha="$2"
  local state="$3"
  local context="$4"
  local description="$5"
  local target_url="${FORGEJO_HOST}/${github_slug}/actions"

  local http_code
  http_code=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST \
    -H "Authorization: token ${GITHUB_PAT}" \
    -H "Content-Type: application/json" \
    "${GITHUB_API}/repos/${github_slug}/statuses/${sha}" \
    -d "{
      \"state\": \"${state}\",
      \"context\": \"${context}\",
      \"description\": \"${description}\",
      \"target_url\": \"${target_url}\"
    }")

  [[ "$http_code" == "201" ]]
}
