# Feature Development Guide

How to add new features to this local Forgejo infrastructure project.
Every section follows the same pattern: where to put the code, what conventions
to respect, and a minimal working example you can copy.

---

## 1. Codebase Map

```
scripts/
  bootstrap.sh          # Orchestrates first-time setup; sources lib/common.sh
  mirror-repo.sh        # Top-level command: register one GitHub repo
  sync-mirrors.sh       # Top-level command: one-shot sync
  watch-mirrors.sh      # Daemon: continuous sync + GitHub status reporting
  pat-server.py         # (Python) PAT helper server

  lib/
    common.sh           # Logging helpers, load_env(), require_forgejo()
    forgejo-api.sh      # All Forgejo REST API calls
    github-api.sh       # All GitHub REST API calls
    git-sync.sh         # Bare-clone cache + git push logic

docker-compose.yml      # Service definitions (forgejo, forgejo-db, forgejo-runner)
env.example             # Template for .env
.forgejo/workflows/     # Forgejo-native CI workflows (override .github/workflows/)
.github/workflows/      # GitHub Actions-compatible workflows
```

The **lib/** files are pure function libraries — they define functions, never
call them.  Top-level scripts (`mirror-repo.sh`, `watch-mirrors.sh`, etc.)
source the libs they need and contain the `main` logic.

---

## 2. Adding a New Shell Script

### When to add a new top-level script

Create a new script whenever you need a new user-facing command with its own
`--help`, argument parsing, and step-by-step output (like `mirror-repo.sh`).
Shared helper logic goes in `lib/`; the script is the thin entry point.

### Template

```bash
#!/usr/bin/env bash
# my-feature.sh — One-line description of what this script does.
#
# Usage: ./scripts/my-feature.sh <arg1> [--flag]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Source every lib you need (order matters: common first)
# shellcheck source=lib/forgejo-api.sh
source "${SCRIPT_DIR}/lib/forgejo-api.sh"

usage() {
  cat <<EOF
Usage: $(basename "$0") <arg1> [--flag]

Short description of what this does.

Arguments:
  arg1   Explanation

Options:
  --flag  What it changes

Required variables in .env:
  FORGEJO_ADMIN_USER
  FORGEJO_ADMIN_PASSWORD
  GITHUB_PAT
EOF
  exit 1
}

[[ $# -lt 1 || "${1:-}" == "-h" || "${1:-}" == "--help" ]] && usage

ARG1="$1"

load_env          # always first: populates AUTH and validates .env
require_forgejo   # always second: exits early with a clear message if the server is down

step "Step 1 — doing the first thing"
# ... your logic ...
ok "Step 1 complete"

step "Step 2 — doing the second thing"
# ... your logic ...
ok "Done: ${FORGEJO_HOST}/${ARG1}"
```

### Checklist

- `set -euo pipefail` at the top.
- Source only what you need — `common.sh` is included transitively by every
  lib, so you do not need to source it explicitly if you source any lib.
- Call `load_env` before any API call.
- Call `require_forgejo` before any Forgejo API call.
- Use `step`, `ok`, `info`, `warn`, `die` from `lib/common.sh` for all output.
- Add a `usage()` function and handle `-h` / `--help`.
- Make it idempotent: running it twice must not break anything.

---

## 3. Adding a New Forgejo API Function

All Forgejo REST API calls live in `scripts/lib/forgejo-api.sh`.

### Conventions

| Convention | Detail |
|---|---|
| Naming | `forgejo_<verb>_<noun>` e.g. `forgejo_list_secrets`, `forgejo_create_webhook` |
| Auth | Always `-u "${AUTH}"` (set by `load_env` in `common.sh`) |
| Base URL | Always `${FORGEJO_HOST}/api/v1/...` |
| Error handling | Use `die` for unrecoverable errors; return empty string for "not found" |
| Output | Print results to stdout; diagnostic messages to stderr via `info`/`warn` |
| JSON parsing | Use inline `python3 -c "import sys,json; ..."` — no external deps |

### Example: adding `forgejo_list_secrets`

```bash
# ---------------------------------------------------------------------------
# forgejo_list_secrets <owner/repo>
# Prints the name of every Actions secret defined on a repository.
# ---------------------------------------------------------------------------
forgejo_list_secrets() {
  local owner_repo="$1"
  curl -sf \
    -u "${AUTH}" \
    "${FORGEJO_HOST}/api/v1/repos/${owner_repo}/actions/secrets" \
    | python3 -c "
import sys, json
for s in json.load(sys.stdin).get('data', []):
    print(s['name'])
" 2>/dev/null || true
}
```

### Example: adding `forgejo_create_webhook`

```bash
# ---------------------------------------------------------------------------
# forgejo_create_webhook <owner/repo> <target_url>
# Creates a push-event webhook on a Forgejo repository.
# Prints the numeric webhook ID, or "exists" if a webhook for that URL already exists.
# ---------------------------------------------------------------------------
forgejo_create_webhook() {
  local owner_repo="$1"
  local target_url="$2"

  # Check if a webhook with this URL already exists.
  local existing
  existing=$(curl -sf -u "${AUTH}" \
    "${FORGEJO_HOST}/api/v1/repos/${owner_repo}/hooks" \
    | python3 -c "
import sys,json
for h in json.load(sys.stdin):
    if h.get('config', {}).get('url') == '${target_url}':
        print('exists'); break
" 2>/dev/null || true)
  [[ "$existing" == "exists" ]] && echo "exists" && return 0

  local response
  response=$(curl -s -X POST \
    -u "${AUTH}" \
    -H "Content-Type: application/json" \
    "${FORGEJO_HOST}/api/v1/repos/${owner_repo}/hooks" \
    -d "{
      \"type\": \"forgejo\",
      \"active\": true,
      \"events\": [\"push\"],
      \"config\": {
        \"url\": \"${target_url}\",
        \"content_type\": \"json\"
      }
    }")

  local hook_id
  hook_id=$(echo "$response" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || true)
  [[ -n "$hook_id" ]] && echo "$hook_id" || die "Failed to create webhook. Response: ${response}"
}
```

---

## 4. Adding a New GitHub API Function

All GitHub REST API calls live in `scripts/lib/github-api.sh`.

### Conventions

| Convention | Detail |
|---|---|
| Naming | `github_<verb>_<noun>` |
| Auth | `-H "Authorization: token ${GITHUB_PAT}"` |
| Base URL | `${GITHUB_API}/...` (already set to `https://api.github.com`) |
| Guard | Always call `github_has_pat \|\| return 0` first so features degrade gracefully without a PAT |
| Slugs | Accept `owner/repo` as `$1` to stay consistent with existing functions |

### Example: adding `github_create_issue`

```bash
# ---------------------------------------------------------------------------
# github_create_issue <owner/repo> <title> <body>
# Creates an issue on a GitHub repository.
# Returns 0 on HTTP 201, 1 on error.
# ---------------------------------------------------------------------------
github_create_issue() {
  local github_slug="$1"
  local title="$2"
  local body="$3"

  github_has_pat || { warn "GITHUB_PAT not set — cannot create issue"; return 1; }

  local http_code
  http_code=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST \
    -H "Authorization: token ${GITHUB_PAT}" \
    -H "Content-Type: application/json" \
    "${GITHUB_API}/repos/${github_slug}/issues" \
    -d "{\"title\": \"${title}\", \"body\": \"${body}\"}")

  [[ "$http_code" == "201" ]]
}
```

---

## 5. Adding a New Environment Variable

1. **Add it to `env.example`** with a comment explaining what it is and where
   to get the value:

   ```bash
   # Slack webhook URL for CI notifications (optional).
   # Create at https://api.slack.com/apps → Incoming Webhooks.
   SLACK_WEBHOOK_URL=
   ```

2. **Validate it in `lib/common.sh`** if it is _required_ for the toolchain
   to work at all:

   ```bash
   # Inside load_env(), add to the required vars loop:
   for var in FORGEJO_ADMIN_USER FORGEJO_ADMIN_PASSWORD GITHUB_PAT SLACK_WEBHOOK_URL; do
   ```

   If it is _optional_, check it inline where it is used:

   ```bash
   [[ -n "${SLACK_WEBHOOK_URL:-}" ]] || { info "SLACK_WEBHOOK_URL not set — skipping notification"; return 0; }
   ```

3. **Never reference it directly in `bootstrap.sh`** without going through
   `load_env`. The `.env` file is loaded once; all scripts inherit the exported
   variables.

---

## 6. Adding a New Docker Service

Edit `docker-compose.yml`. Follow these conventions:

- Give the container a stable `container_name` (matches the service name).
- Use `restart: unless-stopped` for long-running services.
- Attach to the same named volume or a new one under the `volumes:` top-level
  key.
- Add a `healthcheck` if the service exposes an HTTP endpoint.
- Use `depends_on` with `condition: service_healthy` when your service needs
  another to be ready first.

### Example: adding a Redis cache service

```yaml
services:
  # ... existing services ...

  redis:
    image: redis:7-alpine
    container_name: redis
    restart: unless-stopped
    volumes:
      - redis_data:/data
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 5s
      timeout: 3s
      retries: 10

volumes:
  forgejo_data:
  forgejo_db_data:
  forgejo_runner_data:
  redis_data:          # ← add new volume here
```

After editing `docker-compose.yml`, apply the change:

```bash
docker compose up -d redis      # bring up only the new service
# or
docker compose up -d            # bring everything up
```

Add a bootstrap step in `bootstrap.sh` (see §7) if the new service needs
one-time initialisation (tokens, users, config).

---

## 7. Adding a Bootstrap Step

`bootstrap.sh` orchestrates first-time setup via a linear `main()` function.
Each step is a focused function defined above `main`.

### Pattern

```bash
# ---------------------------------------------------------------------------
# my_bootstrap_step
# One-line description.
# ---------------------------------------------------------------------------
my_bootstrap_step() {
  info "Running my bootstrap step..."
  # ...your idempotent setup logic...
  ok "My bootstrap step complete."
}

main() {
  load_env
  detect_runtime
  start_core_services
  wait_for_forgejo
  bootstrap_runner
  start_runner
  wait_for_runner
  validate_container
  my_bootstrap_step   # ← add your step here
  start_watcher
}
```

### Rules for bootstrap functions

- **Idempotent**: check first, act only if needed.  
  Pattern: `if already_done; then info "skipping"; return; fi`
- **Use the runtime globals** set by `detect_runtime`:  
  `$CONTAINER_RUNTIME`, `$COMPOSE`, `$FORGEJO_HOST_URL`, `$FORGEJO_INTERNAL_URL`
- **Never call `exit 1` directly** — use `die "message"` which already calls exit.
- **Order matters**: steps that depend on Forgejo being ready must come after
  `wait_for_forgejo`.

---

## 8. Adding a CI Workflow

Forgejo loads workflows from `.forgejo/workflows/` (preferred) or
`.github/workflows/`. Files in `.forgejo/workflows/` take precedence for repos
mirrored to this instance.

### Anatomy of a workflow

```yaml
# .forgejo/workflows/ci.yml
on: [push]               # trigger: push to any branch

jobs:
  build:
    runs-on: ubuntu-latest   # must match runner label (set in bootstrap.sh)
    steps:
      - uses: actions/checkout@v4
      - name: Run tests
        run: make test
```

### Runner labels

The runner is registered with labels `ubuntu-latest,linux/amd64` (see
`register_runner` in `bootstrap.sh`). Any workflow step with
`runs-on: ubuntu-latest` will be picked up automatically.

To add a custom label (e.g. `my-label`):

1. Update the `--labels` flag in `register_runner`:
   ```bash
   --labels ubuntu-latest,linux/amd64,my-label
   ```
2. Re-run `bash scripts/bootstrap.sh` to re-register (bootstrap is idempotent;
   it detects whether Forgejo data was reset and acts accordingly).

---

## 9. Adding a New Watcher Feature

`watch-mirrors.sh` is the sync daemon. Each sync cycle calls `sync_cycle`.
To add side-effects per cycle (e.g. post a Slack notification, write metrics):

1. Add a helper function in `watch-mirrors.sh` or in a new `lib/` file.
2. Call it from inside `sync_cycle` after the existing logic.
3. Source any new lib file at the top of `watch-mirrors.sh`.

### Example: notify on failure

```bash
# In watch-mirrors.sh (or a new lib/slack.sh):
notify_slack_on_failure() {
  local repo="$1"
  local detail="$2"
  [[ -n "${SLACK_WEBHOOK_URL:-}" ]] || return 0
  curl -sf -X POST -H "Content-Type: application/json" \
    "${SLACK_WEBHOOK_URL}" \
    -d "{\"text\": \":red_circle: Sync failed for \`${repo}\`: ${detail}\"}" >/dev/null || true
}

# Then inside sync_cycle, after the failed+=("$repo") lines:
notify_slack_on_failure "$repo" "$raw_sync_out"
```

---

## 10. Validation After Any Change

There are no automated tests, but use these checks to verify your change:

```bash
# 1. Forgejo is healthy
curl -f http://localhost:1234 || echo "NOT READY"

# 2. Runner is registered
docker run --rm -v forgejo_runner_data:/data busybox \
  test -f /data/.runner && echo "runner OK" || echo "runner MISSING"

# 3. Smoke-test the watcher for one cycle
./scripts/watch-mirrors.sh --once

# 4. Exercise your new script directly
bash ./scripts/my-feature.sh <args>

# 5. Tail logs for unexpected errors
docker compose logs -f forgejo forgejo-runner
```

For changes to `bootstrap.sh`, do a full dry-run against a clean environment:

```bash
docker compose down -v          # wipe all volumes
bash scripts/bootstrap.sh       # re-bootstrap from scratch
```
