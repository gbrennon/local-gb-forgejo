# AI Code Review Infrastructure Analysis

Three-project ecosystem for automated AI-powered code review using local Ollama.

## Project Overview

| Project | Purpose | Key Files |
|---------|--------|---------|
| `ai-review-template` | Template for AI code review workflow | `workflow.yml`, `scripts/` |
| `gb-ollama-container` | Self-hosted LLM infrastructure | `docker-compose.yml`, `modelfiles/` |
| `local-gb-forgejo` | Self-hosted Forgejo with Actions | `docker-compose.yml`, bootstrap |

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                      local-gb-forgejo                      │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────┐  │
│  │  Forgejo  │  │    DB     │  │  forgejo-runner  │  │
│  │  :3000   │  │ postgres │  │  (Actions exec)  │  │
│  └─────────────┘  └─────────────┘  └─────────────────────┘  │
└──────────────────────────────────────────────────────────────┘
                              │
                              │ API calls, diff fetch, comment post
                              ▼
┌─────────────────────────────────────────────────────────────────────┐
│                   gb-ollama-container                     │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────┐   │
│  │ Ollama   │  │  WebUI   │  │  OpenHands   │   │
│  │ :11434  │  │  :3000  │  │    :3001    │   │
│  └─────────────┘  └─────────────┘  └─────────────────┘   │
│                                                             │
│   Models: deepseek-r1:14b, qwen2.5-coder:32b,               │
│          eda-arch-python (custom architecture model)         │
└──────────────────────────────────────────────────────┘
                              │
                              │ POST /api/generate
                              │ (diff → review)
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                 ai-review-template (workflow)               │
│  ┌──────────────────────────────────────────────────┐  │
│  │ Cron poll / Push trigger                         │  │
│  │  1. Fetch open PRs from Codeberg            │  │
│  │ 2. Get diff for each PR                 │  │
│  │ 3. Send to Ollama for review           │  │
│  │ 4. Post comment to PR                │  │
│  │ 5. Update state (JSON)               │  │
│  └──────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────┘
```

---

## Key Insights

### 1. State Management

The ai-review-template uses a JSON file to track reviewed PRs:

```json
{
  "reviewed_prs": [
    {
      "number": 5,
      "commit_sha": "abc123...",
      "reviewed_at": "2024-01-15T10:30:00Z"
    }
  ]
}
```

Logic: Compare `head.sha` with stored `commit_sha`. Same SHA = skip review.

### 2. Dual Target Patterns

- **ai-review-template**: Targets external Codeberg repos (pulls from Codeberg API)
- **local-gb-forgejo**: Targets local Forgejo (posts via local API)

Both use similar Ollama integration patterns.

### 3. Ollama Model Ecosystem (gb-ollama-container)

| Model | Type | Purpose |
|-------|------|---------|
| `qwen2.5-coder:32b` | Base | General coding |
| `deepseek-r1:14b` | Base | Reasoning |
| `eda-arch-python` | Custom | Architecture/SOLID/TDD |

Custom modelfiles in `modelfiles/`:
- `quick-refactor.Modelfile` - Pragmatic refactoring
- `eda-arch-*.Modelfile` - Architecture-aware

### 4. Idempotency

Workflow handles:
- Same PR, same SHA → skip (already reviewed)
- Same PR, new commit → re-review
- New PR → review

### 5. Runner Networking

podman vs docker differences handled in bootstrap:
- podman: `http://host.containers.internal:11434`
- docker: `http://server:11434`

---

## Workflow Execution Flow

```
1. Trigger
   │
   ├─ Schedule (cron: */10 * * * *)
   └─ Push to main/master

2. Load State
   │
   └─ Read JSON file (reviewed_prs.json)

3. Fetch PRs
   │
   └─ GET /repos/{owner}/{repo}/pulls?state=open

4. For each PR:
   │
   ├─ Check SHA → same? skip
   │
   ├─ Get Diff
   │  └─ GET /pulls/{number}.diff
   │
   ├─ Send to Ollama
   │  └─ POST /api/generate
   │     model: deepseek-coder:6.7b
   │     prompt: review instructions + diff
   │
   └─ Post Comment
      └─ POST /issues/{number}/comments

5. Save State
   │
   └─ Write updated JSON file to workspace
```

---

## Prerequisites Met

| Component | Status | Notes |
|-----------|--------|-------|
| Forgejo + Actions | ✅ | local-gb-forgejo |
| Ollama | ✅ | gb-ollama-container |
| deepseek-coder model | ✅ | Available |
| Runner with docker | ✅ | Podman socket mounted |

---

## Dependencies Assumed

1. **Ollama host resolution**: `host.containers.internal` (podman) or `server` (docker compose network)
2. **API token**: Codeberg PAT with `repo` scope
3. **Model available**: `deepseek-coder:6.7b` or similar

---

## Integration Points

### For local Forgejo usage:

```yaml
# In workflow.yml
env:
  OLLAMA_HOST: 'http://host.containers.internal:11434'  # podman
  # or 'http://server:11434'  # docker
  OLLAMA_MODEL: 'deepseek-coder:6.7b'
```

### For custom review criteria:

Edit the prompt in the Ollama request:

```json
"prompt": "You are a code reviewer. Review the following git diff...
Focus on: bugs, security issues, code quality, potential improvements."
```

### For different models:

Using gb-ollama-container models:
- `eda-arch-python` - Architecture/SOLID aware
- `quick-refactor` - Pragmatic refactoring

---

## Current Gaps

1. **No state persistence across workflow runs** - The JSON file needs to be committed back or stored in volume
2. **No retry logic** - Failed reviews silently continue
3. **Hardcoded model** - Should be configurable via environment
4. **No rate limiting** - Could overwhelm Ollama with many PRs

---

## Assumptions Made

1. `deepseek-coder:6.7b` is available in Ollama
2. Runner has network access to Ollama container
3. Secrets (token, repo owner/name) are configured in Forgejo
4. State file commit works (write permissions)
5. `forgejo-runner` has docker/podman socket for running actions

---

## Related Documentation

- `ai-review-template/docs/02-ai-reviewer.md` - Full AI reviewer setup guide
- `gb-ollama-container/README.md` - Ollama container setup
- `local-gb-forgejo/AGENTS.md` - Local Forgejo bootstrap