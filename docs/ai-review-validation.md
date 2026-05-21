# AI Review System Validation Guide

This guide explains how to validate that the Migration AI Controller is working correctly after running bootstrap.

## Prerequisites

Before validating, ensure:

1. **Ollama is running** in gb-ollama-container:
   ```bash
   cd ~/repos/gb-ollama-container
   docker compose up -d server
   ```

2. **Required tokens are set in `.env`**:
   - `FORGEJO_TOKEN` — Forgejo admin token
   - `CODEBERG_TOKEN` — Codeberg PAT with `repo` scope

## Validation Steps

### Step 1: Verify Bootstrap Completed

After running `./scripts/bootstrap.sh`, check that:

```bash
# Forgejo is running
curl -sf http://localhost:1234/api/v1/version

# Runner is connected
podman ps | grep forgejo-runner

# Autostart scripts ran
./scripts/autostart/autostart.sh --status
```

Expected output:
```
ollama                        running
watch-mirrors                running
watch-prs                    running
migration-ai-controller      running
```

### Step 2: Check Controller Logs

```bash
tail -f migration-ai-controller.log
```

You should see log messages like:
```
[2026-04-03 12:00:00] [INFO] Migration AI Controller started (poll interval: 600s)
[2026-04-03 12:00:00] [INFO] === Migration AI Controller Cycle Started ===
[2026-04-03 12:00:00] [INFO] Found N mirror repos
```

### Step 3: Create a Test Migration

1. Go to **Forgejo UI**: http://localhost:1234
2. Click **+** → **Create Migration**
3. Enter a **Codeberg repository URL** that has an open PR
   - Example: `https://codeberg.org/yourusername/test-repo.git`
4. Click **Migrate Repository**

### Step 4: Verify Mirror Detection

Check logs for mirror detection:

```bash
grep -i "mirror" migration-ai-controller.log
```

Expected output:
```
Processing repo: yourusername/test-repo
Mirror URL: https://codeberg.org/yourusername/test-repo.git
Codeberg repo: yourusername/test-repo
```

### Step 5: Verify PR Fetch

Check logs for PR detection:

```bash
grep -i "PR" migration-ai-controller.log
```

Expected output:
```
Found 1 open PRs on Codeberg
Checking PR #1: Your PR Title (SHA: abc123...)
```

### Step 6: Verify Ollama Processing

Check that Ollama is being called:

```bash
grep -i "ollama" migration-ai-controller.log
```

Expected output:
```
Sending diff to Ollama...
```

### Step 7: Verify Review Posted

1. Go to the **Codeberg PR** you migrated
2. Check for a new comment with the header: `## AI Code Review`
3. The comment should contain AI-generated feedback

### Step 8: Verify State Updated

Check the state file:

```bash
cat runner-data/migration-ai-controller/state.json
```

Expected output:
```json
{
  "repos": [
    {
      "owner": "username",
      "name": "repo",
      "reviewed_prs": [
        {
          "number": 1,
          "commit_sha": "abc123...",
          "reviewed_at": "2026-04-03T12:05:00Z"
        }
      ]
    }
  ],
  "last_updated": "2026-04-03T12:05:00Z"
}
```

### Step 9: Verify Idempotency

On the next poll cycle, the controller should skip PRs with no new commits:

```bash
grep "skipping" migration-ai-controller.log
```

Expected output:
```
PR #1 already reviewed with same SHA - skipping
```

## Troubleshooting

### Controller Not Running

```bash
# Check autostart status
./scripts/autostart/autostart.sh --status

# Manually start
./scripts/migration-ai-controller/controller.sh
```

### No Mirror Repos Found

```bash
# Check if migration was created correctly
curl -H "Authorization: token $FORGEJO_TOKEN" \
  "http://localhost:1234/api/v1/repos/search?limit=50" | \
  jq '.data[] | select(.mirror == true)'
```

### Ollama Connection Failed

```bash
# Test Ollama directly
curl http://host.containers.internal:11434/api/tags

# Check model is pulled
curl http://host.containers.internal:11434/api/tags | jq '.models[].name'
```

### Codeberg API Errors

```bash
# Test Codeberg token
curl -H "Authorization: token $CODEBERG_TOKEN" \
  "https://codeberg.org/api/v1/user"
```

## Quick Validation Commands

```bash
# Full validation checklist
echo "=== AI Review Validation ===" && \
echo "" && \
echo "1. Controller running:" && \
pgrep -f "migration-ai-controller" && echo "   OK" && \
echo "" && \
echo "2. Mirror repos found:" && \
curl -s -H "Authorization: token $FORGEJO_TOKEN" \
  "http://localhost:1234/api/v1/repos/search?limit=10" | \
  jq '.data[] | select(.mirror == true) | .full_name' && \
echo "" && \
echo "3. Ollama accessible:" && \
curl -sf http://host.containers.internal:11434/api/tags > /dev/null && echo "   OK" && \
echo "" && \
echo "4. State file exists:" && \
ls -la runner-data/migration-ai-controller/state.json
```

## Files Generated

| File | Location | Description |
|------|----------|-------------|
| Controller log | `migration-ai-controller.log` | Runtime logs |
| State file | `runner-data/migration-ai-controller/state.json` | Reviewed PRs database |
| PID file | `runner-data/migration-ai-controller.pid` | Process ID |

## Environment Variables

| Variable | Description | Example |
|----------|-------------|---------|
| `FORGEJO_TOKEN` | Forgejo admin token | `b3...xxx` |
| `CODEBERG_TOKEN` | Codeberg PAT | `b3...xxx` |
| `OLLAMA_HOST` | Ollama endpoint | `http://host.containers.internal:11434` |
| `OLLAMA_MODEL` | Model name | `deepseek-coder:6.7b` |
| `POLL_INTERVAL` | Seconds between polls | `600` |