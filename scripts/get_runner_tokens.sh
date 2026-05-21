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

echo -e "${GREEN}=== Get Runner Registration Tokens ===${NC}\n"

# Check if jq is installed
if ! command -v jq &> /dev/null; then
    echo -e "${RED}Error: jq is not installed${NC}"
    echo "Install it with: sudo dnf install jq"
    exit 1
fi

# Check if ADMIN_TOKEN is set
if [[ -z "${ADMIN_TOKEN:-}" ]]; then
    echo -e "${YELLOW}ADMIN_TOKEN environment variable not set${NC}\n"
    echo "Steps to get an admin token:"
    echo "1. Go to: https://forgejo.local:1234/user/settings/applications"
    echo "2. Generate New Token"
    echo "3. Select scopes: admin:org, admin:runner"
    echo "4. Copy the token and run:"
    echo -e "\n${GREEN}export ADMIN_TOKEN='your_token_here'${NC}"
    echo -e "${GREEN}./scripts/get_runner_tokens.sh${NC}\n"
    exit 1
fi

FORGEJO_URL="https://forgejo.local:1234"

echo -e "${BLUE}Generating runner registration tokens...${NC}\n"

# Function to get token
get_token() {
    local response
    response=$(curl -sk -X GET "${FORGEJO_URL}/api/v1/admin/runners/registration-token" \
        -H "Authorization: token ${ADMIN_TOKEN}" \
        -H "Content-Type: application/json" 2>&1)

    if echo "${response}" | jq -e '.token' > /dev/null 2>&1; then
        echo "${response}" | jq -r '.token'
    else
        echo "ERROR"
    fi
}

# Get tokens for each runner
echo -e "${YELLOW}Main Runner Token (save to forgejo_secret.txt):${NC}"
MAIN_TOKEN=$(get_token)
if [[ "${MAIN_TOKEN}" != "ERROR" ]]; then
    echo -e "${GREEN}${MAIN_TOKEN}${NC}"
    echo "${MAIN_TOKEN}" > forgejo_secret.txt
    chmod 600 forgejo_secret.txt
    echo -e "${GREEN}✓ Saved to forgejo_secret.txt${NC}\n"
else
    echo -e "${RED}Failed to get token. Check ADMIN_TOKEN and network${NC}\n"
fi

echo -e "${YELLOW}Tiny Runner Token (add to .env as RUNNER_TOKEN_TINY):${NC}"
TINY_TOKEN=$(get_token)
if [[ "${TINY_TOKEN}" != "ERROR" ]]; then
    echo -e "${GREEN}${TINY_TOKEN}${NC}\n"
else
    echo -e "${RED}Failed to get token${NC}\n"
fi

echo -e "${YELLOW}Small Runner Token (add to .env as RUNNER_TOKEN_SMALL):${NC}"
SMALL_TOKEN=$(get_token)
if [[ "${SMALL_TOKEN}" != "ERROR" ]]; then
    echo -e "${GREEN}${SMALL_TOKEN}${NC}\n"
else
    echo -e "${RED}Failed to get token${NC}\n"
fi

echo -e "${YELLOW}Medium Runner Token (add to .env as RUNNER_TOKEN_MEDIUM):${NC}"
MEDIUM_TOKEN=$(get_token)
if [[ "${MEDIUM_TOKEN}" != "ERROR" ]]; then
    echo -e "${GREEN}${MEDIUM_TOKEN}${NC}\n"
else
    echo -e "${RED}Failed to get token${NC}\n"
fi

# Update .env if all tokens were retrieved
if [[ "${TINY_TOKEN}" != "ERROR" && "${SMALL_TOKEN}" != "ERROR" && "${MEDIUM_TOKEN}" != "ERROR" ]]; then
    echo -e "${BLUE}Updating .env file...${NC}"

    # Backup existing .env
    if [[ -f .env ]]; then
        cp .env .env.backup
    fi

    # Update tokens in .env
    sed -i "s/^RUNNER_TOKEN_TINY=.*/RUNNER_TOKEN_TINY=${TINY_TOKEN}/" .env
    sed -i "s/^RUNNER_TOKEN_SMALL=.*/RUNNER_TOKEN_SMALL=${SMALL_TOKEN}/" .env
    sed -i "s/^RUNNER_TOKEN_MEDIUM=.*/RUNNER_TOKEN_MEDIUM=${MEDIUM_TOKEN}/" .env

    echo -e "${GREEN}✓ .env updated with runner tokens${NC}\n"
    echo -e "${BLUE}Next step:${NC}"
    echo -e "${GREEN}podman-compose up -d${NC}\n"
else
    echo -e "${YELLOW}Some tokens failed. Manually add them to .env:${NC}"
    echo "RUNNER_TOKEN_TINY=${TINY_TOKEN}"
    echo "RUNNER_TOKEN_SMALL=${SMALL_TOKEN}"
    echo "RUNNER_TOKEN_MEDIUM=${MEDIUM_TOKEN}"
fi
