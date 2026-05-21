# AI Code Review Workflow Guide

How to create a Forgejo Actions workflow that automates code review using local Ollama.

---

## Quick Start

1. **Ensure Ollama is running**:
   ```bash
   cd ~/repos/gbrennon/gb-ollama-container
   docker compose up -d
   ```

2. **Ensure model is available**:
   ```bash
   docker exec ollama ollama pull deepseek-coder:6.7b
   ```

3. **Copy workflow to your repo**:
   ```bash
   cp ai-review-template/workflow.yml .forgejo/workflows/ai-review.yml
   ```

4. **Configure secrets** in Forgejo repo settings.

---

## Full Workflow Reference

### Basic Structure

```yaml
name: AI Code Review

on:
  pull_request:
  schedule:
    - cron: '*/10 * * * *'

env:
  OLLAMA_HOST: 'http://host.containers.internal:11434'
  OLLAMA_MODEL: 'deepseek-coder:6.7b'

jobs:
  ai-review:
    runs-on: ubuntu-latest
    steps:
      - name: Get PR diff
        id: diff
        run: |
          # Fetch diff from Forgejo API
          DIFF=$(curl -s -H "Authorization: token ${{ secrets.FORGEJO_TOKEN }}" \
            "${{ secrets.FORGEJO_URL }}/api/v1/repos/${{ github.repository }}/pulls/${{ github.event.pull_request.number }}/diff")
          echo "diff<<EOF" >> $GITHUB_OUTPUT
          echo "$DIFF" >> $GITHUB_OUTPUT
          echo "EOF" >> $GITHUB_OUTPUT

      - name: Query Ollama
        id: review
        run: |
          RESPONSE=$(curl -s -X POST ${{ env.OLLAMA_HOST }}/api/generate \
            -H "Content-Type: application/json" \
            -d '{
              "model": "${{ env.OLLAMA_MODEL }}",
              "prompt": "You are a code reviewer. Review the following git diff...

DIFF:
${{ steps.diff.outputs.diff }}",
              "stream": false
            }')
          REVIEW=$(echo "$RESPONSE" | jq -r '.response // empty')
          echo "review<<EOF" >> $GITHUB_OUTPUT
          echo "$REVIEW" >> $GITHUB_OUTPUT
          echo "EOF" >> $GITHUB_OUTPUT

      - name: Post comment
        run: |
          curl -s -X POST \
            -H "Authorization: token ${{ secrets.FORGEJO_TOKEN }}" \
            -H "Content-Type: application/json" \
            "${{ secrets.FORGEJO_URL }}/api/v1/repos/${{ github.repository }}/issues/${{ github.event.pull_request.number }}/comments" \
            -d "{\"body\": \"## AI Code Review\n\n${{ steps.review.outputs.review }}\n\n---\n*Review by ${{ env.OLLAMA_MODEL }} via Forgejo Actions*\" }"
```

---

## Configuration

### Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `OLLAMA_HOST` | Ollama API endpoint | `http://host.containers.internal:11434` |
| `OLLAMA_MODEL` | Model to use for review | `deepseek-coder:6.7b` |

### Secrets

| Secret | Description |
|--------|-------------|
| `FORGEJO_TOKEN` | Personal access token with `repo` scope |
| `FORGEJO_URL` | Forgejo instance URL (e.g., `http://localhost:1234`) |

### Runner Labels

Ensure your runner has appropriate labels for the workflow:

```yaml
jobs:
  ai-review:
    runs-on: ubuntu-latest  # or custom label like 'codeberg-medium'
```

---

## Event Triggers

### On Pull Request

```yaml
on: pull_request
```

Access PR data via:
- `github.event.pull_request.number`
- `github.event.pull_request.title`
- `github.event.pull_request.head.sha`

### On Schedule (Cron)

```yaml
on:
  schedule:
    - cron: '*/10 * * * *'  # Every 10 minutes
```

### Combined

```yaml
on:
  pull_request:
  schedule:
    - cron: '*/10 * * * *'
```

---

## Ollama API Request

### Generate Endpoint

```bash
curl -X POST http://localhost:11434/api/generate \
  -H "Content-Type: application/json" \
  -d '{
    "model": "deepseek-coder:6.7b",
    "prompt": "Your prompt here",
    "stream": false
  }'
```

### Response

```json
{
  "model": "deepseek-coder:6.7b",
  "created_at": "2024-01-15T10:30:00Z",
  "response": "## Issues Found\n...",
  "done": true
}
```

---

## Custom Review Prompts

### Default Prompt

```yaml
"prompt": "You are a code reviewer. Review the following git diff and provide constructive feedback. Focus on bugs, security issues, code quality, and potential improvements. Output in markdown format with these sections:

## Issues Found
- (line/section) - issue description

## Suggestions
- (line/section) - suggestion

## Summary
One sentence overall assessment.

DIFF:
$DIFF"
```

### Architecture Review (using eda-arch-python)

```yaml
"prompt": "You are a senior software architect reviewing code. Apply hexagonal architecture and SOLID principles. Evaluate:

## Architecture
- Ports and adapters separation
- Single Responsibility
- Dependency Inversion

## Code Quality
- Explicit error handling
- No magic numbers

DIFF:
$DIFF"
```

### Security Focus

```yaml
"prompt": "You are a security reviewer. Focus on:

## Security Issues
- Injection risks
- Authentication/authorization
- Data exposure
- Input validation

DIFF:
$DIFF"
```

---

## Complete Example with State Tracking

```yaml
name: AI Code Review with State

on: pull_request

env:
  OLLAMA_HOST: 'http://host.containers.internal:11434'
  OLLAMA_MODEL: 'deepseek-coder:6.7b'
  DB_PATH: '/data/reviewed_prs.json'

jobs:
  ai-review:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout state file
        uses: actions/checkout@v4
        with:
          sparse-checkout: |
            ${{ env.DB_PATH }}
          sparse-checkout-cone-mode: false

      - name: Load state
        id: load-state
        run: |
          DB_FILE="${{ github.workspace }}/${{ env.DB_PATH }}"
          if [ -f "$DB_FILE" ]; then
            echo "state=$(cat $DB_FILE)" >> $GITHUB_OUTPUT
          else
            echo "state={}" >> $GITHUB_OUTPUT
          fi

      - name: Get PR diff
        id: diff
        run: |
          PR_NUM=${{ github.event.pull_request.number }}
          DIFF=$(curl -s -H "Authorization: token ${{ secrets.FORGEJO_TOKEN }}" \
            "${{ secrets.FORGEJO_URL }}/api/v1/repos/${{ github.repository }}/pulls/$PR_NUM.diff")
          echo "diff<<EOF" >> $GITHUB_OUTPUT
          echo "$DIFF" >> $GITHUB_OUTPUT
          echo "EOF" >> $GITHUB_OUTPUT

      - name: Check if already reviewed
        id: check-review
        run: |
          STATE='${{ steps.load-state.outputs.state }}'
          PR_NUM=${{ github.event.pull_request.number }}
          SHA=${{ github.event.pull_request.head.sha }}
          
          # Parse state and check SHA
          echo "Checking PR #$PR_NUM (SHA: $SHA)"
          
          # Simplified: just check if PR number in state
          if echo "$STATE" | jq -e ".prs[$PR_NUM]" >/dev/null 2>&1; then
            echo "reviewed=true" >> $GITHUB_OUTPUT
          else
            echo "reviewed=false" >> $GITHUB_OUTPUT
          fi

      - name: Query Ollama
        if: steps.check-review.outputs.reviewed == 'false'
        id: review
        run: |
          RESPONSE=$(curl -s -X POST ${{ env.OLLAMA_HOST }}/api/generate \
            -H "Content-Type: application/json" \
            -d '{
              "model": "${{ env.OLLAMA_MODEL }}",
              "prompt": "You are a code reviewer. Review the following diff...

DIFF:
${{ steps.diff.outputs.diff }}",
              "stream": false
            }')
          REVIEW=$(echo "$RESPONSE" | jq -r '.response // empty')
          echo "review<<EOF" >> $GITHUB_OUTPUT
          echo "$REVIEW" >> $GITHUB_OUTPUT
          echo "EOF" >> $GITHUB_OUTPUT

      - name: Post comment
        if: steps.check-review.outputs.reviewed == 'false'
        run: |
          curl -s -X POST \
            -H "Authorization: token ${{ secrets.FORGEJO_TOKEN }}" \
            -H "Content-Type: application/json" \
            "${{ secrets.FORGEJO_URL }}/api/v1/repos/${{ github.repository }}/issues/${{ github.event.pull_request.number }}/comments" \
            -d "{\"body\": \"## AI Code Review\n\n${{ steps.review.outputs.review }}\n\n---\n*Review by ${{ env.OLLAMA_MODEL }}*\" }"

      - name: Update state
        if: steps.check-review.outputs.reviewed == 'false'
        run: |
          # Update JSON state file
          echo '{"prs": {...}}' > "${{ env.DB_PATH }}"
```

---

## Working with gb-ollama-container

### Available Models

| Model | Command |
|-------|---------|
| Code review | `deepseek-coder:6.7b` |
| Architecture | `eda-arch-python` |
| Refactoring | `quick-refactor` |

### Custom Model Request

To use a custom model:

```yaml
env:
  OLLAMA_MODEL: 'eda-arch-python'
```

### Checking Model Availability

```bash
# Inside Ollama container
docker exec ollama ollama list

# Or via API
curl http://localhost:11434/api/tags
```

---

## Testing Your Workflow

### 1. Manual Trigger

```bash
# Create a PR, then:
curl -X POST \
  -H "Authorization: token $FORGEJO_TOKEN" \
  "$FORGEJO_URL/api/v1/repos/$REPO/actions/workflows"
```

### 2. View Workflow Runs

Navigate to: `$FORGEJO_URL/-/admin/actions`

### 3. View Logs

```bash
docker compose logs -f forgejo-runner
```

---

## Troubleshooting

### "Ollama not responding"

- Check host: `curl http://host.containers.internal:11434/api/tags`
- Ensure podman socket: check volume mount in docker-compose.yml

### "Model not found"

```bash
docker exec ollama ollama pull deepseek-coder:6.7b
```

### "Permission denied"

- Ensure FORGEJO_TOKEN has `repo` scope
- Check token in repo settings → secrets

### "No diff returned"

- PR must be open
- Check API URL format: `/pulls/{number}.diff`

---

## File Locations

| File | Path |
|------|------|
| Workflow | `.forgejo/workflows/ai-review.yml` |
| Scripts | `scripts/lib/api.sh` |
| Templates | `ai-review-template/workflow.yml` |

---

## See Also

- [AI Code Review Analysis](ai-code-review-analysis.md)
- [ai-review-template README](https://github.com/gbrennon/ai-review-template)
- [gb-ollama-container README](https://github.com/gbrennon/gb-ollama-container)