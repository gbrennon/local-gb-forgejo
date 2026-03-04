# Forgejo Local CI — Scrum Backlog

> **Audience:** This backlog is written for an autonomous agent acting as executor. Each story defines a goal and acceptance criteria. Each task is a concrete, independently executable unit of work. The agent must read the current state of the repository before starting any story and verify acceptance criteria before marking a task done.
>
> **Source of truth for implementation details:** `docs/forgejo-integration-guide.md`

---

## Conventions

- **Epic** — a theme spanning multiple stories
- **Story** — a goal completable in one session, with clear acceptance criteria
- **Task** — a single, verifiable action (read a file, run a command, write a file, verify output)
- **AC** — Acceptance Criteria: conditions that must all be true before the story is done

---

## Epic 1 — Repository is Correctly Configured

> All files in the repo are in the state required to run the system. No manual fixups needed after cloning.

---

### Story 1.1 — Environment File is in Place and Correct

*As an agent bootstrapping this system, I want a properly named and complete `.env` file so that `bootstrap.sh` can source it without errors.*

**AC:**
- File is named `.env` (not `_env`)
- Contains `POSTGRES_DB`, `POSTGRES_USER`, `POSTGRES_PASSWORD`, `FORGEJO_ADMIN_PASSWORD`
- Is listed in `.gitignore`
- `env.example` contains the same four keys with placeholder values

**Tasks:**
- [ ] Read the current directory listing and confirm whether `.env` or `_env` exists
- [ ] If `_env` exists and `.env` does not: rename it (`mv _env .env`)
- [ ] Read `.env` and confirm all four required keys are present; add any missing ones
- [ ] Read `env.example` and confirm it contains all four keys with placeholder values; update if needed
- [ ] Read `.gitignore`; add `.env` and `forgejo_secret.txt` if not already present

---

### Story 1.2 — bootstrap.sh is the Latest Version

*As an agent, I want `bootstrap.sh` to be the current version so that it sources `.env`, detects the runtime correctly, and fetches a real runner token from the Forgejo API.*

**AC:**
- `bootstrap.sh` sources `.env` at the top using `set -a / source / set +a`
- Runtime detection uses `podman info` / `docker info` (daemon check), not CLI version checks
- Runner registration calls `POST /api/v1/admin/runners/registration-token` to get a real token
- Script is idempotent: re-running it skips runner registration if `/data/.runner` already exists

**Tasks:**
- [ ] Read the current `bootstrap.sh` and check whether it contains `source "$ENV_FILE"`
- [ ] If it does not, replace the entire file with the version specified in `docs/forgejo-integration-guide.md` section 2
- [ ] Make the file executable: `chmod +x bootstrap.sh`
- [ ] Verify the script passes `bash -n bootstrap.sh` (syntax check) with no errors

---

### Story 1.3 — System Boots and Runner is Online

*As an agent, I want to run `bootstrap.sh` and confirm all services are healthy and the runner is registered.*

**AC:**
- `bootstrap.sh` exits 0 with final line `All services are up.`
- Runner appears in Forgejo admin panel with status `Idle`
- `forgejo_secret.txt` is present and non-empty

**Tasks:**
- [ ] Run `./bootstrap.sh` and capture output
- [ ] Confirm exit code is 0; if not, read the error and fix the cause before retrying
- [ ] Run the runner verification command from `docs/forgejo-integration-guide.md` section 2 and confirm `local-runner` is returned
- [ ] Confirm `forgejo_secret.txt` exists and is non-empty: `test -s forgejo_secret.txt && echo OK`

---

## Epic 2 — Runner Accepts Standard Workflow Jobs

> The runner is configured with labels that match the `runs-on` targets used in GitHub Actions workflows.

---

### Story 2.1 — Runner Labels Include `ubuntu-latest`

*As an agent, I want the runner registered with `ubuntu-latest` and `linux/amd64` labels so that mirrored GitHub workflows are picked up without modification.*

**AC:**
- Runner config at `/data/.runner` inside the `forgejo_runner_data` volume contains `ubuntu-latest` in its labels
- A test workflow using `runs-on: ubuntu-latest` is queued and picked up by the runner

**Tasks:**
- [ ] Inspect current labels: `podman run --rm -v forgejo_runner_data:/data busybox cat /data/.runner`
- [ ] If `ubuntu-latest` is absent, update `bootstrap.sh` to add `--labels ubuntu-latest,linux/amd64` to the `create-runner-file` command (see `docs/forgejo-integration-guide.md` section 3)
- [ ] Remove the existing runner config to force re-registration: `podman run --rm -v forgejo_runner_data:/data busybox rm -f /data/.runner`
- [ ] Re-run `./bootstrap.sh`
- [ ] Re-inspect labels and confirm `ubuntu-latest` is present
- [ ] Create a minimal test workflow file at `/tmp/test-workflow.yml` with content `on: [push]\njobs:\n  smoke:\n    runs-on: ubuntu-latest\n    steps:\n      - run: echo hello` and push it to a test repo in Forgejo; confirm the job is picked up

---

## Epic 3 — Repositories are Mirrored from Upstream Platforms

> At least one repository from each of GitHub, GitLab, and Bitbucket is mirrored into Forgejo and syncing.

---

### Story 3.1 — A GitHub Repository is Mirrored

*As an agent, I want a GitHub repository mirrored in Forgejo so that its CI can run locally.*

**AC:**
- Repository appears in Forgejo under the admin account
- Full history, branches, and tags are present
- Mirror sync can be triggered manually via API and succeeds

**Tasks:**
- [ ] Confirm a GitHub PAT is available (check `.env` or prompt for it; store it in `.env` as `GITHUB_PAT` — do not hardcode)
- [ ] Run the mirror creation API call from `docs/forgejo-integration-guide.md` section 4.1 with `"service": "github"`
- [ ] Confirm the repo appears: `curl -s -u "admin:${FORGEJO_ADMIN_PASSWORD}" http://localhost:1234/api/v1/repos/search | grep YOUR_REPO`
- [ ] Trigger a manual sync: `curl -s -X POST -u "admin:${FORGEJO_ADMIN_PASSWORD}" http://localhost:1234/api/v1/repos/admin/YOUR_REPO/mirror-sync`
- [ ] Check the repo in the Forgejo UI and confirm last sync timestamp updated

---

### Story 3.2 — A GitLab Repository is Mirrored

*As an agent, I want a GitLab repository mirrored in Forgejo.*

**AC:**
- Repository appears in Forgejo with full history
- Mirror sync succeeds

**Tasks:**
- [ ] Confirm a GitLab Project Access Token is available with `read_repository` scope; store as `GITLAB_PAT` in `.env`
- [ ] Run the mirror creation API call with `"service": "gitlab"` and the GitLab clone URL
- [ ] Confirm repo appears in Forgejo
- [ ] Trigger and verify manual sync

---

### Story 3.3 — A Bitbucket Repository is Mirrored

*As an agent, I want a Bitbucket repository mirrored in Forgejo.*

**AC:**
- Repository appears in Forgejo with full history
- Mirror sync succeeds

**Tasks:**
- [ ] Confirm a Bitbucket App Password is available with `Repositories: Read` permission; store as `BITBUCKET_APP_PASSWORD` in `.env`
- [ ] Run the mirror creation API call with `"service": "bitbucket"` and the Bitbucket clone URL
- [ ] Confirm repo appears in Forgejo
- [ ] Trigger and verify manual sync

---

### Story 3.4 — Mirror Sync is Triggered by Webhooks

*As an agent, I want upstream pushes to trigger immediate mirror syncs rather than waiting for the poll interval.*

**AC:**
- Forgejo is reachable from the internet via a tunnel
- A push to the upstream repo triggers a sync within 30 seconds
- Webhook is configured on at least GitHub (and optionally GitLab and Bitbucket)

**Tasks:**
- [ ] Start a tunnel: `cloudflared tunnel --url http://localhost:1234` or `ngrok http 1234`; capture the public URL
- [ ] Generate a Forgejo API token via UI (`http://localhost:1234/user/settings/applications`) with `repository` scope; store as `FORGEJO_WEBHOOK_TOKEN` in `.env`
- [ ] Configure a push webhook on the GitHub repo using the mirror-sync URL and token (see `docs/forgejo-integration-guide.md` section 4.3)
- [ ] Push a dummy commit to the upstream GitHub repo
- [ ] Within 30 seconds, check the Forgejo mirror's last sync time and confirm it updated
- [ ] Repeat webhook setup for GitLab and Bitbucket mirrors if applicable

---

## Epic 4 — CI Workflows Execute on Forgejo

> Workflows from mirrored repositories run successfully on the local runner.

---

### Story 4.1 — GitHub Actions Workflows Run Unmodified

*As an agent, I want `.github/workflows/` from mirrored GitHub repos to execute on Forgejo without any changes to the workflow files.*

**AC:**
- Forgejo detects and queues the workflow on mirror sync
- Job completes (pass or fail — not "never started")
- No workflow file edits were required

**Tasks:**
- [ ] Confirm the mirrored GitHub repo has `.github/workflows/*.yml`; if not, push a minimal one upstream and sync
- [ ] Trigger a sync and observe the Actions tab in Forgejo: `http://localhost:1234/admin/YOUR_REPO/actions`
- [ ] Confirm the job is picked up by `local-runner` (check runner logs: `podman logs forgejo-runner`)
- [ ] If the job fails due to a missing action (`uses:`), note it and check `docs/forgejo-integration-guide.md` section 5.1 for guidance

---

### Story 4.2 — Forgejo-specific Workflow Override Works

*As an agent, I want to verify that `.forgejo/workflows/` takes precedence over `.github/workflows/` on Forgejo.*

**AC:**
- A repo with both `.forgejo/workflows/ci.yml` and `.github/workflows/ci.yml` runs the Forgejo one on Forgejo
- The GitHub one is unaffected on GitHub

**Tasks:**
- [ ] In a test repo, create `.forgejo/workflows/ci.yml` with a step that outputs `"running on forgejo"` (see `docs/forgejo-integration-guide.md` section 5.2)
- [ ] Push the file and sync the mirror
- [ ] Confirm the Forgejo Actions tab shows the Forgejo-specific workflow ran (not the GitHub one)
- [ ] Confirm the GitHub Actions tab still shows the GitHub workflow ran

---

### Story 4.3 — GitLab/Bitbucket Repos Have Forgejo-native Workflows

*As an agent, I want mirrored GitLab and Bitbucket repos to have `.forgejo/workflows/ci.yml` files that replicate their original pipeline intent.*

**AC:**
- Each GitLab/Bitbucket mirror has a `.forgejo/workflows/ci.yml`
- The workflow covers at minimum: build, test, and lint stages equivalent to the original
- The workflow runs and completes on Forgejo

**Tasks:**
- [ ] Read the original CI config (`.gitlab-ci.yml` or `bitbucket-pipelines.yml`) from the mirrored repo
- [ ] Map stages and steps to GitHub Actions syntax using the table in `docs/forgejo-integration-guide.md` section 5.3
- [ ] Write `.forgejo/workflows/ci.yml` and push it directly to the Forgejo mirror (push to the Forgejo remote, not the upstream)
- [ ] Trigger the workflow manually or via a sync and confirm it runs
- [ ] Repeat for each mirrored repo that has a non-GitHub-Actions CI config

---

### Story 4.4 — Secrets are Available in Forgejo Workflows

*As an agent, I want all secrets referenced in workflows to exist in Forgejo's secret store so that jobs do not fail on missing credentials.*

**AC:**
- All `${{ secrets.* }}` references in workflow files have a corresponding secret in Forgejo
- Secrets are masked in job logs
- No secret values are committed to the repository

**Tasks:**
- [ ] For each mirrored repo, scan workflow files for `secrets.*` references: `grep -r 'secrets\.' .forgejo/ .github/ 2>/dev/null`
- [ ] For each secret found, add it via API (see `docs/forgejo-integration-guide.md` section 5.4) or UI
- [ ] Re-run a workflow that uses a secret and confirm the value is masked (`***`) in the log output
- [ ] Confirm no secret values appear in any committed file: `git log -p | grep -i "SECRET_VALUE"` should return nothing

---

## Epic 5 — Platform is Maintainable

> The system can be operated, debugged, and handed off without tribal knowledge.

---

### Story 5.1 — README Covers Full Setup End-to-End

*As an agent onboarding to this project, I want a README that takes me from zero to a running local CI environment.*

**AC:**
- README covers: prerequisites, env setup, running `bootstrap.sh`, verifying runner, mirroring a repo, triggering a workflow
- A second agent following only the README can complete setup without consulting chat history

**Tasks:**
- [ ] Create or update `README.md` with a Prerequisites section listing: `podman`, `podman-compose`, `openssl`, `curl`, `cloudflared` or `ngrok` (for webhooks)
- [ ] Add a Quick Start section: clone → copy `.env.example` → fill `.env` → run `bootstrap.sh`
- [ ] Add a Mirroring section referencing `docs/forgejo-integration-guide.md` section 4
- [ ] Add a Troubleshooting section covering: daemon not detected, runner not registering, workflow not triggered, secret missing
- [ ] Verify the README is accurate against the current state of the scripts
