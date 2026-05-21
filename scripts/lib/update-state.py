#!/usr/bin/env python3
"""Update the PR review state file."""

import sys
import json
import os


def main():
    state_json = os.environ.get("STATE_JSON", "{}")
    repo = os.environ.get("REPO", "")
    pr_number = os.environ.get("PR_NUMBER", "")
    pr_sha = os.environ.get("PR_SHA", "")

    try:
        d = json.loads(state_json)
    except:
        d = {}

    key = f"{repo}/{pr_number}"
    if "reviewed" not in d:
        d["reviewed"] = {}
    d["reviewed"][key] = {
        "sha": pr_sha,
        "reviewed_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%SZ"),
    }

    print(json.dumps(d))


if __name__ == "__main__":
    from datetime import datetime, timezone

    main()
