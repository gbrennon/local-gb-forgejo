#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

cd "${PROJECT_ROOT}"

echo -e "${GREEN}=== Debugging Forgejo Runners ===${NC}\n"

# Check each runner's logs
runners=("forgejo-runner" "forgejo-runner-tiny" "forgejo-runner-small" "forgejo-runner-medium")

for runner in "${runners[@]}"; do
    echo -e "${BLUE}=== ${runner} ===${NC}"

    # Get full logs
    podman logs "${runner}" 2>&1 || echo -e "${RED}No logs available${NC}"

    echo -e "\n${YELLOW}---${NC}\n"
done

# Check Podman socket permissions
echo -e "${BLUE}=== Podman Socket Info ===${NC}"
ls -la "${XDG_RUNTIME_DIR}/podman/podman.sock"

# Test socket from host
echo -e "\n${BLUE}=== Test Socket from Host ===${NC}"
curl --unix-socket "${XDG_RUNTIME_DIR}/podman/podman.sock" http://localhost/v1.0.0/libpod/info 2>&1 | head -20

# Check if tokens are set
echo -e "\n${BLUE}=== Check Tokens in .env ===${NC}"
if [[ -f .env ]]; then
    grep -E "^RUNNER_TOKEN" .env || echo -e "${YELLOW}No runner tokens found in .env${NC}"
else
    echo -e "${RED}.env file not found${NC}"
fi

# Check secret file
echo -e "\n${BLUE}=== Check Secret File ===${NC}"
if [[ -f forgejo_secret.txt ]]; then
    echo -e "${GREEN}✓ forgejo_secret.txt exists${NC}"
    wc -c forgejo_secret.txt
else
    echo -e "${RED}✗ forgejo_secret.txt not found${NC}"
fi
