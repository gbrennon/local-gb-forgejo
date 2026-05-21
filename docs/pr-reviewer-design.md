# AI PR Reviewer Design

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                          watch-prs.sh                                       │
│   - Polls all repos for open PRs                                           │
│   - Compares SHA with last reviewed state                                   │
│   - Delegates to analyze-pr.sh for new/updated PRs                         │
└─────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                        analyze-pr.sh                                        │
│   - Fetches PR diff from local Forgejo                                     │
│   - Sends to local Ollama                                                  │
│   - Returns structured review                                              │
└─────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                      post-review.sh                                        │
│   - Detects original platform (GitHub/Codeberg) from repo website         │
│   - Posts review comment to original PR                                    │
│   - Updates state file                                                     │
└─────────────────────────────────────────────────────────────────────────────┘
```

## File Structure

```
scripts/
├── watch-prs.sh              # Main watcher daemon
├── analyze-pr.sh            # Analyzes PR with Ollama
├── post-review.sh           # Posts to original platform
├── pr-state.json            # Tracks reviewed PRs
└── lib/
    ├── platform-detect.sh   # Detects GitHub vs Codeberg
    └── ollama-client.sh     # Ollama API wrapper
```

## Flow

```
                    ┌─────────────────┐
                    │   watch-prs.sh  │
                    │    (daemon)    │
                    └────────┬────────┘
                             │
              ┌──────────────┼──────────────┐
              ▼              ▼              ▼
        ┌──────────┐  ┌──────────┐  ┌──────────┐
        │ Repo A   │  │ Repo B   │  │ Repo C   │
        │ PR #1    │  │ PR #2    │  │ PR #3    │
        │ SHA: abc │  │ SHA: def │  │ SHA: ghi │
        └──────────┘  └──────────┘  └──────────┘
              │              │              │
              ▼              ▼              ▼
        ┌─────────────────────────────────────────────┐
        │  Check pr-state.json                         │
        │  - Same PR + Same SHA = skip                │
        │  - Same PR + New SHA = re-review             │
        │  - New PR = review                           │
        └─────────────────────────────────────────────┘
                             │
                             ▼ (if needs review)
                    ┌────────────────┐
                    │ analyze-pr.sh  │
                    │ - fetch diff   │
                    │ - call Ollama  │
                    │ - return json  │
                    └────────────────┘
                             │
                             ▼
                    ┌────────────────┐
                    │ post-review.sh│
                    │ - detect orig │
                    │ - post comment│
                    │ - update state│
                    └────────────────┘
                             │
                             ▼
                    ┌────────────────┐
                    │ Original PR    │
                    │ (GitHub/       │
                    │  Codeberg)     │
                    └────────────────┘
```

## State File Format

```json
{
  "reviewed": {
    "owner/repo/1": {
      "sha": "abc123...",
      "reviewed_at": "2026-04-03T23:00:00Z"
    },
    "owner/repo/2": {
      "sha": "def456...",
      "reviewed_at": "2026-04-03T22:30:00Z"
    }
  }
}
```

## Platform Detection

| Repo Website Field | Platform | API |
|-------------------|----------|-----|
| `github.com/...` | GitHub | `https://api.github.com` |
| `codeberg.org/...` | Codeberg | `https://codeberg.org/api/v1` |
| `forgejo.local/...` | Local | Skip (not external) |

## Example

```bash
# Watch for PRs
./watch-prs.sh -i 60

# Or manually test
./analyze-pr.sh gbrennon/BitPill 1
./post-review.sh gbrennon/BitPill 1 '{"issues": [...]}'
```
