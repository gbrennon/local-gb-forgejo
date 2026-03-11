#!/usr/bin/env bash
# watch-mirrors.sh — Daemon that continuously syncs Forgejo mirrors,
# reports live Forgejo Actions run status, and posts commit statuses
# back to GitHub so results appear on GitHub commits and PRs.
#
# Flow:
#   GitHub push → watcher fetches + pushes to Forgejo (this script)
#     → Forgejo receives real push event → Forgejo Actions fires
#     → watcher reads result → GitHub Commit Status API
#
# Why git push and not mirror-sync: Forgejo pull mirror syncs do NOT fire
# push events, so Actions never trigger. Real git pushes do.
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
# shellcheck source=lib/git-sync.sh
source "${SCRIPT_DIR}/lib/git-sync.sh"
# shellcheck source=lib/github-api.sh
source "${SCRIPT_DIR}/lib/github-api.sh"

# ---------------------------------------------------------------------------
# PID lock — only one instance may run at a time.
# Placing the lock file at the repo root keeps it visible alongside watcher.log.
# ---------------------------------------------------------------------------
WATCHER_PID_FILE="${SCRIPT_DIR}/../watcher.pid"
if [[ -f "$WATCHER_PID_FILE" ]]; then
  _existing_pid=$(cat "$WATCHER_PID_FILE")
  if kill -0 "$_existing_pid" 2>/dev/null; then
    echo "watch-mirrors.sh is already running (PID ${_existing_pid}). Exiting." >&2
    exit 1
  fi
fi
echo $$ > "$WATCHER_PID_FILE"

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
    success)   echo "OK  " ;;
    failure)   echo "FAIL" ;;
    running)   echo "... " ;;
    waiting)   echo "... " ;;
    cancelled) echo "skip" ;;
    skipped)   echo "-   " ;;
    *)         echo "?   " ;;
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
# key format: "<sha>:<context>:<gh_state>"
# Including the gh_state in the key means a status change (e.g. failure →
# success after a re-run) will be re-posted to GitHub.
# ---------------------------------------------------------------------------
_state_has_key() {
  grep -qF "$1" "$STATE_FILE" 2>/dev/null
}

_state_remove_context() {
  # Remove all entries for a given "sha:context" prefix regardless of state.
  if [[ -f "$STATE_FILE" ]]; then
    grep -vF "$1:" "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE" || true
  fi
}

_state_write() {
  local context_key="$1"  # sha:context
  local gh_state="$2"
  _state_remove_context "$context_key"
  echo "${context_key}:${gh_state}" >> "$STATE_FILE"
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
# Tracks reported statuses to avoid duplicate API calls. Re-posts if the
# status changes (e.g. failure → success after a re-run).
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
  runs=$(forgejo_list_recent_runs "$forgejo_repo" 20)
  if [[ "$runs" == "no_runs" ]] || [[ -z "$runs" ]]; then return 0; fi

  _state_prune

  local posted=0
  while IFS=$'\t' read -r status name branch sha run_url _task_id; do
    if [[ -z "$sha" ]]; then continue; fi

    local gh_state
    gh_state=$(forgejo_to_github_state "$status")
    if [[ -z "$gh_state" ]]; then continue; fi

    # Key includes the gh_state so a changed outcome (failure → success) re-posts.
    local context_key="${sha}:forgejo/${name}"
    local full_key="${context_key}:${gh_state}"

    # Skip only if this exact (sha, context, state) combo was already posted.
    if _state_has_key "$full_key"; then continue; fi

    local description="${name}: ${status}"
    if github_post_commit_status "$github_slug" "$sha" "$gh_state" \
        "forgejo/${name}" "$description"; then
      _state_write "$context_key" "$gh_state"
      posted=$((posted + 1))
    fi
  done <<< "$runs"

  if [[ $posted -gt 0 ]]; then
    printf '         -> %d GitHub status(es) posted (%s)\n' "$posted" "$github_slug"
  fi
}

# ---------------------------------------------------------------------------
# print_run_status <repo>
# Shows the last few Forgejo Actions runs for the repo.
# For failed runs, prints the Forgejo UI URL so the user can inspect logs.
# ---------------------------------------------------------------------------
print_run_status() {
  local repo="$1"
  local runs
  runs=$(forgejo_list_recent_runs "$repo" 5)

  if [[ "$runs" == "no_runs" ]] || [[ -z "$runs" ]]; then
    printf '         .  no action runs yet\n'
    return
  fi

  while IFS=$'\t' read -r status name branch sha run_url task_id; do
    local icon short_sha
    icon=$(run_icon "$status")
    short_sha="${sha:0:7}"
    # Prefix with [CI] to make clear this is a Forgejo Actions job result, not a script error
    printf '         [CI] %s  %-10s  %-30s  %s @ %s\n' "$icon" "$status" "$name" "$short_sha" "$branch"

    if [[ "$status" == "failure" || "$status" == "error" ]]; then
      if [[ -n "$task_id" ]]; then
        local log_tail
        log_tail=$(forgejo_get_task_log_tail "$repo" "$task_id" 6 2>/dev/null || true)
        if [[ -n "$log_tail" ]]; then
          while IFS= read -r log_line; do
            printf '               |  %s\n' "$log_line"
          done <<< "$log_tail"
        fi
      fi
      if [[ -n "$run_url" ]]; then
        printf '               \\- logs: %s\n' "$run_url"
      fi
    fi
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
    # Include both push repos (managed by this toolchain) and legacy pull mirrors.
    # Pull mirrors are flagged with a warning; push repos use git_push_sync.
    { forgejo_list_push_repos; forgejo_list_mirrors; } | sort -u
  fi
}

# ---------------------------------------------------------------------------
# sync_cycle <cycle_number>
# Syncs all repos and prints status.
# ---------------------------------------------------------------------------
sync_cycle() {
  local cycle="$1"
  local timestamp
  timestamp=$(date '+%Y-%m-%d %H:%M:%S')

  local push_repos mirror_repos
  push_repos=$(forgejo_list_push_repos)
  mirror_repos=$(forgejo_list_mirrors)

  local all_repos=()
  while IFS= read -r r; do [[ -n "$r" ]] && all_repos+=("$r"); done <<< "$push_repos"
  while IFS= read -r r; do [[ -n "$r" ]] && all_repos+=("$r"); done <<< "$mirror_repos"

  if [[ ${#all_repos[@]} -eq 0 ]]; then
    warn "No repos found. Use ./scripts/mirror-repo.sh <org> <repo> to add one."
    return
  fi

  local push_count=0
  [[ -n "$push_repos" ]] && push_count=$(echo "$push_repos" | grep -c .) || push_count=0

  echo ""
  echo "--------------------------------------------------------"
  echo "  ${timestamp}  |  Cycle #${cycle}  |  ${#all_repos[@]} repo(s)"
  echo "--------------------------------------------------------"

  local failed=()
  declare -A fail_msgs=()
  for repo in "${all_repos[@]}"; do
    # Pull mirrors: Forgejo does not fire push events on mirror syncs so Actions
    # never trigger. Auto-convert in place: delete the mirror and recreate as a
    # regular repo under the same owner, then push from GitHub.
    if echo "$mirror_repos" | grep -qx "$repo"; then
      printf '    [..] %-32s pull mirror detected - auto-converting to push repo\n' "$repo"
      local conv_slug
      conv_slug=$(forgejo_convert_mirror_to_push "$repo" 2>&1) || {
        printf '    [!!] %-32s conversion failed: %s\n' "$repo" "$conv_slug" >&2
        failed+=("$repo")
        fail_msgs["$repo"]="$conv_slug"
        continue
      }
      printf '    [OK] %-32s converted - pushing from github.com/%s\n' "$repo" "$conv_slug"
      local push_out
      push_out=$(git_init_push "$repo" "$conv_slug" 2>&1) || {
        printf '    [!!] %-32s initial push failed: %s\n' "$repo" "$push_out" >&2
        failed+=("$repo")
        fail_msgs["$repo"]="$push_out"
        continue
      }
      printf '    [OK] %-32s push complete - waiting for Actions to queue\n' "$repo"
      sleep 4
      print_run_status "$repo"
      report_runs_to_github "$repo" || true
      continue
    fi

    local github_slug sync_info
    github_slug=$(forgejo_get_mirror_source "$repo")
    local source_label="${github_slug:-unknown}"

    sync_info=$(git_push_sync "$repo" 2>&1) || {
      printf '    [!!] %-32s sync failed  <-  %s\n' "$repo" "$source_label" >&2
      fail_msgs["$repo"]="$sync_info"
      failed+=("$repo")
      continue
    }

    printf '    [OK] %-32s %s  <-  %s\n' "$repo" "$sync_info" "$source_label"

    runs=$(forgejo_list_recent_runs "$repo" 5)
    if [[ "$runs" == "no_runs" || -z "$runs" ]]; then
      sleep 3
      runs=$(forgejo_list_recent_runs "$repo" 5)
    fi
    if [[ "$runs" == "no_runs" || -z "$runs" ]]; then
      printf '         .  no action runs yet - check that workflow files exist in .forgejo/workflows/ or .github/workflows/\n'
    else
      print_run_status "$repo"
      report_runs_to_github "$repo" || true
    fi
  done

  if [[ ${#failed[@]} -gt 0 ]]; then
    warn "Failed: ${failed[*]}"
    for r in "${failed[@]}"; do
      msg="${fail_msgs[$r]:-no details available}"
      printf '    [DETAIL] %-32s %s\n' "$r" "$(echo "$msg" | tr '\n' ' ' | cut -c1-400)" >&2
    done
  fi
}

# ---------------------------------------------------------------------------
# Shutdown handler
# ---------------------------------------------------------------------------
on_exit() {
  rm -f "$WATCHER_PID_FILE"
  echo ""
  echo "==> Watcher stopped."
  echo "    Run ./scripts/watch-mirrors.sh to restart the daemon."
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
  sync_cycle "$cycle" || true  # never let a failed cycle kill the watcher

  if [[ "$RUN_ONCE" == true ]]; then
    break
  fi

  printf '\n  next sync in %ds\n' "$INTERVAL"
  sleep "$INTERVAL"
done
