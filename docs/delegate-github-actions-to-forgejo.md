# Delegating GitHub Actions to Local Forgejo

This document describes **exactly** what you must do, step by step, to run your GitHub repository's CI workflows on your local Forgejo instance instead of (or in parallel with) GitHub-hosted runners.

---

## Prerequisites — Must Be True Before Starting

Verify each item before proceeding:

```bash
# 1. Forgejo is running and healthy
curl -f http://localhost:1234 && echo "OK"

# 2. Runner is online (should show ubuntu-latest in labels)
podman logs forgejo-runner 2>&1 | grep "declared successfully"

# 3. .env is populated
grep -q FORGEJO_ADMIN_USER .env && grep -q FORGEJO_ADMIN_PASSWORD .env && echo "OK"
```

If any check fails, run `./bootstrap.sh` first.

---

## Step 1 — Create a GitHub Personal Access Token

You need a PAT so Forgejo can pull your repository.

1. Go to: https://github.com/settings/tokens/new
2. Select **"Tokens (classic)"**
3. Set expiration as needed
4. Check **only** the `repo` scope (read access is enough for mirroring)
5. Click **Generate token** and copy it immediately
6. Add it to your `.env` file:

```bash
echo "GITHUB_PAT=ghp_YOUR_TOKEN_HERE" >> .env
```

> Do not commit `.env`. It is already in `.gitignore`.

---

## Step 2 — Mirror the GitHub Repository into Forgejo

Replace `YOUR_ORG`, `YOUR_REPO`, and run from the repo root:

```bash
source .env

curl -s -X POST \
  -u "${FORGEJO_ADMIN_USER}:${FORGEJO_ADMIN_PASSWORD}" \
  -H "Content-Type: application/json" \
  http://localhost:1234/api/v1/repos/migrate \
  -d "{
    \"clone_addr\": \"https://github.com/YOUR_ORG/YOUR_REPO.git\",
    \"auth_token\": \"${GITHUB_PAT}\",
    \"mirror\": true,
    \"mirror_interval\": \"8h\",
    \"repo_name\": \"YOUR_REPO\",
    \"repo_owner\": \"${FORGEJO_ADMIN_USER}\",
    \"service\": \"github\",
    \"private\": false
  }"
```

**Verify the mirror was created:**

```bash
source .env

curl -s \
  -u "${FORGEJO_ADMIN_USER}:${FORGEJO_ADMIN_PASSWORD}" \
  "http://localhost:1234/api/v1/repos/${FORGEJO_ADMIN_USER}/YOUR_REPO" \
  | python3 -c "import sys,json; r=json.load(sys.stdin); print('OK:', r['full_name'], '| mirror:', r['mirror'])"
```

Expected output: `OK: gbrennon/YOUR_REPO | mirror: True`

---

## Step 3 — Trigger the First Sync

The mirror was just created but may not have fetched all content yet. Force a sync now:

```bash
source .env

curl -s -X POST \
  -u "${FORGEJO_ADMIN_USER}:${FORGEJO_ADMIN_PASSWORD}" \
  "http://localhost:1234/api/v1/repos/${FORGEJO_ADMIN_USER}/YOUR_REPO/mirror-sync"
```

Wait 10–30 seconds, then confirm the repo has content:

```bash
source .env

curl -s \
  -u "${FORGEJO_ADMIN_USER}:${FORGEJO_ADMIN_PASSWORD}" \
  "http://localhost:1234/api/v1/repos/${FORGEJO_ADMIN_USER}/YOUR_REPO/branches" \
  | python3 -c "import sys,json; bs=json.load(sys.stdin); [print('branch:', b['name']) for b in bs]"
```

---

## Step 4 — Confirm the Workflow File Exists in the Mirror

Forgejo reads `.github/workflows/` automatically. Confirm it is present:

```bash
source .env

curl -s \
  -u "${FORGEJO_ADMIN_USER}:${FORGEJO_ADMIN_PASSWORD}" \
  "http://localhost:1234/api/v1/repos/${FORGEJO_ADMIN_USER}/YOUR_REPO/contents/.github/workflows" \
  | python3 -c "import sys,json; fs=json.load(sys.stdin); [print(f['name']) for f in fs]"
```

If the `.github/workflows/` directory is missing, the repo either has no workflows or the sync hasn't completed. Re-run Step 3.

---

## Step 5 — Verify the Runner Will Accept the Job

Your runner is registered with labels `ubuntu-latest` and `linux/amd64`. Jobs must declare one of these in `runs-on:`.

Check what `runs-on:` values your workflow uses:

```bash
source .env

curl -s \
  -u "${FORGEJO_ADMIN_USER}:${FORGEJO_ADMIN_PASSWORD}" \
  "http://localhost:1234/api/v1/repos/${FORGEJO_ADMIN_USER}/YOUR_REPO/git/trees/HEAD?recursive=true" \
  | python3 -c "
import sys, json
tree = json.load(sys.stdin)
wf = [f['path'] for f in tree.get('tree', []) if f['path'].startswith('.github/workflows/')]
print('Workflow files:', wf)
"
```

Then for each workflow file, check its `runs-on:` value. If it says `ubuntu-latest`, it will be picked up. If it says something like `ubuntu-22.04` or a custom label not registered on your runner, add that label:

```bash
# Add a label by re-registering the runner with the extra label
# First, delete the current runner config:
podman run --rm -v gb-forgejo-local_forgejo_runner_data:/data busybox rm -f /data/config.yml /data/.runner

# Then re-run bootstrap with the new label set:
# Edit bootstrap.sh — change --labels line to:
#   --labels ubuntu-latest,ubuntu-22.04,linux/amd64
./bootstrap.sh
```

---

## Step 6 — Trigger a Workflow Run

A workflow run is triggered by a new commit being synced to the Forgejo mirror. The fastest way to trigger one without pushing to GitHub:

**Option A — Trigger via a manual sync (if the repo already has commits on the default branch):**

Forgejo triggers workflows on the most recent commit when it detects a new sync with new commits. If the mirror is fresh and has commits, the sync in Step 3 may have already queued a run.

Check the Actions tab:

```
http://localhost:1234/YOUR_ADMIN_USER/YOUR_REPO/actions
```

**Option B — Push a commit to GitHub, which syncs to Forgejo:**

Push any commit to the GitHub repo. Within up to 8 hours (or sooner with a webhook — see Step 7), the Forgejo mirror will sync and trigger the workflow.

**Option C — Create a dummy commit directly on the Forgejo mirror:**

```bash
# Clone from Forgejo, make a change, push back
git clone http://localhost:1234/${FORGEJO_ADMIN_USER}/YOUR_REPO /tmp/YOUR_REPO
cd /tmp/YOUR_REPO
git commit --allow-empty -m "ci: trigger local run"
git push http://${FORGEJO_ADMIN_USER}:${FORGEJO_ADMIN_PASSWORD}@localhost:1234/${FORGEJO_ADMIN_USER}/YOUR_REPO.git
```

---

## Step 7 (Optional but Recommended) — Set Up a Webhook for Instant Sync

Without a webhook, the mirror polls GitHub every 8 hours. A webhook makes Forgejo sync within seconds of a GitHub push.

**Requirement:** Forgejo must be reachable from the internet. Use a tunnel:

```bash
# Option A: cloudflared (no account needed for quick tunnels)
cloudflared tunnel --url http://localhost:1234
# It prints a URL like: https://RANDOM.trycloudflare.com

# Option B: ngrok (requires free account)
ngrok http 1234
# It prints a URL like: https://RANDOM.ngrok-free.app
```

**Generate a Forgejo API token** (do not use your admin password for webhooks):

1. Go to: `http://localhost:1234/user/settings/applications`
2. Under **"Token Name"**, enter `github-webhook`
3. Select scope: `repository` (write)
4. Click **Generate Token** and copy it
5. Store it in `.env`:

```bash
echo "FORGEJO_WEBHOOK_TOKEN=YOUR_TOKEN" >> .env
```

**Configure the webhook on GitHub:**

1. Go to your GitHub repo: `Settings → Webhooks → Add webhook`
2. Fill in:
   - **Payload URL:** `https://YOUR_TUNNEL_URL/api/v1/repos/${FORGEJO_ADMIN_USER}/YOUR_REPO/mirror-sync`
   - **Content type:** `application/json`
   - **Secret:** leave empty (auth is via header)
   - **Events:** select **"Just the push event"**
3. Add a custom header (GitHub does not support arbitrary headers in the UI; use the secret field as a token carrier):

   Alternatively, use a lightweight proxy or script on your end that adds the `Authorization` header before calling Forgejo. The simplest approach is to use the Forgejo webhook endpoint directly:

   **Payload URL with token in query string (simpler):**
   ```
   https://YOUR_TUNNEL_URL/api/v1/repos/${FORGEJO_ADMIN_USER}/YOUR_REPO/mirror-sync?token=${FORGEJO_WEBHOOK_TOKEN}
   ```

**Test the webhook:**

```bash
source .env

# Simulate what GitHub sends: trigger a mirror sync
curl -s -X POST \
  -H "Authorization: token ${FORGEJO_WEBHOOK_TOKEN}" \
  "http://localhost:1234/api/v1/repos/${FORGEJO_ADMIN_USER}/YOUR_REPO/mirror-sync"

echo "Sync triggered. Check http://localhost:1234/${FORGEJO_ADMIN_USER}/YOUR_REPO in a few seconds."
```

---

## Step 8 — Add Secrets Required by Workflows

Secrets from GitHub Actions are **not** mirrored. You must add them manually for each secret referenced in your workflow files.

**Find what secrets your workflows need:**

```bash
# Clone the mirror locally and grep
git clone http://localhost:1234/${FORGEJO_ADMIN_USER}/YOUR_REPO /tmp/check-secrets
grep -r 'secrets\.' /tmp/check-secrets/.github/workflows/ | grep -o 'secrets\.[A-Z_]*' | sort -u
```

**Add each secret to Forgejo:**

```bash
source .env

curl -s -X PUT \
  -u "${FORGEJO_ADMIN_USER}:${FORGEJO_ADMIN_PASSWORD}" \
  -H "Content-Type: application/json" \
  "http://localhost:1234/api/v1/repos/${FORGEJO_ADMIN_USER}/YOUR_REPO/actions/secrets/MY_SECRET_NAME" \
  -d '{"data": "the_actual_secret_value"}'
```

Repeat for every secret found. Verify secrets are listed (values are masked):

```bash
source .env

curl -s \
  -u "${FORGEJO_ADMIN_USER}:${FORGEJO_ADMIN_PASSWORD}" \
  "http://localhost:1234/api/v1/repos/${FORGEJO_ADMIN_USER}/YOUR_REPO/actions/secrets" \
  | python3 -c "import sys,json; d=json.load(sys.stdin); [print('secret:', s['name']) for s in d.get('data',[])]"
```

---

## Step 9 — Monitor the Workflow Run

**Via browser:**
```
http://localhost:1234/FORGEJO_ADMIN_USER/YOUR_REPO/actions
```

**Via runner logs:**
```bash
podman logs -f forgejo-runner
```

A job being picked up looks like:
```
level=info msg="[poller 0] fetched a task"
level=info msg="[job 1] starting job"
```

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Workflow not triggered after sync | `FORGEJO__actions__ENABLED` not set | Confirm `docker-compose.yml` has `FORGEJO__actions__ENABLED=true` under `forgejo` service |
| Job stays in "Waiting" | No runner with matching label | Check runner labels with `podman logs forgejo-runner \| grep labels`; re-register if needed |
| Job fails with "unknown action" | Third-party `uses:` action not available | Forgejo can fetch actions from GitHub. Ensure the runner container has internet access |
| Mirror not syncing | Poll interval | Trigger manually: `curl -X POST -u ... .../mirror-sync` or set up webhook (Step 7) |
| Secret not found in job | Secret not added to Forgejo | Run Step 8 for the missing secret |
| `docker: command not found` inside job | Runner uses `host` mode, not Docker | The runner is configured as `ubuntu-latest:host`. Jobs that need Docker must mount the socket or use a different runner config |

---

## What Happens Under the Hood

```
You push to GitHub
      │
      ▼
GitHub fires push webhook
      │
      ▼ (POST /api/v1/repos/.../mirror-sync)
Forgejo pulls new commits from GitHub
      │
      ▼
Forgejo detects .github/workflows/*.yml
      │
      ▼
Forgejo queues a workflow run
      │
      ▼
forgejo-runner polls Forgejo every few seconds
      │
      ▼
Runner picks up the job and executes it locally
      │
      ▼
Results appear in Forgejo Actions tab
```
