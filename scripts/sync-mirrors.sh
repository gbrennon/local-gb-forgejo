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
# shellcheck source=lib/git-sync.sh
source "${SCRIPT_DIR}/lib/git-sync.sh"

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
  step "Syncing repo: ${TARGET_REPO}"
  if git_push_sync "$TARGET_REPO"; then
    ok "Sync complete for ${TARGET_REPO}"
  else
    warn "Sync failed — check that ${TARGET_REPO} is a push repo (not a pull mirror)."
    warn "Convert pull mirrors with: ./scripts/mirror-repo.sh <org> ${TARGET_REPO##*/}"
    exit 1
  fi

else
  # ---------------------------------------------------------------------------
  # Discover and sync all mirrors
  # ---------------------------------------------------------------------------
  step "Discovering repos to sync"

  # Merge push repos and legacy pull mirrors; warn on pull mirrors.
  mapfile -t all_repos < <({ forgejo_list_push_repos; forgejo_list_mirrors; } | sort -u)

  if [[ ${#all_repos[@]} -eq 0 ]]; then
    warn "No repos found. Use ./scripts/mirror-repo.sh <org> <repo> to add one."
    exit 0
  fi

  ok "Found ${#all_repos[@]} repo(s):"
  printf '    %s\n' "${all_repos[@]}"

  step "Syncing all repos"

  failed=()
  for repo in "${all_repos[@]}"; do
    is_mirror=$(curl -sf -u "${AUTH}" "${FORGEJO_HOST}/api/v1/repos/${repo}" \
      | python3 -c "import sys,json; print(json.load(sys.stdin).get('mirror', False))" 2>/dev/null || echo "false")
    if [[ "$is_mirror" == "True" ]]; then
      step "  ${repo} — pull mirror: attempting mirror-sync via Forgejo API"
      if mirror_resp=$(forgejo_trigger_sync "$repo" 2>&1); then
        ok "  ${repo} — mirror-sync requested"
        # show branches if any
        mapfile -t branches < <(forgejo_list_branches "$repo")
        if [[ ${#branches[@]} -gt 0 ]]; then
          printf '    branches: %s\n' "${branches[*]}"
        else
          printf '    branches: none\n'
        fi
      else
        warn "  ${repo} — mirror-sync failed: ${mirror_resp}";
        failed+=("$repo")
      fi
      continue
    fi

    sync_out=$(git_push_sync "$repo" 2>&1) || {
      warn "  ${repo} — sync failed: $(echo "$sync_out" | tr '\n' ' ' | cut -c1-300)"
      failed+=("$repo")
      continue
    }
    ok "  ${repo} — ${sync_out}"
  done

  echo ""
  if [[ ${#failed[@]} -eq 0 ]]; then
    ok "All ${#all_repos[@]} repo(s) synced."
  else
    warn "${#failed[@]} repo(s) failed: ${failed[*]}"
    exit 1
  fi
fi

info ""
info "watch-mirrors.sh re-syncs repos automatically every 1 minute via git push."
info "Monitor mirrors: ${FORGEJO_HOST}/-/admin/repos"
