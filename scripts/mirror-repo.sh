#!/usr/bin/env bash
# mirror-repo.sh — Register a GitHub repository for push-based sync with Forgejo.
#
# Creates a regular Forgejo repo (not a pull mirror) and performs an initial
# git push from GitHub. Subsequent syncs are handled by watch-mirrors.sh, which
# pushes commits to Forgejo and triggers Forgejo Actions workflows.
#
# If a pull mirror already exists for the same repo, it is converted automatically
# (deleted and recreated as a regular repo — git history is preserved via push).
#
# Usage: ./scripts/mirror-repo.sh <github_org> <repo>
#
# This is idempotent: safe to re-run if the repo already exists.

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

OWNER_REPO="${ORG}/${REPO}"

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
step "Step 2 — Setting up github.com/${ORG}/${REPO} in Forgejo"

# If a pull mirror already exists, convert it to a push-based repo.
# Pull mirrors do not fire push events, so Actions never trigger on them.
existing_type=$(curl -sf -u "${AUTH}" "${FORGEJO_HOST}/api/v1/repos/${OWNER_REPO}" \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print('mirror' if d.get('mirror') else 'repo')" 2>/dev/null || echo "none")

if [[ "$existing_type" == "mirror" ]]; then
  warn "Pull mirror detected — converting to push-based repo (git history is preserved)..."
  forgejo_delete_repo "$OWNER_REPO"
  existing_type="none"
fi

result=$(forgejo_create_push_repo "$ORG" "$REPO")
if [[ "$result" == "exists" ]]; then
  ok "Repo already exists: ${OWNER_REPO}"
else
  ok "Repo created: ${result}"
fi

# Ensure Actions is enabled (create_push_repo does not set this automatically).
if forgejo_enable_actions "$OWNER_REPO"; then
  ok "Actions enabled for ${OWNER_REPO}"
else
  warn "Could not enable Actions for ${OWNER_REPO} — enable manually in repo Settings → Actions"
fi

# ---------------------------------------------------------------------------
# Step 3 — Trigger first sync and verify branches
# ---------------------------------------------------------------------------
step "Step 3 — Pushing branches and tags from GitHub to Forgejo"

if git_init_push "$OWNER_REPO" "${ORG}/${REPO}"; then
  ok "Push complete"
  # Poll for action runs (give Forgejo a short window to queue workflows)
  attempts=0
  runs=""
  while [[ $attempts -lt 6 ]]; do
    runs=$(forgejo_list_recent_runs "$OWNER_REPO" 5)
    if [[ "$runs" != "no_runs" && -n "$runs" ]]; then
      break
    fi
    attempts=$((attempts + 1))
    sleep 3
  done
  if [[ "$runs" == "no_runs" || -z "$runs" ]]; then
    warn "No action runs detected after initial push — dumping workflow diagnostics"
    for path in ".forgejo/workflows" ".github/workflows"; do
      mapfile -t wf < <(forgejo_list_workflow_files "$OWNER_REPO" "$path")
      if [[ ${#wf[@]} -gt 0 ]]; then
        ok "Found workflow files in $path:"
        for f in "${wf[@]}"; do
          printf '    %s\n' "$f"
          curl -sf -u "${AUTH}" "${FORGEJO_HOST}/api/v1/repos/${OWNER_REPO}/contents/${path}/${f}" \
            | python3 -c "import sys,json,base64; d=json.load(sys.stdin); print('\n'.join(base64.b64decode(d.get('content','')).decode().splitlines()[:30]))" 2>/dev/null || echo '      (could not fetch)'
        done
      fi
    done
    echo 'Raw runs API response:'
    curl -s -u "${AUTH}" "${FORGEJO_HOST}/api/v1/repos/${OWNER_REPO}/actions/tasks?limit=10" | sed -n '1,200p'
  else
    ok "Action runs detected after initial push:"
    while IFS=$'\t' read -r status name branch sha; do
      printf '    %s  %s @ %s\n' "$status" "$name" "$branch"
    done <<< "$runs"
  fi
else
  warn "Push failed — check your GITHUB_PAT and network connectivity."
  info "Retry manually: ./scripts/sync-mirrors.sh ${OWNER_REPO}"
fi

sleep 3  # give Forgejo time to index pushed refs before listing them
mapfile -t branches < <(forgejo_list_branches "$OWNER_REPO")
if [[ ${#branches[@]} -gt 0 ]]; then
  ok "Branches available:"
  printf '    branch: %s\n' "${branches[@]}"
else
  warn "No branches found — push may have failed silently."
fi

# ---------------------------------------------------------------------------
# Step 4 — Confirm workflow files are present
# ---------------------------------------------------------------------------
step "Step 4 — Checking workflow files"

mapfile -t wf_github < <(forgejo_list_workflow_files "$OWNER_REPO" ".github/workflows")
mapfile -t wf_forgejo < <(forgejo_list_workflow_files "$OWNER_REPO" ".forgejo/workflows")
workflow_files=("${wf_forgejo[@]}" "${wf_github[@]}")

if [[ ${#wf_forgejo[@]} -gt 0 ]]; then
  ok ".forgejo/workflows/ (Forgejo-native, takes precedence):"
  printf '    %s\n' "${wf_forgejo[@]}"
fi
if [[ ${#wf_github[@]} -gt 0 ]]; then
  ok ".github/workflows/ (GitHub Actions compat):"
  printf '    %s\n' "${wf_github[@]}"
fi
if [[ ${#workflow_files[@]} -eq 0 ]]; then
  warn "No workflow files found in .forgejo/workflows/ or .github/workflows/."
  info "Create .forgejo/workflows/ci.yml to define your CI pipeline."
fi

# ---------------------------------------------------------------------------
# Step 5 — Scan for required secrets
# ---------------------------------------------------------------------------
step "Step 5 — Scanning workflow files for required secrets"

forgejo_report_missing_secrets "$OWNER_REPO"

# ---------------------------------------------------------------------------
# Step 6 — Summary
# ---------------------------------------------------------------------------
step "Step 6 — Done"
ok "Mirror:   ${FORGEJO_HOST}/${OWNER_REPO}"
ok "Actions:  ${FORGEJO_HOST}/${OWNER_REPO}/actions"
info ""
info "Repo syncs automatically every 1 minute via watch-mirrors.sh."
info "To trigger an immediate sync:"
info "  ./scripts/sync-mirrors.sh ${OWNER_REPO}"
info ""
info "Each sync pushes new commits to Forgejo, which fires push events"
info "and triggers Forgejo Actions workflows automatically."
