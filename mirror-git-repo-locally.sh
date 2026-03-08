#!/usr/bin/env bash
set -euo pipefail

FORGEJO_HOST="http://localhost:1234"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
  cat <<EOF
Usage: $(basename "$0") <org> <repo>

Mirror a GitHub repository into the local Forgejo instance and verify the
CI delegation chain is working end-to-end.

Arguments:
  org   GitHub organization or username that owns the repository
  repo  Repository name on GitHub

Required variables in .env (relative to this script):
  FORGEJO_ADMIN_USER      Forgejo admin username
  FORGEJO_ADMIN_PASSWORD  Forgejo admin password
  GITHUB_PAT              GitHub Personal Access Token with 'repo' scope
                          Create one at: https://github.com/settings/tokens/new

Example:
  $(basename "$0") myorg myrepo
  $(basename "$0") octocat Hello-World

Steps performed:
  1. Verify Forgejo and runner are healthy
  2. Create the GitHub mirror in Forgejo
  3. Trigger the first sync and verify branches were fetched
  4. List .github/workflows/ files present in the mirror
  5. List required secrets found in workflow files
  6. Print the Actions tab URL to monitor runs
EOF
  exit 1
}

# ---------------------------------------------------------------------------
# Require both positional arguments
# ---------------------------------------------------------------------------
if [[ $# -lt 2 ]]; then
  usage
fi

ORG="$1"
REPO="$2"

# ---------------------------------------------------------------------------
# Load .env
# ---------------------------------------------------------------------------
ENV_FILE="${SCRIPT_DIR}/.env"
if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: .env not found at ${ENV_FILE}" >&2
  echo "       Copy env.example to .env and fill in values." >&2
  exit 1
fi
set -a
source "$ENV_FILE"
set +a

# Validate required env vars
for var in FORGEJO_ADMIN_USER FORGEJO_ADMIN_PASSWORD GITHUB_PAT; do
  if [[ -z "${!var:-}" ]]; then
    echo "ERROR: ${var} is not set in .env" >&2
    exit 1
  fi
done

AUTH="${FORGEJO_ADMIN_USER}:${FORGEJO_ADMIN_PASSWORD}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
step() { echo ""; echo "==> $*"; }
ok()   { echo "    [OK] $*"; }
info() { echo "    [--] $*"; }
warn() { echo "    [!!] $*"; }

# ---------------------------------------------------------------------------
# Step 1 — Prerequisites
# ---------------------------------------------------------------------------
step "Step 1 — Verifying prerequisites"

if curl -sf "${FORGEJO_HOST}" >/dev/null; then
  ok "Forgejo is reachable at ${FORGEJO_HOST}"
else
  echo "ERROR: Forgejo is not responding at ${FORGEJO_HOST}. Run ./bootstrap.sh first." >&2
  exit 1
fi

runner_status=$(podman logs forgejo-runner 2>&1 | grep "declared successfully" | tail -1 || true)
if [[ -n "$runner_status" ]]; then
  ok "Runner is online: ${runner_status}"
else
  warn "Could not confirm runner status. Check: podman logs forgejo-runner"
fi

# ---------------------------------------------------------------------------
# Step 2 — Create the mirror
# ---------------------------------------------------------------------------
step "Step 2 — Mirroring github.com/${ORG}/${REPO} into Forgejo"

response=$(curl -s -X POST \
  -u "${AUTH}" \
  -H "Content-Type: application/json" \
  "${FORGEJO_HOST}/api/v1/repos/migrate" \
  -d "{
    \"clone_addr\": \"https://github.com/${ORG}/${REPO}.git\",
    \"auth_token\": \"${GITHUB_PAT}\",
    \"mirror\": true,
    \"mirror_interval\": \"1m\",
    \"repo_name\": \"${REPO}\",
    \"repo_owner\": \"${FORGEJO_ADMIN_USER}\",
    \"service\": \"github\",
    \"private\": false
  }")

http_name=$(echo "$response" | python3 -c "import sys,json; r=json.load(sys.stdin); print(r.get('full_name',''))" 2>/dev/null || true)
error_msg=$(echo "$response" | python3 -c "import sys,json; r=json.load(sys.stdin); print(r.get('message',''))" 2>/dev/null || true)

if [[ -n "$http_name" ]]; then
  ok "Mirror created: ${http_name}"
elif echo "$error_msg" | grep -qi "already exist"; then
  ok "Mirror already exists for ${FORGEJO_ADMIN_USER}/${REPO}"
else
  echo "ERROR: Failed to create mirror." >&2
  echo "       Response: ${response}" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Step 3 — Trigger first sync and verify branches
# ---------------------------------------------------------------------------
step "Step 3 — Triggering first sync"

curl -s -X POST \
  -u "${AUTH}" \
  "${FORGEJO_HOST}/api/v1/repos/${FORGEJO_ADMIN_USER}/${REPO}/mirror-sync" >/dev/null
ok "Sync request sent"

info "Waiting 15 seconds for sync to complete..."
sleep 15

branches=$(curl -s \
  -u "${AUTH}" \
  "${FORGEJO_HOST}/api/v1/repos/${FORGEJO_ADMIN_USER}/${REPO}/branches" \
  | python3 -c "import sys,json; bs=json.load(sys.stdin); [print('    branch:', b['name']) for b in bs]" 2>/dev/null || true)

if [[ -n "$branches" ]]; then
  ok "Branches fetched:"
  echo "$branches"
else
  warn "No branches found yet. The sync may still be in progress."
  info "Re-run this script or trigger manually:"
  info "  curl -s -X POST -u '${AUTH}' ${FORGEJO_HOST}/api/v1/repos/${FORGEJO_ADMIN_USER}/${REPO}/mirror-sync"
fi

# ---------------------------------------------------------------------------
# Step 4 — Confirm workflow files are present
# ---------------------------------------------------------------------------
step "Step 4 — Checking .github/workflows/"

workflow_files=$(curl -s \
  -u "${AUTH}" \
  "${FORGEJO_HOST}/api/v1/repos/${FORGEJO_ADMIN_USER}/${REPO}/contents/.github/workflows" \
  | python3 -c "import sys,json; fs=json.load(sys.stdin); [print('    ' + f['name']) for f in (fs if isinstance(fs,list) else [])]" 2>/dev/null || true)

if [[ -n "$workflow_files" ]]; then
  ok "Workflow files found:"
  echo "$workflow_files"
else
  warn ".github/workflows/ not found or empty."
  info "If this is a GitLab/Bitbucket mirror, create .forgejo/workflows/ci.yml manually."
  info "See docs/delegate-github-actions-to-forgejo.md — Step 5 and Troubleshooting."
fi

# ---------------------------------------------------------------------------
# Step 5 — Scan for required secrets
# ---------------------------------------------------------------------------
step "Step 5 — Scanning workflow files for required secrets"

tmp_clone=$(mktemp -d)
trap 'rm -rf "$tmp_clone"' EXIT

git clone --quiet \
  "http://${FORGEJO_ADMIN_USER}:${FORGEJO_ADMIN_PASSWORD}@localhost:1234/${FORGEJO_ADMIN_USER}/${REPO}.git" \
  "${tmp_clone}/${REPO}" 2>/dev/null || true

if [[ -d "${tmp_clone}/${REPO}/.github/workflows" ]]; then
  required_secrets=$(grep -r 'secrets\.' "${tmp_clone}/${REPO}/.github/workflows/" \
    | grep -o 'secrets\.[A-Za-z_][A-Za-z0-9_]*' \
    | sort -u || true)

  if [[ -n "$required_secrets" ]]; then
    warn "The following secrets are referenced in workflow files and must be added to Forgejo:"
    while IFS= read -r s; do
      secret_name="${s#secrets.}"
      info "  curl -s -X PUT -u '${AUTH}' -H 'Content-Type: application/json' \\"
      info "    '${FORGEJO_HOST}/api/v1/repos/${FORGEJO_ADMIN_USER}/${REPO}/actions/secrets/${secret_name}' \\"
      info "    -d '{\"data\": \"YOUR_VALUE\"}'"
    done <<< "$required_secrets"
  else
    ok "No secrets.* references found in workflow files"
  fi
else
  info "No .github/workflows/ directory to scan"
fi

# ---------------------------------------------------------------------------
# Step 6 — Summary
# ---------------------------------------------------------------------------
step "Step 6 — Done"
ok "Mirror:   ${FORGEJO_HOST}/${FORGEJO_ADMIN_USER}/${REPO}"
ok "Actions:  ${FORGEJO_HOST}/${FORGEJO_ADMIN_USER}/${REPO}/actions"
info ""
info "To monitor runner activity:"
info "  podman logs -f forgejo-runner"
info ""
info "To trigger a sync at any time:"
info "  curl -s -X POST -u '${AUTH}' ${FORGEJO_HOST}/api/v1/repos/${FORGEJO_ADMIN_USER}/${REPO}/mirror-sync"
info ""
info "Mirror interval is set to 1 minute — Forgejo will auto-sync every 60 seconds."
