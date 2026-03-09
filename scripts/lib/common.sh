#!/usr/bin/env bash
# Shared utilities: logging, .env loading, Forgejo health check.
# Source this file from any script under scripts/.

# Resolve the repository root (two levels up from scripts/lib/)
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

FORGEJO_HOST="${FORGEJO_HOST:-http://localhost:1234}"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
step() { echo ""; echo "==> $*"; }
ok()   { echo "    [OK] $*"; }
info() { echo "    [--] $*"; }
warn() { echo "    [!!] $*" >&2; }
die()  { echo "ERROR: $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# load_env
# Sources .env from the repository root and validates required variables.
# Sets AUTH="${FORGEJO_ADMIN_USER}:${FORGEJO_ADMIN_PASSWORD}".
# ---------------------------------------------------------------------------
load_env() {
  local env_file="${REPO_ROOT}/.env"
  [[ -f "$env_file" ]] || die ".env not found at ${env_file}. Copy env.example to .env and fill in values."

  set -a
  # shellcheck disable=SC1090
  source "$env_file"
  set +a

  for var in FORGEJO_ADMIN_USER FORGEJO_ADMIN_PASSWORD GITHUB_PAT; do
    [[ -n "${!var:-}" ]] || die "${var} is not set in .env"
  done

  AUTH="${FORGEJO_ADMIN_USER}:${FORGEJO_ADMIN_PASSWORD}"
}

# ---------------------------------------------------------------------------
# require_forgejo
# Exits with a clear message if Forgejo is not reachable.
# ---------------------------------------------------------------------------
require_forgejo() {
  curl -sf "${FORGEJO_HOST}" >/dev/null \
    || die "Forgejo is not responding at ${FORGEJO_HOST}. Run ./bootstrap.sh first."
  ok "Forgejo is reachable at ${FORGEJO_HOST}"
}
