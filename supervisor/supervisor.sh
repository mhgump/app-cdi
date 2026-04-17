#!/bin/bash
# Application Supervisor
#
# Runs as a systemd service on each cluster instance.
# Clones the git repo, builds the Docker image, runs the container,
# watches for crashes (restart), and polls instance metadata for rebuild triggers.
#
# Environment provided by /etc/supervisor/env (set during startup):
#   CLUSTER_NAME, GIT_REPO_URL, GIT_DEPLOY_KEY, APP_DIR,
#   CONTAINER_PORT, APP_PORT, CONTAINER_NAME,
#   INSTANCE_ID, REDIS_HOST, REDIS_PORT, REDIS_PREFIX, PROJECT_ID
#
# Container env is populated from instance metadata:
#   postgres-host, postgres-user, postgres-schema, postgres-password-secret,
#   redis-host, redis-port, redis-prefix
#
# supervisor-http runs alongside this script (separate systemd service) and serves
# /health, /health/local, and /metadata on CONTAINER_PORT, proxying everything
# else to the app container on APP_PORT.

set -euo pipefail

META_URL="http://metadata.google.internal/computeMetadata/v1"
META_HEADER="Metadata-Flavor: Google"

log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [supervisor] $*"; }
err()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [supervisor] ERROR: $*" >&2; }
meta() { curl -sf "${META_URL}/instance/attributes/$1" -H "$META_HEADER" 2>/dev/null || true; }

# ── Validate required env vars ────────────────────────────────────────────────

: "${CLUSTER_NAME:?CLUSTER_NAME not set}"
: "${GIT_REPO_URL:?GIT_REPO_URL not set}"
: "${APP_DIR:?APP_DIR not set}"
: "${CONTAINER_PORT:?CONTAINER_PORT not set}"
: "${APP_PORT:?APP_PORT not set}"
: "${PROJECT_ID:?PROJECT_ID not set}"
: "${CONTAINER_NAME:?CONTAINER_NAME not set}"

# GIT_DEPLOY_KEY is optional — omitted when the repo is public (HTTPS clone)
if [ -n "${GIT_DEPLOY_KEY:-}" ] && [ -f "${GIT_DEPLOY_KEY}" ]; then
    export GIT_SSH_COMMAND="ssh -i ${GIT_DEPLOY_KEY} -o StrictHostKeyChecking=no -o BatchMode=yes"
fi

# ── Helpers ───────────────────────────────────────────────────────────────────

# write_build_state writes the current build phase to /run/supervisor/build-state
# so supervisor-http can include it in /health and /metadata responses.
# Usage: write_build_state BUILDING [commit]
#        write_build_state IDLE
write_build_state() {
    mkdir -p /run/supervisor
    echo "$*" > /run/supervisor/build-state
}

fetch_env_file() {
    # Build /etc/supervisor/app.env with all secrets/config the container needs.
    # These are passed to `docker run --env-file`.
    # Note: PORT is set to APP_PORT (the container's internal port). supervisor-http
    # listens on CONTAINER_PORT and reverse-proxies to APP_PORT.
    local pg_password instance_id
    pg_password=$(gcloud secrets versions access latest \
        --secret="$(meta postgres-password-secret)" \
        --project="$PROJECT_ID" 2>/dev/null || true)

    # Resolve the GCP instance name for the app to display (falls back to hostname)
    instance_id=$(curl -sf "${META_URL}/instance/name" -H "$META_HEADER" 2>/dev/null || hostname)

    cat > /etc/supervisor/app.env <<EOF
CLUSTER_NAME=${CLUSTER_NAME}
INSTANCE_ID=${instance_id}
PORT=${APP_PORT}
POSTGRES_HOST=$(meta postgres-host)
POSTGRES_USER=$(meta postgres-user)
POSTGRES_PASSWORD=${pg_password}
POSTGRES_SCHEMA=$(meta postgres-schema)
REDIS_HOST=$(meta redis-host)
REDIS_PORT=$(meta redis-port)
REDIS_PREFIX=$(meta redis-prefix)
EOF
    chmod 600 /etc/supervisor/app.env
    log "App env file refreshed."
}

sync_repo() {
    local commit="${1:-}"
    mkdir -p "$APP_DIR"

    if [ ! -d "${APP_DIR}/.git" ]; then
        log "Cloning ${GIT_REPO_URL} ..."
        git clone "$GIT_REPO_URL" "$APP_DIR"
    else
        log "Fetching origin ..."
        git -C "$APP_DIR" fetch origin
    fi

    if [ -n "$commit" ] && [ "$commit" != "latest" ]; then
        log "Checking out ${commit} ..."
        git -C "$APP_DIR" checkout "$commit"
    else
        local branch
        branch=$(git -C "$APP_DIR" remote show origin | awk '/HEAD branch/{print $NF}')
        git -C "$APP_DIR" checkout "$branch"
        git -C "$APP_DIR" pull origin "$branch"
    fi

    log "Repo HEAD: $(git -C "$APP_DIR" rev-parse --short HEAD)"
}

build_image() {
    local build_context="$APP_DIR"
    local dockerfile_args=""

    local ctx dockerfile
    ctx=$(meta "build-context")
    dockerfile=$(meta "dockerfile")

    [ -n "$ctx" ]        && build_context="${APP_DIR}/${ctx}"
    [ -n "$dockerfile" ] && dockerfile_args="-f ${APP_DIR}/${dockerfile}"

    # Embed the git commit as a Docker label so supervisor-http can read it via
    # `docker inspect` and include it in /health and /metadata responses.
    local commit
    commit=$(git -C "$APP_DIR" rev-parse HEAD)

    log "Building Docker image (context: ${build_context}, commit: ${commit}) ..."
    # shellcheck disable=SC2086
    docker build \
        -t "${CONTAINER_NAME}:latest" \
        --label "git-commit=${commit}" \
        ${dockerfile_args} "${build_context}"
    log "Image built."
}

stop_container() {
    if docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
        log "Stopping old container ..."
        docker stop "$CONTAINER_NAME" 2>/dev/null || true
        docker rm   "$CONTAINER_NAME" 2>/dev/null || true
    fi
}

start_container() {
    # Bind to 127.0.0.1 only — supervisor-http owns the external-facing CONTAINER_PORT
    # and reverse-proxies inbound traffic to the app on APP_PORT.
    log "Starting container (internal port ${APP_PORT}) ..."
    docker run -d \
        --name "$CONTAINER_NAME" \
        --restart=no \
        -p "127.0.0.1:${APP_PORT}:${APP_PORT}" \
        --env-file /etc/supervisor/app.env \
        --label "cluster=${CLUSTER_NAME}" \
        "${CONTAINER_NAME}:latest"
    log "Container up: $(docker ps --filter "name=${CONTAINER_NAME}" --format '{{.Status}}')"
}

redeploy() {
    local commit="${1:-}"
    write_build_state "BUILDING ${commit}"
    fetch_env_file
    sync_repo "$commit"
    build_image
    stop_container
    start_container
    write_build_state "IDLE"
}

healthcheck() {
    if docker ps --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
        return 0  # healthy
    fi

    err "Container not running — restarting ..."
    # Try a cheap restart of the existing image first; fall back to full redeploy.
    if docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
        docker start "$CONTAINER_NAME" 2>/dev/null || redeploy
    else
        redeploy
    fi
}

# ── Main ──────────────────────────────────────────────────────────────────────

log "=== Supervisor starting (cluster: ${CLUSTER_NAME}) ==="
redeploy

LAST_TRIGGER=""
while true; do
    CURRENT_TRIGGER=$(meta "rebuild-trigger")

    if [ -n "$CURRENT_TRIGGER" ] && [ "$CURRENT_TRIGGER" != "$LAST_TRIGGER" ]; then
        log "Rebuild triggered: ${CURRENT_TRIGGER}"
        LAST_TRIGGER="$CURRENT_TRIGGER"

        # Trigger format: "<commit>-<timestamp>" or "latest-<timestamp>"
        COMMIT=$(echo "$CURRENT_TRIGGER" | sed 's/-[0-9]*$//')
        [ "$COMMIT" = "latest" ] && COMMIT=""

        redeploy "$COMMIT"
    fi

    healthcheck
    sleep 10
done
