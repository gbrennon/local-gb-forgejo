#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

cd "${PROJECT_ROOT}"

echo -e "${GREEN}=== Restarting Forgejo Runners ===${NC}\n"

runners=("forgejo-runner" "runner-tiny" "runner-small" "runner-medium")

if [[ $# -gt 0 ]]; then
    # Restart specific runner(s)
    for runner in "$@"; do
        echo -e "${BLUE}Restarting ${runner}...${NC}"
        podman-compose restart "${runner}"
    done
else
    # Restart all runners
    for runner in "${runners[@]}"; do
        echo -e "${BLUE}Restarting ${runner}...${NC}"
        podman-compose restart "${runner}"
    done
fi

echo -e "\n${GREEN}✓ Done${NC}"
echo -e "Check status: ${BLUE}./scripts/verify_runners.sh${NC}"
