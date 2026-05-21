#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

cd "${PROJECT_ROOT}"

echo -e "${GREEN}=== Verifying Forgejo Runners ===${NC}\n"

# Check containers
echo -e "${BLUE}Container Status:${NC}"
podman-compose ps

# Check Podman socket
echo -e "\n${BLUE}Podman Socket:${NC}"
if [[ -S "${XDG_RUNTIME_DIR}/podman/podman.sock" ]]; then
    echo -e "${GREEN}✓ Socket exists at: ${XDG_RUNTIME_DIR}/podman/podman.sock${NC}"
    if systemctl --user is-active --quiet podman.socket; then
        echo -e "${GREEN}✓ Socket is active${NC}"
    else
        echo -e "${RED}✗ Socket exists but service is not active${NC}"
    fi
else
    echo -e "${RED}✗ Socket not found${NC}"
    echo "Run: systemctl --user enable --now podman.socket"
fi

# Test Docker/Podman access from runner
echo -e "\n${BLUE}Docker/Podman Access Test:${NC}"
if podman exec forgejo-runner docker ps > /dev/null 2>&1; then
    echo -e "${GREEN}✓ forgejo-runner can access Docker/Podman${NC}"
else
    echo -e "${RED}✗ forgejo-runner cannot access Docker/Podman${NC}"
fi

# Check runner logs
echo -e "\n${YELLOW}=== Recent Runner Logs ===${NC}\n"

for runner in forgejo-runner runner-tiny runner-small runner-medium; do
    echo -e "${GREEN}--- ${runner} ---${NC}"
    if podman ps --format '{{.Names}}' | grep -q "^${runner}$"; then
        # Check for registration status
        if podman logs "${runner}" 2>&1 | grep -q "Runner registered successfully"; then
            echo -e "${GREEN}✓ Registered successfully${NC}"
        elif podman logs "${runner}" 2>&1 | grep -q "register runner"; then
            echo -e "${YELLOW}! Registration in progress or failed${NC}"
        fi

        # Show last few lines
        podman logs "${runner}" 2>&1 | tail -5
        echo ""
    else
        echo -e "${RED}✗ Container not running${NC}\n"
    fi
done

# Summary
echo -e "${BLUE}=== Summary ===${NC}"
echo -e "Admin panel: ${YELLOW}https://forgejo.local:1234/admin/actions/runners${NC}"
echo -e "To check full logs: ${GREEN}podman-compose logs -f <container-name>${NC}"
echo -e "To restart a runner: ${GREEN}podman-compose restart <container-name>${NC}"
