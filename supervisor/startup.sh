#!/bin/bash
# GCP Instance Startup Script  (Terraform template — do not run directly)
#
# Terraform injects:
#   $${supervisor_b64}          ← base64-encoded supervisor.sh
#   $${supervisor_http_gcs_uri} ← GCS URI of the compiled supervisor-http binary
#
# All other $${...} are escaped Terraform template syntax for literal bash $${}

set -euo pipefail
export HOME=/root

STARTUP_LOG="/var/log/startup.log"
exec > >(tee -a "$STARTUP_LOG") 2>&1

META_URL="http://metadata.google.internal/computeMetadata/v1"
META_HEADER="Metadata-Flavor: Google"

meta_attr()    { curl -sf "$${META_URL}/instance/attributes/$1" -H "$${META_HEADER}" 2>/dev/null || true; }
meta_project() { curl -sf "$${META_URL}/project/project-id" -H "$${META_HEADER}"; }

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [startup] $*"; }

# Fetch a secret from Secret Manager using the instance SA token (no gcloud needed)
fetch_secret() {
    local secret="$1"
    local token
    token=$(curl -sf "$${META_URL}/instance/service-accounts/default/token" \
        -H "$${META_HEADER}" | jq -r '.access_token')
    curl -sf \
        "https://secretmanager.googleapis.com/v1/projects/$${PROJECT_ID}/secrets/$${secret}/versions/latest:access" \
        -H "Authorization: Bearer $${token}" | jq -r '.payload.data' | base64 -d
}

log "=== Instance startup ==="

CLUSTER_NAME=$(meta_attr "cluster-name")
GIT_REPO_URL=$(meta_attr "git-repo-url")
GIT_DEPLOY_KEY_SECRET=$(meta_attr "git-deploy-key-secret")
CONTAINER_PORT=$(meta_attr "container-port")
PROJECT_ID=$(meta_project)

# APP_PORT is the internal port the app container listens on.
# supervisor-http listens on CONTAINER_PORT and reverse-proxies to APP_PORT.
APP_PORT=$((CONTAINER_PORT + 1))

# Resolve the instance name once at startup so both systemd services can use it.
INSTANCE_ID=$(curl -sf "$${META_URL}/instance/name" -H "$${META_HEADER}" 2>/dev/null || hostname)

# Redis config — read directly from instance metadata (same values supervisor.sh uses)
REDIS_HOST=$(meta_attr "redis-host")
REDIS_PORT=$(meta_attr "redis-port")
REDIS_PREFIX=$(meta_attr "redis-prefix")

log "Cluster: $CLUSTER_NAME | Port: $CONTAINER_PORT (app internal: $APP_PORT)"

# ── Packages ──────────────────────────────────────────────────────────────────

log "Installing packages ..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -qq -y docker.io git git-lfs curl jq

# Google Cloud SDK is pre-installed on GCP Debian images; install if missing.
if ! command -v gcloud &>/dev/null; then
    log "Installing gcloud SDK ..."
    apt-get install -qq -y apt-transport-https ca-certificates gnupg
    echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] \
https://packages.cloud.google.com/apt cloud-sdk main" \
        > /etc/apt/sources.list.d/google-cloud-sdk.list
    curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg \
        | gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg
    apt-get update -qq
    apt-get install -qq -y google-cloud-cli
fi

systemctl enable docker
systemctl start docker

# ── Git auth (private repos only) ────────────────────────────────────────────

GIT_TOKEN_SECRET=$(meta_attr "git-token-secret")
DEPLOY_KEY_PATH=""

if [ -n "$GIT_TOKEN_SECRET" ]; then
    log "Fetching GitHub token from Secret Manager ..."
    GIT_TOKEN=$(fetch_secret "$GIT_TOKEN_SECRET")
    GIT_REPO_URL=$(echo "$GIT_REPO_URL" | sed "s|https://|https://x-access-token:$${GIT_TOKEN}@|")
    log "Git credentials embedded in repo URL."
elif [ -n "$GIT_DEPLOY_KEY_SECRET" ]; then
    log "Fetching deploy key from Secret Manager ..."
    mkdir -p /root/.ssh
    fetch_secret "$GIT_DEPLOY_KEY_SECRET" > /root/.ssh/deploy_key
    chmod 600 /root/.ssh/deploy_key

    cat > /root/.ssh/config <<'SSHCONFIG'
Host *
    StrictHostKeyChecking no
    IdentityFile /root/.ssh/deploy_key
    BatchMode yes
SSHCONFIG
    chmod 600 /root/.ssh/config
    DEPLOY_KEY_PATH="/root/.ssh/deploy_key"
else
    log "No auth secret set — repo is public, cloning via HTTPS."
fi

# ── Supervisor env ─────────────────────────────────────────────────────────────
# This file is loaded by both supervisor.service and supervisor-http.service.

mkdir -p /etc/supervisor
cat > /etc/supervisor/env <<ENVFILE
CLUSTER_NAME="$CLUSTER_NAME"
GIT_REPO_URL="$GIT_REPO_URL"
GIT_DEPLOY_KEY="$DEPLOY_KEY_PATH"
APP_DIR="/opt/app"
CONTAINER_PORT="$CONTAINER_PORT"
APP_PORT="$APP_PORT"
PROJECT_ID="$PROJECT_ID"
CONTAINER_NAME="app"
INSTANCE_ID="$INSTANCE_ID"
REDIS_HOST="$REDIS_HOST"
REDIS_PORT="$REDIS_PORT"
REDIS_PREFIX="$REDIS_PREFIX"
ENVFILE

# ── Install supervisor binary ──────────────────────────────────────────────────

log "Installing supervisor ..."
echo "${supervisor_b64}" | base64 -d > /usr/local/bin/supervisor
chmod +x /usr/local/bin/supervisor

# ── Install supervisor-http binary ────────────────────────────────────────────
# The pre-compiled linux/amd64 binary is stored in GCS by deploy.sh.

log "Downloading supervisor-http from ${supervisor_http_gcs_uri} ..."
gcloud storage cp "${supervisor_http_gcs_uri}" /usr/local/bin/supervisor-http
chmod +x /usr/local/bin/supervisor-http

# ── Systemd services ───────────────────────────────────────────────────────────

cat > /etc/systemd/system/supervisor.service <<'SERVICE'
[Unit]
Description=Application Supervisor
After=docker.service network-online.target
Wants=network-online.target docker.service

[Service]
Type=simple
EnvironmentFile=/etc/supervisor/env
ExecStart=/usr/local/bin/supervisor
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=supervisor

[Install]
WantedBy=multi-user.target
SERVICE

cat > /etc/systemd/system/supervisor-http.service <<'SERVICE'
[Unit]
Description=Supervisor HTTP (health + metadata endpoints)
After=docker.service network-online.target
Wants=network-online.target docker.service

[Service]
Type=simple
EnvironmentFile=/etc/supervisor/env
ExecStart=/usr/local/bin/supervisor-http
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=supervisor-http

[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload
systemctl enable supervisor
systemctl enable supervisor-http
systemctl start supervisor
systemctl start supervisor-http

log "=== Startup complete ==="
