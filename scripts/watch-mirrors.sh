#!/usr/bin/env bash
# watch-mirrors.sh — Daemon that continuously syncs Forgejo mirrors,
# reports live Forgejo Actions run status, and posts commit statuses
# back to GitHub so results appear on GitHub commits and PRs.
#
# Flow:
#   GitHub push → mirror-sync (this script) → Forgejo detects change
#     → Forgejo Actions fires → watcher reads result → GitHub Commit Status API
#
# Usage:
#   ./scripts/watch-mirrors.sh                   # watch ALL mirrors, 60s interval
#   ./scripts/watch-mirrors.sh -i 30             # custom interval in seconds
#   ./scripts/watch-mirrors.sh -r repo1,repo2    # watch specific repos only
#   ./scripts/watch-mirrors.sh --once            # single sync cycle then exit

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/forgejo-api.sh
source "${SCRIPT_DIR}/lib/forgejo-api.sh"
# shellcheck source=lib/github-api.sh
source "${SCRIPT_DIR}/lib/github-api.sh"

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
INTERVAL=60
REPOS_FILTER=""   # empty = all mirrors
RUN_ONCE=false

# Tracks which (sha:context) pairs have already been reported to GitHub.
# Format per line: "sha:context:pending" or "sha:context:done"
# "pending" entries may be upgraded to "done" in subsequent cycles.
STATE_FILE="${SCRIPT_DIR}/../runner-data/gh-status-reported.txt"

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Continuously sync Forgejo mirrors and report Forgejo Actions run status.
Forgejo picks up new commits from GitHub and fires Actions workflows automatically.

Options:
  -i <seconds>      Sync interval in seconds (default: 60)
  -r <repo[,repo]>  Comma-separated list of repos to watch (default: all mirrors)
  --once            Run a single sync cycle then exit
  -h, --help        Show this help

Examples:
  $(basename "$0")                       # watch every mirror, 60s cycle
  $(basename "$0") -i 30                 # sync every 30 seconds
  $(basename "$0") -r my-api,my-frontend # watch specific repos
  $(basename "$0") --once                # one-shot sync of all mirrors
EOF
  exit 0
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -i) INTERVAL="$2"; shift 2 ;;
    -r) REPOS_FILTER="$2"; shift 2 ;;
    --once) RUN_ONCE=true; shift ;;
    -h|--help) usage ;;
    *) die "Unknown option: $1. Run with --help for usage." ;;
  esac
done

# ---------------------------------------------------------------------------
# Status icon helpers
# ---------------------------------------------------------------------------
run_icon() {
  case "$1" in
    success)   echo "✓" ;;
    failure)   echo "✗" ;;
    running)   echo "⟳" ;;
    waiting)   echo "…" ;;
    cancelled) echo "⊘" ;;
    skipped)   echo "−" ;;
    *)         echo "?" ;;
  esac
}

# ---------------------------------------------------------------------------
# forgejo_to_github_state <forgejo_status>
# Maps Forgejo run status to GitHub commit status state.
# Prints empty string for statuses that should not be reported (e.g. skipped).
# ---------------------------------------------------------------------------
forgejo_to_github_state() {
  case "$1" in
    success)            echo "success" ;;
    failure)            echo "failure" ;;
    cancelled|error)    echo "error" ;;
    waiting|running)    echo "pending" ;;
    *)                  echo "" ;;   # skipped → do not report
  esac
}

# ---------------------------------------------------------------------------
# is_final_gh_state <forgejo_status>
# Returns 0 if the status is terminal (will not change again).
# ---------------------------------------------------------------------------
is_final_gh_state() {
  case "$1" in
    success|failure|cancelled) return 0 ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# State file helpers
# key format: "<sha>:<context>"
# ---------------------------------------------------------------------------
_state_has_done() {
  grep -qF "$1:done" "$STATE_FILE" 2>/dev/null
}
_state_has_any() {
  grep -qF "$1:" "$STATE_FILE" 2>/dev/null
}
_state_remove() {
  if [[ -f "$STATE_FILE" ]]; then
    grep -vF "$1:" "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE" || true
  fi
}
_state_write() {
  _state_remove "$1"
  echo "$1:$2" >> "$STATE_FILE"
}
_state_prune() {
  # Keep only the last 1000 lines so the file never grows unbounded.
  if [[ -f "$STATE_FILE" ]] && [[ "$(wc -l < "$STATE_FILE")" -gt 1000 ]]; then
    tail -500 "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
  fi
}

# ---------------------------------------------------------------------------
# report_runs_to_github <forgejo_owner/repo>
# Reads recent Forgejo Actions runs and posts their status to GitHub.
# Tracks reported statuses to avoid duplicate API calls.
# Never propagates errors — failures are silently skipped so the watcher
# loop stays alive regardless of GitHub API availability.
# ---------------------------------------------------------------------------
report_runs_to_github() {
  local forgejo_repo="$1"

  github_has_pat || return 0

  local github_slug
  github_slug=$(forgejo_get_mirror_source "$forgejo_repo")
  if [[ -z "$github_slug" ]]; then return 0; fi

  local runs
  runs=$(forgejo_list_recent_runs "$forgejo_repo" 10)
  if [[ "$runs" == "no_runs" ]] || [[ -z "$runs" ]]; then return 0; fi

  _state_prune

  local posted=0
  while IFS=$'\t' read -r status name branch sha; do
    if [[ -z "$sha" ]]; then continue; fi

    local gh_state
    gh_state=$(forgejo_to_github_state "$status")
    if [[ -z "$gh_state" ]]; then continue; fi

    local key="${sha}:forgejo/${name}"

    if is_final_gh_state "$status"; then
      if _state_has_done "$key"; then continue; fi
      if github_post_commit_status "$github_slug" "$sha" "$gh_state" \
          "forgejo/${name}" "${name}: ${status}"; then
        _state_write "$key" "done"
        posted=$((posted + 1))
      fi
    else
      if _state_has_any "$key"; then continue; fi
      github_post_commit_status "$github_slug" "$sha" "pending" \
        "forgejo/${name}" "${name}: ${status}" || true
      _state_write "$key" "pending"
      posted=$((posted + 1))
    fi
  done <<< "$runs"

  if [[ $posted -gt 0 ]]; then
    printf '         → %d status(es) posted to GitHub\n' "$posted"
  fi
}

# ---------------------------------------------------------------------------
# print_run_status <repo>
# Shows the last few Forgejo Actions runs for the repo.
# ---------------------------------------------------------------------------
print_run_status() {
  local repo="$1"
  local runs
  runs=$(forgejo_list_recent_runs "$repo" 3)

  if [[ "$runs" == "no_runs" ]] || [[ -z "$runs" ]]; then
    return
  fi

  while IFS=$'\t' read -r status name branch sha; do
    local icon short_sha
    icon=$(run_icon "$status")
    short_sha="${sha:0:7}"
    printf '         %s  %-10s  %s  (%s@%s)\n' "$icon" "$status" "$name" "$branch" "$short_sha"
  done <<< "$runs"
}

# ---------------------------------------------------------------------------
# resolve_repos
# Resolves the working list of repos: explicit filter or all mirrors.
# ---------------------------------------------------------------------------
resolve_repos() {
  if [[ -n "$REPOS_FILTER" ]]; then
    tr ',' '\n' <<< "$REPOS_FILTER"
  else
    forgejo_list_mirrors
  fi
}

# ---------------------------------------------------------------------------
# sync_cycle <cycle_number>
# Syncs all repos and prints status.
# ---------------------------------------------------------------------------
sync_cycle() {
  local cycle="$1"
  local timestamp
  timestamp=$(date '+%H:%M:%S')

  mapfile -t repos < <(resolve_repos)

  if [[ ${#repos[@]} -eq 0 ]]; then
    warn "No mirrors found. Use ./scripts/mirror-repo.sh <org> <repo> to add one."
    return
  fi

  echo ""
  echo "==> [${timestamp}] Cycle #${cycle} — ${#repos[@]} mirror(s)"

  local failed=()
  for repo in "${repos[@]}"; do
    if forgejo_trigger_sync "$repo" 2>/dev/null; then
      printf '    [OK] %-30s synced\n' "$repo"
      print_run_status "$repo"
      report_runs_to_github "$repo" || true
    else
      printf '    [!!] %-30s sync failed\n' "$repo" >&2
      failed+=("$repo")
    fi
  done

  if [[ ${#failed[@]} -gt 0 ]]; then
    warn "Failed to sync: ${failed[*]}"
  fi
}

# ---------------------------------------------------------------------------
# Shutdown handler
# ---------------------------------------------------------------------------
on_exit() {
  echo ""
  echo "==> Watcher stopped."
  echo "    Forgejo continues syncing automatically every 1 minute via mirror_interval."
  echo "    Actions UI: ${FORGEJO_HOST}/-/admin/runners"
}
trap on_exit EXIT INT TERM

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
load_env

echo ""
echo "==> Forgejo Mirror Watcher"
echo "    Host:     ${FORGEJO_HOST}"
echo "    Interval: ${INTERVAL}s"
if [[ -n "$REPOS_FILTER" ]]; then
  echo "    Repos:    ${REPOS_FILTER}"
else
  echo "    Repos:    all mirrors"
fi
if github_has_pat; then
  echo "    GitHub:   commit statuses enabled (PAT configured)"
else
  echo "    GitHub:   commit statuses disabled (set GITHUB_PAT in .env to enable)"
fi
echo "    Ctrl+C to stop"

require_forgejo

cycle=0

while true; do
  cycle=$((cycle + 1))
  sync_cycle "$cycle"

  if [[ "$RUN_ONCE" == true ]]; then
    break
  fi

  printf '\n    [--] Next sync in %ds...\n' "$INTERVAL"
  sleep "$INTERVAL"
done
