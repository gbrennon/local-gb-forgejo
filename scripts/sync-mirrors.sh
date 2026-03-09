#!/usr/bin/env bash
# sync-mirrors.sh — Trigger an immediate sync on Forgejo mirror repositories.
#
# Without arguments: syncs ALL mirrors, including those created via the web UI.
# With a repo name:  syncs only that specific mirror.
#
# The Forgejo API (mirror-sync) works for every mirror regardless of how it was
# originally created, so this script covers web UI mirrors and script mirrors alike.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/forgejo-api.sh
source "${SCRIPT_DIR}/lib/forgejo-api.sh"

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
  cat <<EOF
Usage: $(basename "$0") [repo]

Trigger an immediate sync on Forgejo mirror repositories.

Without arguments, syncs ALL mirrors (including those created via the web UI).
With a repo name, syncs only that specific repository.

Arguments:
  repo   (optional) name of a specific repository to sync

Required variables in .env:
  FORGEJO_ADMIN_USER      Forgejo admin username
  FORGEJO_ADMIN_PASSWORD  Forgejo admin password
  GITHUB_PAT              GitHub Personal Access Token

Examples:
  $(basename "$0")              # sync every mirror
  $(basename "$0") my-service   # sync only my-service
EOF
  exit 1
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && usage

load_env

step "Checking Forgejo"
require_forgejo

# Normalise: bare "repo" → "owner/repo" using admin as default owner
TARGET_REPO="${1:-}"
if [[ -n "$TARGET_REPO" && "$TARGET_REPO" != */* ]]; then
  TARGET_REPO="${FORGEJO_ADMIN_USER}/${TARGET_REPO}"
fi

if [[ -n "$TARGET_REPO" ]]; then
  # ---------------------------------------------------------------------------
  # Sync a single named repo
  # ---------------------------------------------------------------------------
  step "Syncing mirror: ${TARGET_REPO}"
  forgejo_trigger_sync "$TARGET_REPO"
  ok "Sync triggered for ${TARGET_REPO}"

else
  # ---------------------------------------------------------------------------
  # Discover and sync all mirrors
  # ---------------------------------------------------------------------------
  step "Discovering all mirrors in Forgejo"

  mapfile -t mirrors < <(forgejo_list_mirrors)

  if [[ ${#mirrors[@]} -eq 0 ]]; then
    warn "No mirrors found. Use ./scripts/mirror-repo.sh <org> <repo> to add one."
    exit 0
  fi

  ok "Found ${#mirrors[@]} mirror(s):"
  printf '    %s\n' "${mirrors[@]}"

  step "Triggering sync on all mirrors"

  failed=()
  for repo in "${mirrors[@]}"; do
    if forgejo_trigger_sync "$repo" 2>/dev/null; then
      ok "  ${repo}"
    else
      warn "  ${repo} — sync request failed"
      failed+=("$repo")
    fi
  done

  echo ""
  if [[ ${#failed[@]} -eq 0 ]]; then
    ok "All ${#mirrors[@]} mirror(s) queued for sync."
  else
    warn "${#failed[@]} repo(s) failed: ${failed[*]}"
    exit 1
  fi
fi

info ""
info "Forgejo re-syncs mirrors automatically every 1 minute."
info "Monitor mirrors: ${FORGEJO_HOST}/-/admin/repos"
