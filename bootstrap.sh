#!/usr/bin/env bash
set -euo pipefail

SECRET_FILE="forgejo_secret.txt"
RUNNER_CONFIG="/data/config.yml"
FORGEJO_HOST_PORT="1234"
FORGEJO_ADMIN_USER="${FORGEJO_ADMIN_USER:-forgejo_admin}"

# ---------------------------------------------------------------------------
# Load .env file
# ---------------------------------------------------------------------------
ENV_FILE=".env"
if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck source=.env
  source "$ENV_FILE"
  set +a
else
  echo "ERROR: .env file not found. Copy .env.example to .env and fill in values." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Detect the actual container runtime by checking which daemon is reachable.
# ---------------------------------------------------------------------------
if podman info &>/dev/null 2>&1; then
  COMPOSE="podman-compose"
  CONTAINER_RUNTIME="podman"
elif docker info &>/dev/null 2>&1; then
  COMPOSE="docker compose"
  CONTAINER_RUNTIME="docker"
else
  echo "ERROR: neither podman nor docker daemon is reachable." >&2
  exit 1
fi
echo "Detected container runtime: $CONTAINER_RUNTIME"

# For runner registration: podman-compose run is outside the pod network,
# so we reach Forgejo via the host. Docker shares the compose network.
if [[ "$CONTAINER_RUNTIME" == "podman" ]]; then
  FORGEJO_INTERNAL_URL="http://host.containers.internal:${FORGEJO_HOST_PORT}"
else
  FORGEJO_INTERNAL_URL="http://forgejo:3000"
fi

FORGEJO_HOST_URL="http://localhost:${FORGEJO_HOST_PORT}"

# ---------------------------------------------------------------------------
# Wrapper: podman-compose creates pods — 'down' tears down the pod cleanly.
# docker compose up -d is idempotent natively.
# ---------------------------------------------------------------------------
compose_up() {
  if [[ "$CONTAINER_RUNTIME" == "podman" ]]; then
    $COMPOSE down 2>/dev/null || true
    $COMPOSE up --detach "$@"
  else
    $COMPOSE up -d "$@"
  fi
}

# Start core services
compose_up forgejo forgejo-db

echo "Waiting for Forgejo to be healthy..."
until $CONTAINER_RUNTIME inspect --format='{{.State.Health.Status}}' forgejo 2>/dev/null | grep -q "healthy"; do
  sleep 3
  echo "  still waiting..."
done
echo "Forgejo is ready."

# ---------------------------------------------------------------------------
# Idempotent: skip registration if runner config already exists in the volume
# ---------------------------------------------------------------------------
if $COMPOSE run --rm forgejo-runner sh -c "test -f $RUNNER_CONFIG" 2>/dev/null; then
  echo "Runner already registered, skipping."
else
  # ---------------------------------------------------------------------------
  # Ensure the Forgejo admin user exists (no-op if already created)
  # ---------------------------------------------------------------------------
  echo "Ensuring Forgejo admin user exists..."
  $CONTAINER_RUNTIME exec --user git forgejo \
    forgejo admin user create \
    --username "${FORGEJO_ADMIN_USER}" \
    --password "${FORGEJO_ADMIN_PASSWORD}" \
    --email "${FORGEJO_ADMIN_USER}@local.dev" \
    --admin \
    --must-change-password=false \
    2>&1 | grep -v -E "already exists|name is reserved" || true

  # ---------------------------------------------------------------------------
  # Fetch a runner registration token from the Forgejo API
  # ---------------------------------------------------------------------------
  echo "Fetching runner registration token from Forgejo API..."
  forgejo_secret=$(curl -sf \
    -u "${FORGEJO_ADMIN_USER}:${FORGEJO_ADMIN_PASSWORD}" \
    "${FORGEJO_HOST_URL}/api/v1/admin/runners/registration-token" \
    | grep -o '"token":"[^"]*"' \
    | cut -d'"' -f4)

  if [[ -z "$forgejo_secret" ]]; then
    echo "ERROR: failed to retrieve runner registration token." >&2
    exit 1
  fi

  echo "$forgejo_secret" > "$SECRET_FILE"
  echo "Token saved to $SECRET_FILE"

  # Generate a default config file, then register with labels
  $COMPOSE run --rm forgejo-runner \
    sh -c "forgejo-runner generate-config > /data/config.yml && \
      forgejo-runner register \
        -c /data/config.yml \
        --no-interactive \
        --instance '$FORGEJO_INTERNAL_URL' \
        --name local-runner \
        --token '$forgejo_secret' \
        --labels ubuntu-latest,linux/amd64"
fi

compose_up forgejo-runner
echo "All services are up."
