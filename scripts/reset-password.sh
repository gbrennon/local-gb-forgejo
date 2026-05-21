#!/usr/bin/env bash
# reset-password.sh — Reset a Forgejo user password via admin CLI.
#
# Usage:
#   ./scripts/reset-password.sh                          # Interactive mode
#   ./scripts/reset-password.sh --user alice --password newpass  # Non-interactive
#   ./scripts/reset-password.sh --list                   # List all users
#   ./scripts/reset-password.sh --help                   # Show this help
#
# Requires: Forgejo container running, admin user in .env

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck disable=SC1090
source "${SCRIPT_DIR}/lib/common.sh"

# ---------------------------------------------------------------------------
# Runtime detection (simplified — no URL globals needed)
# ---------------------------------------------------------------------------
detect_runtime() {
  if podman info &>/dev/null 2>&1; then
    CONTAINER_RUNTIME="podman"
  elif docker info &>/dev/null 2>&1; then
    CONTAINER_RUNTIME="docker"
  else
    die "Neither podman nor docker daemon is reachable."
  fi
}

# ---------------------------------------------------------------------------
# ensure_forgejo_running
# ---------------------------------------------------------------------------
ensure_forgejo_running() {
  local status
  status=$($CONTAINER_RUNTIME inspect --format='{{.State.Status}}' forgejo 2>/dev/null) || \
    die "Forgejo container not found. Run ./scripts/bootstrap.sh first."

  if [[ "$status" != "running" ]]; then
    die "Forgejo container is not running (status: ${status}). Run: docker compose up -d"
  fi
}

# ---------------------------------------------------------------------------
# list_users
# ---------------------------------------------------------------------------
list_users() {
  info "Fetching user list from Forgejo..."
  local output exit_code=0
  output=$($CONTAINER_RUNTIME exec --user git forgejo \
    forgejo admin user list 2>&1) || exit_code=$?

  if [[ $exit_code -ne 0 ]]; then
    die "Failed to list users (exit ${exit_code}): ${output}"
  fi

  echo ""
  echo "$output"
  echo ""
  ok "User list retrieved"
}

# ---------------------------------------------------------------------------
# reset_password_interactive
# ---------------------------------------------------------------------------
reset_password_interactive() {
  echo ""
  echo "Forgejo Password Reset (Interactive Mode)"
  echo "=========================================="
  echo ""

  read -rp "Username: " username
  if [[ -z "$username" ]]; then
    die "Username cannot be empty."
  fi

  read -rsp "New password: " password
  echo ""
  if [[ -z "$password" ]]; then
    die "Password cannot be empty."
  fi

  read -rsp "Confirm password: " password_confirm
  echo ""
  if [[ "$password" != "$password_confirm" ]]; then
    die "Passwords do not match."
  fi

  reset_password "$username" "$password"
}

# ---------------------------------------------------------------------------
# reset_password <username> <password>
# ---------------------------------------------------------------------------
reset_password() {
  local username="$1"
  local password="$2"

  info "Resetting password for user '${username}'..."

  local output exit_code=0
  output=$($CONTAINER_RUNTIME exec --user git forgejo \
    forgejo admin user change-password \
      --username "${username}" \
      --password "${password}" 2>&1) || exit_code=$?

  if echo "$output" | grep -qi "error\|failed\|not found"; then
    die "Password reset failed: ${output}"
  fi

  if [[ $exit_code -ne 0 ]]; then
    die "Password reset failed (exit ${exit_code}): ${output}"
  fi

  [[ -n "$output" ]] && info "$output"
  ok "Password reset successfully for user '${username}'"
}

# ---------------------------------------------------------------------------
# usage
# ---------------------------------------------------------------------------
usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Reset a Forgejo user password via the admin CLI.

Options:
  --user <username>       Username to reset (required for non-interactive mode)
  --password <password>   New password (required for non-interactive mode)
  --list                  List all Forgejo users
  --help                  Show this help message

Examples:
  $(basename "$0")                                    # Interactive mode
  $(basename "$0") --user alice --password newpass    # Non-interactive
  $(basename "$0") --list                             # List all users

Notes:
  - Requires Forgejo container to be running
  - Uses admin credentials from .env file
  - Works with both podman and docker
EOF
  exit 0
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
main() {
  local username=""
  local password=""
  local action=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --user)
        username="${2:-}"
        [[ -n "$username" ]] || die "--user requires a value"
        shift 2
        ;;
      --password)
        password="${2:-}"
        [[ -n "$password" ]] || die "--password requires a value"
        shift 2
        ;;
      --list)
        action="list"
        shift
        ;;
      --help|-h)
        usage
        ;;
      *)
        die "Unknown option: ${1}. Use --help for usage."
        ;;
    esac
  done

  load_env
  detect_runtime
  ensure_forgejo_running

  if [[ "$action" == "list" ]]; then
    list_users
    exit 0
  fi

  if [[ -n "$username" && -n "$password" ]]; then
    reset_password "$username" "$password"
  elif [[ -z "$username" && -z "$password" ]]; then
    reset_password_interactive
  else
    die "Both --user and --password are required for non-interactive mode. Use --help for usage."
  fi
}

main "$@"
