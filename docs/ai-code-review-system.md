# AI Code Review System Documentation

## Overview

The AI Code Review system automatically reviews pull requests on your local Forgejo instance by:
1. Polling mirrored repos for open PRs (from Codeberg/GitHub)
2. Fetching PR diffs and sending them to local Ollama
3. Posting AI-generated review comments back to the original PR

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                          watch-prs.sh                                       │
│   - Polls all repos for open PRs                                           │
│   - Handles both local Forgejo PRs and mirrored external PRs              │
│   - Compares SHA with last reviewed state                                  │
└─────────────────────────────────────────────────────────────────────────────┘
                                     │
                                     ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                      Ollama (Local LLM)                                     │
│   - Receives diff + prompt                                                 │
│   - Returns structured JSON review                                         │
└─────────────────────────────────────────────────────────────────────────────┘
                                     │
                                     ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                     Original Platform                                      │
│   - Posts review comment to Codeberg/GitHub PR                             │
│   - Uses API token for authentication                                       │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## How It Works

### 1. PR Detection

The system handles two types of PRs:

**Local PRs**: PRs created directly on Forgejo
```bash
curl "${FORGEJO_HOST}/api/v1/repos/${repo}/pulls?state=open"
```

**Mirrored PRs**: PRs from the original platform (Codeberg/GitHub)
- When local PRs are empty, the system checks if the repo is a mirror
- Fetches PRs from original platform API using `original_url` from repo metadata

### 2. Diff Fetching

**Local diff** (PR exists on Forgejo):
```bash
curl "${FORGEJO_HOST}/api/v1/repos/${repo}/compare/${base_sha}...${head_sha}"
```

**External diff** (mirrored repo):
```bash
# Codeberg
curl "https://codeberg.org/api/v1/repos/${original_slug}/compare/${base}...${head}"

# GitHub  
curl "https://api.github.com/repos/${original_slug}/compare/${base}...${head}"
```

### 3. Review Generation

The diff is sent to Ollama with a structured prompt that asks for JSON output.

**Prompt includes**:
- Review priorities (critical, architectural, quality)
- Output format specification
- Guidelines (specific, actionable, no emojis)

### 4. Comment Posting

The JSON response is formatted into a clean markdown comment and posted to the original PR:
- Issues with severity and type tags
- Suggestions
- Praise (what was done well)
- Summary

---

## File Structure

```
scripts/
├── watch-prs.sh              # Main watcher daemon ( polls for PRs )
├── lib/
│   ├── build-prompt.py       # Builds Ollama prompt from diff
│   ├── build-comment.py      # Formats JSON response into markdown
│   ├── json-escape.py        # Escapes JSON for API posting
│   ├── update-state.py       # Updates review state file
│   ├── platform-detect.sh    # Detects GitHub vs Codeberg
│   └── ollama-client.sh      # Ollama API wrapper
└── autostart/                # Autostart scripts
```

---

## Key Scripts

### watch-prs.sh

Main daemon that:
1. Loads configuration from `.env`
2. Polls repos every 60 seconds (configurable)
3. For each repo:
   - Gets open PRs (local + external for mirrors)
   - Checks if already reviewed (by SHA)
   - If new/updated: fetches diff, calls Ollama, posts comment
   - Updates state file

**Usage**:
```bash
./watch-prs.sh                    # Daemon mode, 60s interval
./watch-prs.sh -i 30              # Custom interval
./watch-prs.sh -r owner/repo      # Watch specific repo
./watch-prs.sh --once             # Single cycle
```

### lib/build-prompt.py

Builds the prompt sent to Ollama. Uses environment variable `DIFF_CONTENT`.

**Input**: Git diff (via DIFF_CONTENT env var)

**Output**: Prompt text including:
- System role (Senior Principal Engineer)
- Review priorities
- Output format specification (JSON schema)
- Guidelines
- The diff

### lib/build-comment.py

Formats Ollama's JSON response into clean markdown.

**Input**: Ollama response (via REVIEW_JSON env var)

**Output**: Markdown comment with:
- Issues (severity + type tags)
- Suggestions
- Praise
- Summary
- Model attribution

Features:
- Extracts JSON from markdown code blocks
- Falls back gracefully if no valid JSON

### lib/json-escape.py

Safely escapes JSON string for API POST body.

### lib/update-state.py

Updates the review state file after successful posting.

---

## Configuration

### Environment Variables (.env)

| Variable | Description | Example |
|----------|-------------|---------|
| `FORGEJO_HOST` | Forgejo URL | `http://localhost:1234` |
| `FORGEJO_ADMIN_USER` | Admin username | `gbadmin` |
| `FORGEJO_ADMIN_PASSWORD` | Admin password | `forgejo-admin-1234!@#$` |
| `OLLAMA_HOST` | Ollama URL | `http://localhost:11434` |
| `OLLAMA_MODEL` | Model to use | `code-review` or `qwen2.5-coder:14b` |
| `CODEBERG_TOKEN` | Codeberg API token (for posting comments) | `...` |
| `GITHUB_PAT` | GitHub token (for posting comments) | `...` |
| `POLL_INTERVAL` | Poll interval in seconds | `60` |

### State File

Location: `runner-data/pr-reviews.json`

Format:
```json
{
  "reviewed": {
    "gbrennon/BitPill/79": {
      "sha": "59580ee...",
      "reviewed_at": "2026-04-04T06:06:11Z"
    }
  }
}
```

---

## Platform Detection

The system detects the original platform from repo metadata:

| Field | Platform |
|-------|----------|
| `website` contains `github.com` | GitHub |
| `website` contains `codeberg.org` | Codeberg |
| `original_url` contains `codeberg.org` | Codeberg |
| `original_url` contains `github.com` | GitHub |

API endpoints:
- GitHub: `https://api.github.com/repos/{owner}/{repo}/...`
- Codeberg: `https://codeberg.org/api/v1/repos/{owner}/{repo}/...`

---

## Review Output Format

### Expected Ollama JSON (code-review model):

```json
{
  "issues": [
    {"file": "src/auth.py", "line": "45", "severity": "high", "type": "solid", "description": "UserService has multiple responsibilities"}
  ],
  "suggestions": [
    {"file": "src/auth.py", "line": "120", "description": "Extract magic number 86400 to named constant"}
  ],
  "praise": [
    {"file": "src/auth.py", "description": "Clean separation of concerns in token generation"}
  ],
  "summary": "Good overall structure with a few SOLID violations that should be addressed."
}
```

### Formatted Comment Output:

```markdown
## AI Code Review

### Issues
- [HIGH] [solid] src/auth.py:45: UserService has multiple responsibilities

### Suggestions
- src/auth.py:120: Extract magic number 86400 to named constant

### Praise
- src/auth.py: Clean separation of concerns in token generation

**Summary:** Good overall structure with a few SOLID violations that should be addressed.

---
*Review by code-review via local Forgejo*
```

---

## Ollama Model

### Recommended: code-review

Built on `phi4:latest` with:
- System prompt defining review behavior
- Code review guidelines knowledge base
- Focus on SOLID, architecture, code smells
- Structured JSON output

### Alternative: qwen2.5-coder:14b

General-purpose code model. Works but may not be as focused on architecture review.

### Building the model

```bash
# In gb-ollama-container repo
./scripts/build-modelfiles.sh

# Or manually
docker exec ollama ollama create code-review -f /tmp/code-review.Modelfile
```

### Using the model

Set in `.env`:
```bash
OLLAMA_MODEL=code-review
```

Or when running:
```bash
OLLAMA_MODEL=code-review ./scripts/watch-prs.sh
```

---

## Troubleshooting

### No PRs found

1. Check repo is mirrored: `curl "${FORGEJO_HOST}/api/v1/repos/${repo}" | jq '.mirror, .original_url'`
2. Verify API token has read access

### Review not posting

1. Check CODEBERG_TOKEN or GITHUB_PAT is set
2. Verify token has repo scope (write access to issues)
3. Check logs: `tail -f watch-prs.log`

### Ollama request failed

1. Verify Ollama is running: `curl http://localhost:11434/api/tags`
2. Check model exists: `ollama list`
3. Try manually: `echo "$diff" | ollama run code-review`

### JSON parsing errors

The system includes fallback handling:
- If Ollama returns markdown-wrapped JSON, it extracts the JSON
- If no valid JSON found, treats response as summary text

Check logs for debug output.

---

## Related Documentation

- `docs/pr-reviewer-design.md` - Original design document
- `docs/ai-code-review-analysis.md` - Initial analysis
- `docs/ai-code-review-workflow-guide.md` - Usage guide
- `gb-ollama-container/docs/code-review-model.md` - Model documentation
- `gb-ollama-container/prompts/code-review.txt` - System prompt
- `gb-ollama-container/knowledges/base/code_review_guidelines.md` - Review guidelines
