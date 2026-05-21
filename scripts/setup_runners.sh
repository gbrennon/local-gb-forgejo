#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

cd "${PROJECT_ROOT}"

echo -e "${GREEN}=== Forgejo Runners Setup ===${NC}\n"

# Check if .env exists
if [[ ! -f .env ]]; then
    echo -e "${YELLOW}Creating .env from env.example...${NC}"
    if [[ -f env.example ]]; then
        cp env.example .env
        echo -e "${RED}Please edit .env and set all required values${NC}"
        exit 1
    else
        cat > .env << 'EOF'
# Database
POSTGRES_DB=forgejo
POSTGRES_USER=forgejo
POSTGRES_PASSWORD=change_me_to_secure_password

# Runner tokens (get these from Forgejo admin panel after first start)
RUNNER_TOKEN_TINY=
RUNNER_TOKEN_SMALL=
RUNNER_TOKEN_MEDIUM=
EOF
        echo -e "${RED}Created .env file. Please set POSTGRES_PASSWORD and runner tokens${NC}"
        exit 1
    fi
fi

# Check if runner config exists
if [[ ! -f runner-data/config.yml ]]; then
    echo -e "${YELLOW}Creating runner-data/config.yml...${NC}"
    mkdir -p runner-data
    cat > runner-data/config.yml << 'EOF'
log:
  level: info
  job_level: info

runner:
  file: .runner
  capacity: 1
  envs: {}
  env_file: .env
  timeout: 3h
  shutdown_timeout: 3h
  insecure: true
  fetch_timeout: 5s
  fetch_interval: 2s
  report_interval: 1s
  labels: []

cache:
  enabled: true
  port: 0
  dir: ""
  external_server: ""
  secret: ""
  host: ""
  proxy_port: 0
  actions_cache_url_override: ""

container:
  network: ""
  enable_ipv6: false
  privileged: false
  options: ""
  workdir_parent: ""
  valid_volumes:
    - "**"
  docker_host: "-"
  force_pull: false
  force_rebuild: false

host:
  workdir_parent: ""
EOF
    echo -e "${GREEN}Created runner-data/config.yml${NC}"
fi

# Check Podman socket
echo -e "${BLUE}Checking Podman socket...${NC}"
if [[ ! -S "${XDG_RUNTIME_DIR}/podman/podman.sock" ]]; then
    echo -e "${YELLOW}Podman socket not found. Enabling...${NC}"
    systemctl --user enable --now podman.socket
    sleep 2
fi

if systemctl --user is-active --quiet podman.socket; then
    echo -e "${GREEN}✓ Podman socket is running${NC}"
else
    echo -e "${RED}✗ Podman socket failed to start${NC}"
    echo "Try: systemctl --user restart podman.socket"
    exit 1
fi

# Start only Forgejo and DB
echo -e "\n${GREEN}Starting Forgejo and database...${NC}"
podman-compose up -d forgejo forgejo-db

# Wait for Forgejo to be healthy
echo -e "${YELLOW}Waiting for Forgejo to be ready...${NC}"
for i in {1..60}; do
    if podman exec forgejo curl -fsk https://localhost:3000 > /dev/null 2>&1; then
        echo -e "\n${GREEN}✓ Forgejo is ready!${NC}"
        break
    fi
    if [[ $i -eq 60 ]]; then
        echo -e "\n${RED}✗ Forgejo failed to start within 2 minutes${NC}"
        echo "Check logs: podman-compose logs forgejo"
        exit 1
    fi
    echo -n "."
    sleep 2
done

echo -e "\n${GREEN}=== Next Steps ===${NC}\n"
echo -e "${BLUE}1.${NC} Access Forgejo at: ${YELLOW}https://forgejo.local:1234${NC}"
echo -e "${BLUE}2.${NC} Login as admin and go to: Settings > Applications"
echo -e "${BLUE}3.${NC} Generate New Token with scopes: ${YELLOW}admin:org, admin:runner${NC}"
echo -e "${BLUE}4.${NC} Get runner registration tokens:\n"
echo -e "${GREEN}export ADMIN_TOKEN='your_token_here'${NC}"
echo -e "${GREEN}curl -k -X GET 'https://forgejo.local:1234/api/v1/admin/runners/registration-token' \\
  -H \"Authorization: token \${ADMIN_TOKEN}\" | jq -r '.token'${NC}\n"
echo -e "${BLUE}5.${NC} Save main runner token to: ${YELLOW}forgejo_secret.txt${NC}"
echo -e "${BLUE}6.${NC} Update ${YELLOW}.env${NC} with: RUNNER_TOKEN_TINY, RUNNER_TOKEN_SMALL, RUNNER_TOKEN_MEDIUM"
echo -e "${BLUE}7.${NC} Run: ${GREEN}podman-compose up -d${NC}"
echo -e "${BLUE}8.${NC} Verify: ${GREEN}./scripts/verify_runners.sh${NC}\n"
