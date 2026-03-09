# local-gb-forgejo

A local [Forgejo](https://forgejo.org) instance that mirrors GitHub repositories and runs
CI/CD via Forgejo Actions on a local runner. Results are posted back to GitHub as commit
statuses so they appear on your PRs and commits — just like regular GitHub Actions, but
running on your own machine.

---

## What this does

```
┌─────────────────────┐         push          ┌───────────────────────────┐
│   GitHub (origin)   │ ─────────────────────▶│   GitHub (github.com)     │
│  GitHub repo        │                       └─────────────┬─────────────┘
└─────────────────────┘                                     │
                                                            │ HTTPS (PAT)
                                                            ▼
┌────────────────────────────────────────────────────────────────────────────┐
│  Host machine (localhost:1234)                                             │
│                                                                            │
│  ┌──────────────────────┐   poll /mirror-sync API (every 60s)              │
│  │  watch-mirrors.sh    │───────────────────────────────────┐              │
│  │  (background daemon) │                                   │              │
│  └──────────────────────┘                                   ▼              │
│                                                    ┌───────────────────┐   │
│                                                    │   Forgejo (cont.) │   │
│                                                    │   web UI + API    │   │
│                                                    │   mirrors repos   │   │
│                                                    └────────┬──────────┘   │
│                                                             │              │
│                                                             ▼ gRPC         │
│                                                    ┌───────────────────┐   │
│                                                    │  forgejo-runner   │   │
│                                                    │  executes workflow│   │
│                                                    └───────────────────┘   │
└────────────────────────────────────────────────────────────────────────────┘

```

- You keep using GitHub as normal (push, open PRs, merge)
- Forgejo mirrors your repos locally and runs workflows on every push
- A watcher daemon syncs mirrors every 60 seconds and reports results back to GitHub
- On reboot, everything restarts automatically via systemd

---

## Architecture

| Component | What it is | Port |
|-----------|-----------|------|
| `forgejo` | Self-hosted Git forge (web UI + API) | `localhost:1234` |
| `forgejo-db` | PostgreSQL backing store | internal |
| `forgejo-runner` | Forgejo Actions runner (executes workflows) | internal |
| `watch-mirrors.sh` | Host daemon — syncs mirrors + posts GitHub statuses | — |

All containers are defined in `docker-compose.yml` and managed by
Podman (auto-detected) or Docker.

---

## Prerequisites

- [Podman](https://podman.io) + `podman-compose` **or** Docker + Docker Compose
- `jq`, `curl`, `git`, `gh` (GitHub CLI)
- A GitHub Personal Access Token with `repo` scope (needed for mirror auth + status API)
- Ports `1234` free on the host

---

## First-time setup

### 1 — Clone and configure

```bash
git clone https://github.com/<your-github-username>/local-gb-forgejo.git
cd local-gb-forgejo
cp env.example .env
```

Edit `.env` — fill in every value:

```bash
POSTGRES_DB=forgejo
POSTGRES_USER=forgejo
POSTGRES_PASSWORD=<strong-password>
FORGEJO_ADMIN_USER=gbadmin          # Forgejo admin username
FORGEJO_ADMIN_PASSWORD=<strong-password>
GITHUB_PAT=ghp_xxxxxxxxxxxxxxxxxxxx # GitHub PAT with repo scope
```

> **Never commit `.env`** — it is in `.gitignore`.

### 2 — Bootstrap

```bash
./scripts/bootstrap.sh
```

This script:
1. Detects Podman or Docker and starts the compose stack
2. Waits for Forgejo to be healthy
3. Creates the admin user if this is a fresh database
4. Fetches a runner registration token from the Forgejo API
5. Registers and starts the `forgejo-runner` container
6. Starts `watch-mirrors.sh` as a background daemon

On success you will see:

```
[OK] Forgejo is ready.
[OK] Runner registered.
[OK] Mirror watcher started (PID …)
```

Forgejo UI: **http://localhost:1234**

---

## Make it start on boot (systemd)

After the first successful bootstrap, install the two systemd user services so everything
restarts automatically after a reboot — no login required.

### 1 — Install the services

```bash
# Reload unit files (services are already in ~/.config/systemd/user/)
systemctl --user daemon-reload

# Enable both services to start at boot
systemctl --user enable forgejo-stack.service forgejo-watcher.service

# Allow your user session to run at boot without being logged in
loginctl enable-linger $USER
```

### 2 — Start them now (first time)

```bash
systemctl --user start forgejo-stack.service
# forgejo-watcher starts automatically after the stack is up
```

### 3 — Verify

```bash
systemctl --user status forgejo-stack.service forgejo-watcher.service
```

Expected output:
```
● forgejo-stack.service
     Active: active (exited)   ← bootstrap finished, containers are up

● forgejo-watcher.service
     Active: active (running)  ← watcher loop is alive
```

### What happens on reboot

1. `forgejo-stack.service` — runs `scripts/bootstrap.sh --no-watcher`
   - Starts Forgejo + DB + runner containers
   - Re-registers the runner if needed (idempotent)
2. `forgejo-watcher.service` — starts `watch-mirrors.sh` in the foreground
   - systemd restarts it automatically if it ever crashes (`Restart=always`)
   - Logs append to `watcher.log` in the repo root

---

## Mirroring a GitHub repo

### Via script (recommended)

```bash
./scripts/mirror-repo.sh <github-username> <repo-name>
# e.g. ./scripts/mirror-repo.sh <your-github-username> stunning-palm-tree
```

The script creates the mirror under `FORGEJO_ADMIN_USER`, triggers the first sync, lists
fetched branches, and scans workflow files for required secrets.

### Via Forgejo web UI

1. Go to `http://localhost:1234` → **+ New Migration** → GitHub
2. Paste the GitHub HTTPS URL
3. Check **"This repository will be a mirror"**
4. You can create it under any Forgejo user account

> Mirrors created by **any Forgejo user** are auto-discovered by the watcher.
> The admin credentials used to call `GET /api/v1/repos/search?mirror=true` return
> all repos across all users.

---

## Workflow files

Forgejo reads `.forgejo/workflows/` (takes precedence) or `.github/workflows/`.

Minimal example for a mirror repo:

```yaml
# .forgejo/workflows/ci.yml
on: [push]

jobs:
  ci:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: echo "✅ Running on branch ${{ github.ref_name }}"

  merge-to-main:
    if: github.ref == 'refs/heads/main'
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: echo "✅ Merged to main — ${{ github.sha }}"
```

> **Note:** The runner image (`data.forgejo.org/forgejo/runner:9`) is minimal.
> Language toolchains (Rust, Node, Python) must be installed in-workflow.

---

## GitHub commit status reporting

After each sync cycle the watcher posts Forgejo Actions results back to GitHub using the
[Commit Status API](https://docs.github.com/en/rest/commits/statuses).

On your GitHub PR you will see:

```
✅  forgejo/CI — every push          success
⏭️  forgejo/CI — merge to main only  skipped   ← only runs after merge
```

Each job gets its own status context (`forgejo/<job-name>`). The `target_url` links to
`http://localhost:1234/<owner>/<repo>/actions` (only reachable from your machine, but the
status itself is visible on GitHub to everyone).

Reported statuses are tracked in `runner-data/gh-status-reported.txt` to avoid duplicates.

---

## Day-to-day usage

### Check everything is healthy

```bash
# Containers
podman ps  # or: docker ps

# Forgejo API
curl -sf http://localhost:1234/api/v1/version && echo "OK"

# Watcher
systemctl --user status forgejo-watcher.service

# Live watcher log
tail -f watcher.log
```

### Force an immediate sync (skip the 60s wait)

```bash
source .env
curl -s -X POST \
  -u "$FORGEJO_ADMIN_USER:$FORGEJO_ADMIN_PASSWORD" \
  "http://localhost:1234/api/v1/repos/<forgejo-owner>/<repo>/mirror-sync" \
  -o /dev/null -w "sync: %{http_code}\n"
```

### Check recent Actions runs

```bash
source .env
curl -s -u "$FORGEJO_ADMIN_USER:$FORGEJO_ADMIN_PASSWORD" \
  "http://localhost:1234/api/v1/repos/<forgejo-owner>/<repo>/actions/tasks?limit=10" \
  | jq -r '.workflow_runs[] | "\(.status)\t\(.name)\t\(.head_branch)"'
```

Or open the browser: **http://localhost:1234/\<owner\>/\<repo\>/actions**

### List all mirrors

```bash
source .env
curl -s -u "$FORGEJO_ADMIN_USER:$FORGEJO_ADMIN_PASSWORD" \
  "http://localhost:1234/api/v1/repos/search?mirror=true&limit=50" \
  | jq -r '.data[].full_name'
```

### Restart after config change

```bash
systemctl --user restart forgejo-stack.service
```

### Full teardown (destroys all data)

```bash
systemctl --user stop forgejo-watcher.service forgejo-stack.service
podman-compose down -v   # or: docker compose down -v
```

---

## Scripts reference

| Script | Purpose |
|--------|---------|
| `scripts/bootstrap.sh` | Full stack setup: start containers, register runner, start watcher |
| `scripts/bootstrap.sh --no-watcher` | Same but skip watcher start (used by systemd) |
| `scripts/mirror-repo.sh <org> <repo>` | Register a GitHub repo as a Forgejo mirror |
| `scripts/sync-mirrors.sh [owner/repo]` | One-shot sync of all or a specific mirror |
| `scripts/watch-mirrors.sh` | Background daemon: sync every 60s + report to GitHub |

---

## File layout

```
local-gb-forgejo/

├── docker-compose.yml              # forgejo + forgejo-db + forgejo-runner
├── env.example                     # template — copy to .env
├── scripts/
│   ├── lib/
│   │   ├── common.sh               # logging, load_env, require_forgejo
│   │   ├── forgejo-api.sh          # Forgejo API wrappers
│   │   └── github-api.sh           # GitHub Commit Status API
│   ├── mirror-repo.sh              # one-shot mirror registration
│   ├── sync-mirrors.sh             # one-shot sync
│   └── watch-mirrors.sh            # 60s daemon
├── runner-data/
│   └── gh-status-reported.txt      # dedup state for GitHub status posts

└── ~/.config/systemd/user/
    ├── forgejo-stack.service       # systemd unit: containers
    └── forgejo-watcher.service     # systemd unit: watcher daemon
```

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| `scripts/bootstrap.sh` fails at runner token | Forgejo DB not fully initialized | Wait 10s and re-run |
| Mirror sync fails silently | Web UI mirror created without GitHub PAT | See below |
| Runner never connects | Stale `.runner` file from previous DB | `podman-compose down -v && ./scripts/bootstrap.sh` |
| GitHub statuses not appearing | `GITHUB_PAT` missing or expired | Check `.env`, re-run watcher |
| `forgejo-watcher` keeps restarting | Script error — check logs | `journalctl --user -u forgejo-watcher -n 50` |

### Fix a web UI mirror with no credentials

If you created a mirror via the Forgejo web UI without a PAT, syncs will silently fail.
Fix the stored remote URL inside the container:

```bash
source .env
podman exec forgejo sh -c "
  git config --global --add safe.directory /data/git/repositories/<owner>/<repo>.git
  git -C /data/git/repositories/<owner>/<repo>.git remote set-url origin \
    https://oauth2:${GITHUB_PAT}@github.com/<github-owner>/<repo>.git
"
```

Then trigger a sync to verify:

```bash
curl -s -X POST -u "$FORGEJO_ADMIN_USER:$FORGEJO_ADMIN_PASSWORD" \
  "http://localhost:1234/api/v1/repos/<owner>/<repo>/mirror-sync" \
  -o /dev/null -w "%{http_code}\n"
```
