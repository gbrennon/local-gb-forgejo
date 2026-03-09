#!/usr/bin/env bash
# mirror-repo.sh — Register a GitHub repository as a 1-minute mirror in Forgejo.
#
# Usage: ./scripts/mirror-repo.sh <github_org> <repo>
#
# This is idempotent: safe to re-run if the mirror already exists.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/forgejo-api.sh
source "${SCRIPT_DIR}/lib/forgejo-api.sh"

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
  cat <<EOF
Usage: $(basename "$0") <org> <repo>

Register a GitHub repository as a mirror in the local Forgejo instance.
The mirror syncs automatically every 1 minute.

Arguments:
  org   GitHub organization or username that owns the repository
  repo  Repository name on GitHub

Required variables in .env:
  FORGEJO_ADMIN_USER      Forgejo admin username
  FORGEJO_ADMIN_PASSWORD  Forgejo admin password
  GITHUB_PAT              GitHub Personal Access Token (repo scope)
                          Create at: https://github.com/settings/tokens/new

Steps performed:
  1. Verify Forgejo is healthy
  2. Create the GitHub mirror in Forgejo (idempotent)
  3. Trigger the first sync and verify branches are fetched
  4. List .github/workflows/ files present in the mirror
  5. Scan workflow files for required secrets
  6. Print the Actions tab URL

Examples:
  $(basename "$0") myorg myrepo
  $(basename "$0") octocat Hello-World
EOF
  exit 1
}

[[ $# -lt 2 ]] && usage

ORG="$1"
REPO="$2"

load_env

OWNER_REPO="${FORGEJO_ADMIN_USER}/${REPO}"

# ---------------------------------------------------------------------------
# Step 1 — Prerequisites
# ---------------------------------------------------------------------------
step "Step 1 — Verifying prerequisites"

require_forgejo

runner_status=$(podman logs forgejo-runner 2>&1 | grep "declared successfully" | tail -1 || true)
if [[ -n "$runner_status" ]]; then
  ok "Runner is online"
else
  warn "Could not confirm runner status. Check: podman logs forgejo-runner"
fi

# ---------------------------------------------------------------------------
# Step 2 — Create the mirror
# ---------------------------------------------------------------------------
step "Step 2 — Mirroring github.com/${ORG}/${REPO} into Forgejo"

result=$(forgejo_create_mirror "$ORG" "$REPO")
if [[ "$result" == "exists" ]]; then
  ok "Mirror already exists for ${OWNER_REPO}"
else
  ok "Mirror created: ${result}"
fi

# ---------------------------------------------------------------------------
# Step 3 — Trigger first sync and verify branches
# ---------------------------------------------------------------------------
step "Step 3 — Triggering first sync"

# Forgejo needs time after mirror creation to finish its internal setup
# before it accepts sync requests. Retry until the API accepts (up to 30s).
sync_ok=false
for _attempt in 1 2 3 4 5 6; do
  sleep 5
  if forgejo_trigger_sync "$OWNER_REPO" 2>/dev/null; then
    sync_ok=true
    break
  fi
  info "Waiting for mirror to become ready... (${_attempt}/6)"
done
if ! $sync_ok; then
  warn "Could not trigger sync — mirror may still be initializing."
  info "Trigger manually later: ./scripts/sync-mirrors.sh ${OWNER_REPO}"
else
  ok "Sync request sent"
  info "Waiting 15 seconds for sync to complete..."
  sleep 15
fi

mapfile -t branches < <(forgejo_list_branches "$OWNER_REPO")
if [[ ${#branches[@]} -gt 0 ]]; then
  ok "Branches fetched:"
  printf '    branch: %s\n' "${branches[@]}"
else
  warn "No branches found yet — sync may still be in progress."
  info "Trigger manually: ./scripts/sync-mirrors.sh ${OWNER_REPO}"
fi

# ---------------------------------------------------------------------------
# Step 4 — Confirm workflow files are present
# ---------------------------------------------------------------------------
step "Step 4 — Checking .github/workflows/"

mapfile -t workflow_files < <(forgejo_list_workflow_files "$OWNER_REPO")
if [[ ${#workflow_files[@]} -gt 0 ]]; then
  ok "Workflow files found:"
  printf '    %s\n' "${workflow_files[@]}"
else
  warn ".github/workflows/ not found or empty."
  info "For GitLab/Bitbucket mirrors, create .forgejo/workflows/ci.yml manually."
fi

# ---------------------------------------------------------------------------
# Step 5 — Scan for required secrets
# ---------------------------------------------------------------------------
step "Step 5 — Scanning workflow files for required secrets"

forgejo_scan_secrets "$OWNER_REPO"

# ---------------------------------------------------------------------------
# Step 6 — Summary
# ---------------------------------------------------------------------------
step "Step 6 — Done"
ok "Mirror:   ${FORGEJO_HOST}/${OWNER_REPO}"
ok "Actions:  ${FORGEJO_HOST}/${OWNER_REPO}/actions"
info ""
info "Mirror syncs automatically every 1 minute."
info "To trigger an immediate sync:"
info "  ./scripts/sync-mirrors.sh ${OWNER_REPO}"
