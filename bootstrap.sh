#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
SECRET_FILE="forgejo_secret.txt"
RUNNER_STATE_FILE="/data/.runner"
FORGEJO_HOST_PORT="1234"
FORGEJO_ADMIN_USER="${FORGEJO_ADMIN_USER:-forgejo_admin}"

# Derive the compose project name the same way podman-compose / docker compose
# does: $COMPOSE_PROJECT_NAME env var, else basename of the working directory.
# Both runtimes prefix volume names with "<project>_".
COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-$(basename "$PWD")}"
RUNNER_VOLUME="${COMPOSE_PROJECT_NAME}_forgejo_runner_data"

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------
log_ok() {
  echo "[OK] $1"
}

log_fail() {
  echo "[FAIL] $1" >&2
}

log_error() {
  echo "ERROR: $1" >&2
}

log_warn() {
  echo "[WARN] $1" >&2
}

log_info() {
  echo "[INFO] $1"
}

# ---------------------------------------------------------------------------
# load_env
# ---------------------------------------------------------------------------
load_env() {
  local env_file=".env"
  if [[ -f "$env_file" ]]; then
    set -a
    # shellcheck source=.env
    source "$env_file"
    set +a
  else
    log_error ".env file not found. Copy .env.example to .env and fill in values."
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# ensure_podman_socket
# After a reboot /run is cleared, so podman.sock disappears even though
# podman.socket is enabled. Restart the unit to recreate the socket file.
# ---------------------------------------------------------------------------
ensure_podman_socket() {
  command -v podman &>/dev/null || return 0  # podman not installed — skip

  local sock="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/podman/podman.sock"
  [[ -S "$sock" ]] && return 0  # socket already present — nothing to do

  log_info "podman socket missing at $sock — restarting podman.socket ..."
  if systemctl --user restart podman.socket 2>/dev/null; then
    local retries=10
    local i=0
    until [[ -S "$sock" ]]; do
      sleep 1
      i=$((i + 1))
      if [[ $i -ge $retries ]]; then
        log_warn "podman socket did not appear after restart — will fall back to docker if available."
        return 0
      fi
    done
    log_info "podman socket ready."
  else
    log_warn "systemctl --user restart podman.socket failed — will fall back to docker if available."
  fi
}

# ---------------------------------------------------------------------------
# detect_runtime
# Sets globals: COMPOSE, CONTAINER_RUNTIME, FORGEJO_INTERNAL_URL,
#               FORGEJO_HOST_URL
# ---------------------------------------------------------------------------
detect_runtime() {
  ensure_podman_socket

  if podman info &>/dev/null 2>&1; then
    COMPOSE="podman-compose"
    CONTAINER_RUNTIME="podman"
  elif docker info &>/dev/null 2>&1; then
    COMPOSE="docker compose"
    CONTAINER_RUNTIME="docker"
  else
    log_error "neither podman nor docker daemon is reachable."
    exit 1
  fi
  log_info "Detected container runtime: $CONTAINER_RUNTIME"
  log_info "Compose project: $COMPOSE_PROJECT_NAME  →  runner volume: $RUNNER_VOLUME"

  # For runner registration: podman-compose run is outside the pod network,
  # so we reach Forgejo via the host. Docker shares the compose network.
  if [[ "$CONTAINER_RUNTIME" == "podman" ]]; then
    FORGEJO_INTERNAL_URL="http://host.containers.internal:${FORGEJO_HOST_PORT}"
  else
    FORGEJO_INTERNAL_URL="http://forgejo:3000"
  fi

  FORGEJO_HOST_URL="http://localhost:${FORGEJO_HOST_PORT}"
}

# ---------------------------------------------------------------------------
# kill_port <port>
# Forcefully removes any container currently binding the given host port.
# Needed because podman-compose down only removes containers it tracks by
# name — leftover containers with generated names (e.g. from a previous run)
# are silently skipped, leaving the port bound.
# ---------------------------------------------------------------------------
kill_port() {
  local port="$1"
  local container
  container=$(
    $CONTAINER_RUNTIME ps --format "{{.Names}} {{.Ports}}"       | awk -v p=":${port}->" '$0 ~ p {print $1}'       | head -1
  )
  if [[ -n "$container" ]]; then
    log_info "Removing container ${container} holding port ${port}..."
    $CONTAINER_RUNTIME rm -f "$container" 2>/dev/null || true
  fi
}

# ---------------------------------------------------------------------------
# compose_up [service ...]
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

# ---------------------------------------------------------------------------
# start_core_services
# ---------------------------------------------------------------------------
start_core_services() {
  compose_up forgejo forgejo-db
}

# ---------------------------------------------------------------------------
# wait_for_forgejo
# ---------------------------------------------------------------------------
wait_for_forgejo() {
  log_info "Waiting for Forgejo to be healthy..."
  until $CONTAINER_RUNTIME inspect --format='{{.State.Health.Status}}' forgejo 2>/dev/null | grep -q "healthy"; do
    sleep 3
    log_info "still waiting..."
  done
  log_info "Forgejo is ready."
}

# ---------------------------------------------------------------------------
# runner_is_registered
# Checks the volume directly via the container runtime — does not rely on
# compose run exit codes, which are unreliable in podman when the container
# hasn't been started yet.
# Returns 0 if registered, 1 otherwise.
# ---------------------------------------------------------------------------
runner_is_registered() {
  $CONTAINER_RUNTIME run --rm \
    -v "${RUNNER_VOLUME}:/data" \
    busybox \
    test -f "$RUNNER_STATE_FILE" 2>/dev/null
}

# ---------------------------------------------------------------------------
# ensure_admin_user
# ---------------------------------------------------------------------------
ensure_admin_user() {
  log_info "Ensuring Forgejo admin user exists..."
  $CONTAINER_RUNTIME exec --user git forgejo \
    forgejo admin user create \
      --username "${FORGEJO_ADMIN_USER}" \
      --password "${FORGEJO_ADMIN_PASSWORD}" \
      --email "${FORGEJO_ADMIN_USER}@local.dev" \
      --admin \
      --must-change-password=false \
    2>&1 | grep -v -E "already exists|name is reserved" || true
}

# ---------------------------------------------------------------------------
# fetch_registration_token
# Prints the token to stdout; all other output goes to stderr.
# ---------------------------------------------------------------------------
fetch_registration_token() {
  log_info "Fetching runner registration token from Forgejo API..."
  local token
  token=$(curl -sf \
    -u "${FORGEJO_ADMIN_USER}:${FORGEJO_ADMIN_PASSWORD}" \
    "${FORGEJO_HOST_URL}/api/v1/admin/runners/registration-token" \
    | grep -o '"token":"[^"]*"' \
    | cut -d'"' -f4)

  if [[ -z "$token" ]]; then
    log_error "failed to retrieve runner registration token."
    exit 1
  fi

  echo "$token"
}

# ---------------------------------------------------------------------------
# register_runner <token>
# Generates config and registers the runner, writing .runner into /data.
# Uses -w /data so the runner writes .runner to the persisted volume path
# without needing --runner-file (unsupported in runner:9).
# ---------------------------------------------------------------------------
register_runner() {
  local token="$1"

  echo "$token" > "$SECRET_FILE"
  log_info "Token saved to $SECRET_FILE"

  $COMPOSE run --rm -w /data forgejo-runner \
    sh -c "forgejo-runner generate-config > /data/config.yml && \
      forgejo-runner register \
        -c /data/config.yml \
        --no-interactive \
        --instance '$FORGEJO_INTERNAL_URL' \
        --name local-runner \
        --token '$token' \
        --labels ubuntu-latest,linux/amd64"
}

# ---------------------------------------------------------------------------
# bootstrap_runner
# Idempotent: skips registration if .runner already exists in the volume.
# ---------------------------------------------------------------------------
bootstrap_runner() {
  if runner_is_registered; then
    log_info "Runner already registered, skipping."
    return
  fi

  ensure_admin_user
  local token
  token=$(fetch_registration_token)
  register_runner "$token"
}

# ---------------------------------------------------------------------------
# start_runner
# ---------------------------------------------------------------------------
start_runner() {
  compose_up forgejo-runner
}

# ---------------------------------------------------------------------------
# wait_for_runner
# Polls until the runner logs show it has declared itself to Forgejo.
# ---------------------------------------------------------------------------
wait_for_runner() {
  log_info "Waiting for runner to connect to Forgejo..."
  local retries=20
  local i=0
  until $CONTAINER_RUNTIME logs forgejo-runner 2>&1 | grep -q "declared successfully"; do
    sleep 3
    i=$((i + 1))
    if [[ $i -ge $retries ]]; then
      log_error "runner did not connect within expected time."
      log_error "Check logs: $CONTAINER_RUNTIME logs forgejo-runner"
      exit 1
    fi
    log_info "still waiting for runner... (${i}/${retries})"
  done
  log_info "Runner connected."
}

# ---------------------------------------------------------------------------
# validate
# Post-boot assertions: volume file exists and API confirms runner is online.
# ---------------------------------------------------------------------------
validate_container() {
  echo ""
  log_info "--- Validating deployment ---"

  # 1. .runner file in volume
  if runner_is_registered; then
    log_ok ".runner file present in volume"
  else
    log_fail ".runner file missing from volume"
    exit 1
  fi

  # 2. Runner daemon confirmed connection in logs
  if $CONTAINER_RUNTIME logs forgejo-runner 2>&1 | grep -q "declared successfully"; then
    log_ok "Runner daemon declared itself to Forgejo"
  else
    log_fail "Runner daemon has not declared itself — check: $CONTAINER_RUNTIME logs forgejo-runner"
    exit 1
  fi

  log_ok "--- All checks passed ---"
  echo ""
  log_info "Forgejo:        ${FORGEJO_HOST_URL}"
  log_info "Actions UI:     ${FORGEJO_HOST_URL}/-/admin/runners"
  log_info "Runner logs:    $CONTAINER_RUNTIME logs -f forgejo-runner"
}


# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
main() {
  load_env
  detect_runtime
  start_core_services
  wait_for_forgejo
  bootstrap_runner
  start_runner
  wait_for_runner
  validate_container
}

main "$@"
