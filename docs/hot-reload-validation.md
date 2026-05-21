# Hot-Reload Validation Guide

This document explains how to validate that the hot-reload functionality is working correctly in your `local-gb-forgejo` setup.

## Quick Test: Verify Hot-Reload Is Working

### 1. Check Current Status

```bash
cd ~/repos/gbrennon/local-gb-forgejo
./scripts/reload.sh --status
```

Expected output:
```
[reload] Hot-reloadable processes:
  ✓ watch-prs: running (PID XXXXX)
  ✓ watcher-prs: running (PID XXXXX)
  ✓ watch-mirrors: running (PID XXXXX)
  ✓ watcher: running (PID XXXXX)
  ✓ migration-ai-controller: running (PID XXXXX)
```

### 2. Test Hot-Reload by Changing a Variable

```bash
cd ~/repos/gbrennon/local-gb-forgejo

# Current model
grep OLLAMA_MODEL .env
# Expected: OLLAMA_MODEL=code-review

# Change the model
sed -i 's/OLLAMA_MODEL=.*/OLLAMA_MODEL=phi4:latest/' .env

# Wait 10 seconds (auto-reload checks every 3 seconds)
# Check logs for model change
grep "Model:" ~/repos/gbrennon/local-gb-forgejo/watch-prs.log | tail -1
```

Expected: Model changes to phi4:latest automatically.

## Code Review Features

### Verdict (Approve/Request Changes)

The code review system automatically determines a verdict:
- **Approved** ✅ - No critical or high severity issues found
- **Changes Requested** ❌ - Critical or high severity issues found

The verdict is included in the review comment and (when supported) submitted as a formal review.

### Model Logging

Each review includes the model used:
```
---
*Review by code-review via local Forgejo*
```

You can see this in the logs:
```bash
grep "Model:" ~/repos/gbrennon/local-gb-forgejo/watch-prs.log | tail -1
```

## Verification Checklist

- [ ] All daemons running (`ps aux | grep watch`)
- [ ] Hot-reload initialization message in logs
- [ ] `./scripts/reload.sh --status` shows all processes
- [ ] Editing .env triggers automatic reload within 10 seconds
- [ ] Model used is logged in PR review comments
- [ ] Verdict (Approved/Changes Requested) is shown in comments

## Files Modified for Hot-Reload

| File | Change |
|------|--------|
| `scripts/lib/hot-reload.sh` | New - shared hot-reload library with auto-detect |
| `scripts/watch-prs.sh` | Added verdict support, model logging, hot-reload |
| `scripts/lib/build-comment.py` | Added verdict determination, model in footer |
| `scripts/reload.sh` | New - utility to trigger reloads |
| `scripts/autostart/autostart.sh` | Added `--reload` action |
