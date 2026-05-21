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

echo -e "${GREEN}=== Fixing Runner Issues ===${NC}\n"

# 1. Check tokens
echo -e "${BLUE}1. Checking tokens...${NC}"
if [[ ! -f forgejo_secret.txt ]]; then
    echo -e "${RED}✗ forgejo_secret.txt missing${NC}"
    echo "Create it with: echo 'YOUR_TOKEN' > forgejo_secret.txt"
    exit 1
fi

if [[ ! -s forgejo_secret.txt ]]; then
    echo -e "${RED}✗ forgejo_secret.txt is empty${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Main runner secret exists${NC}"

# Check .env tokens
source .env
if [[ -z "${RUNNER_TOKEN_TINY:-}" ]]; then
    echo -e "${YELLOW}! RUNNER_TOKEN_TINY not set in .env${NC}"
fi
if [[ -z "${RUNNER_TOKEN_SMALL:-}" ]]; then
    echo -e "${YELLOW}! RUNNER_TOKEN_SMALL not set in .env${NC}"
fi
if [[ -z "${RUNNER_TOKEN_MEDIUM:-}" ]]; then
    echo -e "${YELLOW}! RUNNER_TOKEN_MEDIUM not set in .env${NC}"
fi

# 2. Fix Podman socket permissions
echo -e "\n${BLUE}2. Checking Podman socket...${NC}"
if [[ -S "${XDG_RUNTIME_DIR}/podman/podman.sock" ]]; then
    echo -e "${GREEN}✓ Socket exists${NC}"

    # Set proper permissions
    chmod 666 "${XDG_RUNTIME_DIR}/podman/podman.sock" 2>/dev/null || true

    # Restart socket
    systemctl --user restart podman.socket
    echo -e "${GREEN}✓ Socket restarted${NC}"
else
    echo -e "${RED}✗ Socket not found${NC}"
    systemctl --user enable --now podman.socket
fi

# 3. Stop all runners
echo -e "\n${BLUE}3. Stopping all runners...${NC}"
podman-compose stop forgejo-runner forgejo-runner-tiny forgejo-runner-small forgejo-runner-medium || true

# 4. Remove runner data (registration files)
echo -e "\n${BLUE}4. Clearing old registration data...${NC}"
podman volume rm -f local-gb-forgejo_forgejo_runner_data || true
podman volume rm -f local-gb-forgejo_forgejo_runner_tiny || true
podman volume rm -f local-gb-forgejo_forgejo_runner_small || true
podman volume rm -f local-gb-forgejo_forgejo_runner_medium || true

echo -e "${GREEN}✓ Volumes cleared${NC}"

# 5. Start runners
echo -e "\n${BLUE}5. Starting runners...${NC}"
podman-compose up -d

# 6. Wait and check
echo -e "\n${BLUE}6. Waiting for runners to start...${NC}"
sleep 10

echo -e "\n${GREEN}=== Status ===${NC}"
podman-compose ps

echo -e "\n${BLUE}Check logs with:${NC}"
echo "  podman-compose logs -f forgejo-runner"
echo "  podman-compose logs -f forgejo-runner-tiny"
