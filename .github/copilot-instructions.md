# Copilot Instructions

## Overview

This repository sets up a local Forgejo instance (self-hosted Git forge) with an Actions-style CI runner, backed by PostgreSQL, orchestrated via Docker Compose. Primary entry points: `docker-compose.yml`, `bootstrap.sh`, and `docs/forgejo-integration-guide.md`.

## Build / Test / Lint commands

There are no language-specific build/test/lint toolchains in this repository — the project is an infrastructure configuration for running Forgejo locally. Useful commands for validating and exercising the system:

- First-time bootstrap (creates runner config):
  - bash bootstrap.sh
- Start services (after bootstrap):
  - docker compose up -d
- Stop services:
  - docker compose down
- Tail logs:
  - docker compose logs -f forgejo
  - docker compose logs -f forgejo-runner
- Destroy including volumes:
  - docker compose down -v

Single-check / "single test":
- Health endpoint quick check (equivalent to a single test):
  - curl -f http://localhost:1234 || echo "Forgejo not ready"
- Runner registration file check (inside volume):
  - docker run --rm -v forgejo_runner_data:/data busybox test -f /data/.runner && echo "runner registered" || echo "runner missing"

If adding an application or repo with its own tests, run those tests inside that repo's environment or within an ephemeral container; this repo itself contains no unit/integration tests.

## High-level architecture

- Services (see `docker-compose.yml`):
  - forgejo: the web UI and API (container port 3000 mapped to host 1234)
  - forgejo-db: Postgres backing store
  - forgejo-runner: Actions-style runner that executes workflows
- Networking: runner connects to Forgejo over the internal compose network at `http://forgejo:3000` (bootstrap.sh handles internal vs. host addressing for podman).
- Volumes: persistent data stored in three named volumes — `forgejo_data`, `forgejo_db_data`, `forgejo_runner_data`.
- Bootstrap flow: `bootstrap.sh` starts forgejo + db, waits for health, fetches a real runner registration token via the Forgejo API (using `FORGEJO_ADMIN_PASSWORD`), writes `forgejo_secret.txt`, registers the runner, and starts the runner service.

Refer to `docs/forgejo-integration-guide.md` for detailed runbooks and API examples.

## Key conventions and repository-specific patterns

- .env is required for `bootstrap.sh` and must contain at minimum:
  - POSTGRES_DB, POSTGRES_USER, POSTGRES_PASSWORD, FORGEJO_ADMIN_PASSWORD
  - Use `env.example` as the template; do not commit a real `.env` file.
- bootstrap.sh behavior:
  - Detects container runtime by calling `podman info` or `docker info` (daemon check).
  - Uses `podman-compose` when podman is available, otherwise `docker compose`.
  - Uses internal vs host URLs appropriately (`http://host.containers.internal:1234` for podman run contexts vs `http://forgejo:3000` on the compose network).
  - Idempotent runner registration: skips registration if `/data/.runner` exists in the `forgejo_runner_data` volume.
- Runner labels: add `--labels ubuntu-latest,linux/amd64` to the runner registration (in `bootstrap.sh`) if you need the runner to accept `runs-on: ubuntu-latest` workflows.
- Forgejo workflow override: place Forgejo-native workflows under `.forgejo/workflows/` to override `.github/workflows/` on the Forgejo instance.
- Secrets: `forgejo_secret.txt` is produced by `bootstrap.sh` and is intentionally local; do not treat it as a production secret.

## Files and docs to consult

- `docs/forgejo-integration-guide.md` — step-by-step integration and runbook (mirroring, runner labels, API examples).
- `docs/forgejo-scrum-backlog.md` — backlog and operational tasks useful for agents or automation.
- `docker-compose.yml` and `bootstrap.sh` — primary implementation files to modify for runtime behavior.
- `env.example` — template for `.env` variables.

## AI assistant / other assistant configs checked

No CLAUDE.md, .cursorrules, AGENTS.md, .windsurfrules, CONVENTIONS.md, AIDER_CONVENTIONS.md, .clinerules, or similar AI assistant config files were found; important repo-specific behavior is captured above and in `docs/`.

## Quick troubleshooting checks

- Is `.env` present and populated? `grep -q "FORGEJO_ADMIN_PASSWORD" .env || echo ".env missing key"`
- Is Forgejo healthy? `curl -f http://localhost:1234 || echo "not healthy"`
- Is the runner registered? `docker run --rm -v forgejo_runner_data:/data busybox test -f /data/.runner && echo OK`

---

(If edits are needed to add explicit language-specific build/test commands for an application you mirror here, add them to this file under "Build / Test / Lint commands".)
