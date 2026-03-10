#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
SECRET_FILE="forgejo_secret.txt"
RUNNER_STATE_FILE="/data/.runner"
FORGEJO_HOST_PORT="1234"
FORGEJO_ADMIN_USER="${FORGEJO_ADMIN_USER:-forgejo_admin}"
RUNNER_IMAGE="data.forgejo.org/forgejo/runner:9"

# Derive the compose project name the same way podman-compose / docker compose
# does: $COMPOSE_PROJECT_NAME env var, else basename of the working directory.
# Both runtimes prefix volume names with "<project>_".
COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-$(basename "$PWD")}"
RUNNER_VOLUME="${COMPOSE_PROJECT_NAME}_forgejo_runner_data"

# ---------------------------------------------------------------------------
# Shared common utilities
# ---------------------------------------------------------------------------
# shellcheck disable=SC1090
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" && pwd)/common.sh"

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
    die ".env file not found. Copy .env.example to .env and fill in values."
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

  info "podman socket missing at $sock — restarting podman.socket ..."
  if systemctl --user restart podman.socket 2>/dev/null; then
    local retries=10
    local i=0
    until [[ -S "$sock" ]]; do
      sleep 1
      i=$((i + 1))
      if [[ $i -ge $retries ]]; then
        die "podman socket did not appear after restart — will fall back to docker if available."
        return 0
      fi
    done
    info "podman socket ready."
  else
    warn "systemctl --user restart podman.socket failed — will fall back to docker if available."
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
    die "neither podman nor docker daemon is reachable."
  fi
  info "Detected container runtime: $CONTAINER_RUNTIME"
  info "Compose project: $COMPOSE_PROJECT_NAME  →  runner volume: $RUNNER_VOLUME"

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
    info "Removing container ${container} holding port ${port}..."
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
  # podman-compose starts ALL services in the pod regardless of the arguments
  # passed to 'up'. Stop the runner container immediately so it cannot race
  # against the registration step (it has no valid token yet and would
  # corrupt Forgejo's token state before bootstrap can register properly).
  $CONTAINER_RUNTIME stop forgejo-runner 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# wait_for_forgejo
# ---------------------------------------------------------------------------
wait_for_forgejo() {
  info "Waiting for Forgejo container to be healthy..."
  until $CONTAINER_RUNTIME inspect --format='{{.State.Health.Status}}' forgejo 2>/dev/null | grep -q "healthy"; do
    sleep 3
    info "still waiting..."
  done

  # Container is healthy but app.ini may not be written yet (INSTALL_LOCK boots
  # it automatically). Gate on the API actually responding before using the CLI.
  info "Waiting for Forgejo API to be ready..."
  local retries=20
  local i=0
  until curl -sf "${FORGEJO_HOST_URL}/api/v1/version" >/dev/null 2>&1; do
    sleep 3
    i=$((i + 1))
    if [[ $i -ge $retries ]]; then
      die "Forgejo API did not become ready — check: $CONTAINER_RUNTIME logs forgejo"
      exit 1
    fi
    info "API not ready yet... (${i}/${retries})"
  done

  info "Forgejo is ready."
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
# Returns 0 if the admin user was NEWLY created (Forgejo is fresh).
# Returns 1 if the admin user already existed.
# Exits the script on any unexpected failure.
# ---------------------------------------------------------------------------
ensure_admin_user() {
  info "Ensuring Forgejo admin user exists..."
  local output exit_code=0
  output=$($CONTAINER_RUNTIME exec --user git forgejo \
    forgejo admin user create \
      --username "${FORGEJO_ADMIN_USER}" \
      --password "${FORGEJO_ADMIN_PASSWORD}" \
      --email "${FORGEJO_ADMIN_USER}@local.dev" \
      --admin \
      --must-change-password=false 2>&1) || exit_code=$?

  if echo "$output" | grep -qE "already exists|name is reserved"; then
    info "Admin user '${FORGEJO_ADMIN_USER}' already exists."
    return 1
  fi

  if [[ $exit_code -ne 0 ]]; then
    die "Admin user creation failed (exit ${exit_code}): ${output}"
    exit 1
  fi

  [[ -n "$output" ]] && info "$output"
  return 0
}

# ---------------------------------------------------------------------------
# fetch_registration_token
# Prints the token to stdout; all other output goes to stderr.
# ---------------------------------------------------------------------------
fetch_registration_token() {
  info "Fetching runner registration token from Forgejo API..." >&2
  local tmpfile
  tmpfile=$(mktemp)
  local http_code
  http_code=$(curl -s \
    -o "$tmpfile" \
    -w "%{http_code}" \
    -u "${FORGEJO_ADMIN_USER}:${FORGEJO_ADMIN_PASSWORD}" \
    "${FORGEJO_HOST_URL}/api/v1/admin/runners/registration-token")
  local response
  response=$(cat "$tmpfile")
  rm -f "$tmpfile"

  if [[ "$http_code" != "200" ]]; then
    die "Token endpoint returned HTTP ${http_code} (expected 200)."
    die "Response body: ${response}"
    die "Hint: ensure admin user '${FORGEJO_ADMIN_USER}' exists and password is correct."
    exit 1
  fi

  local token
  token=$(echo "$response" | grep -o '"token":"[^"]*"' | cut -d'"' -f4)

  if [[ -z "$token" ]]; then
    die "Could not extract token from API response: ${response}"
    exit 1
  fi

  echo "$token"
}

# ---------------------------------------------------------------------------
# register_runner <token>
# Generates config and registers the runner, writing .runner into /data.
# Runs the registration container on the compose network so that:
#   1. The runner can resolve "forgejo" by container name (same as runtime).
#   2. The instance URL written into config.yml is http://forgejo:3000, which
#      the runner daemon also uses — no post-registration patching needed.
# This works identically for podman and docker because both runtimes create a
# "<project>_default" bridge network for the compose stack.
# ---------------------------------------------------------------------------
register_runner() {
  local token="$1"
  local compose_network="${COMPOSE_PROJECT_NAME}_default"

  echo "$token" > "$SECRET_FILE"
  info "Token saved to $SECRET_FILE"

  $CONTAINER_RUNTIME run --rm \
    -v "${RUNNER_VOLUME}:/data" \
    -w /data \
    --user 0:0 \
    --network "$compose_network" \
    "$RUNNER_IMAGE" \
    sh -c "forgejo-runner generate-config > /data/config.yml && \
      forgejo-runner register \
        -c /data/config.yml \
        --no-interactive \
        --instance 'http://forgejo:3000' \
        --name local-runner \
        --token '${token}' \
        --labels ubuntu-latest,linux/amd64"
}

# ---------------------------------------------------------------------------
# bootstrap_runner
# Idempotent: skips re-registration only when BOTH the .runner file exists
# AND Forgejo has existing state (admin user already existed).
# If Forgejo data was wiped (admin user newly created) but the runner volume
# still has a stale .runner, the stale file is cleared and runner re-registers.
# ---------------------------------------------------------------------------
bootstrap_runner() {
  local forgejo_is_fresh=false
  ensure_admin_user && forgejo_is_fresh=true || true

  if ! $forgejo_is_fresh && runner_is_registered; then
    info "Runner already registered, skipping."
    return
  fi

  if $forgejo_is_fresh && runner_is_registered; then
    info "Forgejo data reset detected — clearing stale runner credentials..."
    $CONTAINER_RUNTIME run --rm \
      -v "${RUNNER_VOLUME}:/data" \
      busybox \
      rm -f "${RUNNER_STATE_FILE}" 2>/dev/null || true
  fi

  local token
  token=$(fetch_registration_token)
  register_runner "$token"
  patch_runner_config
}

# ---------------------------------------------------------------------------
# patch_runner_config
# Sets container.network in config.yml so that job containers are attached to
# the compose network and can resolve the "forgejo" hostname by container name.
# Must be called after register_runner (which regenerates config.yml).
# ---------------------------------------------------------------------------
patch_runner_config() {
  local compose_network="${COMPOSE_PROJECT_NAME}_default"
  info "Patching runner config.yml: container.network = ${compose_network}"
  $CONTAINER_RUNTIME run --rm \
    -v "${RUNNER_VOLUME}:/data" \
    busybox \
    sed -i "s|^  network: \"\"$|  network: \"${compose_network}\"|" /data/config.yml
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
  info "Waiting for runner to connect to Forgejo..."
  local retries=20
  local i=0
  until $CONTAINER_RUNTIME logs forgejo-runner 2>&1 | grep -q "declared successfully"; do
    sleep 3
    i=$((i + 1))
    if [[ $i -ge $retries ]]; then
      die "runner did not connect within expected time."
      die "Check logs: $CONTAINER_RUNTIME logs forgejo-runner"
      exit 1
    fi
    info "still waiting for runner... (${i}/${retries})"
  done
  info "Runner connected."
}

# ---------------------------------------------------------------------------
# validate
# Post-boot assertions: volume file exists and API confirms runner is online.
# ---------------------------------------------------------------------------
validate_container() {
  info ""
  info "--- Validating deployment ---"

  # 1. .runner file in volume
  if runner_is_registered; then
    ok ".runner file present in volume"
  else
    die ".runner file missing from volume"
  fi

  # 2. Runner daemon confirmed connection in logs
  if $CONTAINER_RUNTIME logs forgejo-runner 2>&1 | grep -q "declared successfully"; then
    ok "Runner daemon declared itself to Forgejo"
  else
    die "Runner daemon has not declared itself — check: $CONTAINER_RUNTIME logs forgejo-runner"
  fi

  ok "--- All checks passed ---"
  info ""
  info "Forgejo:        ${FORGEJO_HOST_URL}"
  info "Actions UI:     ${FORGEJO_HOST_URL}/-/admin/runners"
  info "Runner logs:    $CONTAINER_RUNTIME logs -f forgejo-runner"
}


# ---------------------------------------------------------------------------
# start_watcher
# Launches watch-mirrors.sh as a persistent background host process.
# Idempotent: stops any existing watcher before starting a fresh one.
# ---------------------------------------------------------------------------
start_watcher() {
  local repo_root
  repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  local watcher="${repo_root}/watch-mirrors.sh"
  local pid_file="${repo_root}/watcher.pid"
  local log_file="${repo_root}/watcher.log"

  if [[ ! -f "$watcher" ]]; then
    warn "watch-mirrors.sh not found at ${watcher} — skipping watcher start."
    return
  fi

  # Stop any previously running watcher
  if [[ -f "$pid_file" ]]; then
    local old_pid
    old_pid=$(cat "$pid_file")
    if kill -0 "$old_pid" 2>/dev/null; then
      info "Stopping existing watcher (PID ${old_pid})..."
      kill "$old_pid" 2>/dev/null || true
      sleep 1
    fi
    rm -f "$pid_file"
  fi

  info "Starting mirror watcher in background..."
  nohup bash "$watcher" >> "$log_file" 2>&1 &
  local watcher_pid=$!
  echo "$watcher_pid" > "$pid_file"
  ok "Mirror watcher started (PID ${watcher_pid})"
  info "  Logs: tail -f ${log_file}"
  info "  Stop: kill \$(cat watcher.pid)"
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
main() {
  # Parse flags
  local skip_watcher=false
  for arg in "$@"; do
    case "$arg" in
      --no-watcher) skip_watcher=true ;;
    esac
  done

  load_env
  detect_runtime
  start_core_services
  wait_for_forgejo
  bootstrap_runner
  start_runner
  wait_for_runner
  validate_container

  if [[ "$skip_watcher" == false ]]; then
    start_watcher
  else
    info "Skipping watcher start (--no-watcher). Managed externally (e.g. systemd)."
  fi
}

main "$@"
