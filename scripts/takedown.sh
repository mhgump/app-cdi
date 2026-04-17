#!/bin/bash
# Tear down a cluster and clean up all associated resources:
#   - GCP infrastructure (MIG, LB, firewall, service account)
#   - Postgres schema for this cluster
#   - Redis keys for this cluster
#   - Git deploy key (GitHub)
#   - Secret Manager secrets
#
# Usage: ./scripts/takedown.sh --key <key> [--github-token <token>]
#
# Required env: PROJECT_ID (or GOOGLE_PROJECT), DNS_ZONE
# Optional env: TF_STATE_BUCKET (default: ${PROJECT_ID}-tfstate)
# Pass --github-token to automatically revoke the deploy key from GitHub.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

check_required_env

KEY=""
GITHUB_TOKEN_OPT=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --key)          KEY="$2";              shift 2 ;;
        --github-token) GITHUB_TOKEN_OPT="$2"; shift 2 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

if [ -z "$KEY" ]; then
    echo "Error: --key <key> is required." >&2
    echo "Usage: $0 --key <key> [--github-token <token>]" >&2
    exit 1
fi

CLUSTER_NAME="$KEY"

echo "About to tear down deployment: $KEY"
echo ""
echo "This will permanently destroy:"
echo "  - GCP infrastructure (MIG, load balancer, firewall rules, service account)"
echo "  - Postgres schema: ${KEY}"
echo "  - Redis keys:      ${KEY}:*"
echo "  - Deploy key in Secret Manager and git provider"
echo ""
read -rp "Type the key to confirm: " confirm
if [ "$confirm" != "$KEY" ]; then
    echo "Aborted."
    exit 0
fi

# ── Load saved var file ───────────────────────────────────────────────────────

VARS_FILE=$(mktemp /tmp/cluster-XXXXXX.tfvars)
trap 'rm -f "$VARS_FILE"' EXIT

echo "Loading cluster vars ..."
load_cluster_vars "$CLUSTER_NAME" "$VARS_FILE"

# Back-fill state_bucket if the saved var file predates this field
if ! grep -q '^state_bucket' "$VARS_FILE"; then
    echo "state_bucket = \"${TF_STATE_BUCKET}\"" >> "$VARS_FILE"
fi

# Extract values we need for cleanup
REGION=$(grep '^region' "$VARS_FILE" | awk -F'"' '{print $2}')
DOMAIN=$(grep '^domain' "$VARS_FILE" | awk -F'"' '{print $2}')
POSTGRES_HOST=$(grep '^postgres_host' "$VARS_FILE" | awk -F'"' '{print $2}')
POSTGRES_USER=$(grep '^postgres_user' "$VARS_FILE" | awk -F'"' '{print $2}')
POSTGRES_PASSWORD_SECRET=$(grep '^postgres_password_secret' "$VARS_FILE" | awk -F'"' '{print $2}')
REDIS_HOST=$(grep '^redis_host' "$VARS_FILE" | awk -F'"' '{print $2}')
REDIS_PORT=$(grep '^redis_port' "$VARS_FILE" | awk -F= '{print $2}' | tr -d ' ')

# ── Delete DNS record ─────────────────────────────────────────────────────────

if [ -n "$DOMAIN" ]; then
    require_env DNS_ZONE
    echo ""
    echo "Deleting DNS record: ${DOMAIN} ..."
    delete_dns_record "$DNS_ZONE" "$DOMAIN"
fi

# ── Destroy cluster infrastructure ────────────────────────────────────────────

echo ""
echo "Destroying cluster infrastructure ..."
cluster_tf "$CLUSTER_NAME" destroy \
    -var-file="$VARS_FILE" \
    -input=false \
    -auto-approve

echo "Infrastructure destroyed."

# ── Drop Postgres schema ──────────────────────────────────────────────────────

echo ""
echo "Action required — drop Postgres schema '${KEY}' manually:"
echo "  1. Retrieve the Postgres password:"
echo "     gcloud secrets versions access latest --secret=${POSTGRES_PASSWORD_SECRET} --project=${PROJECT_ID}"
echo "  2. Open Cloud SQL Studio in the GCP Console:"
echo "     https://console.cloud.google.com/sql/instances/aviad--appcdi--postgres/studio?project=${PROJECT_ID}"
echo "  3. Connect with user 'app', database 'postgres', and the password from step 1"
echo "  4. Run: DROP SCHEMA IF EXISTS \"${KEY}\" CASCADE;"

# ── Flush Redis keys ──────────────────────────────────────────────────────────

REDIS_PREFIX="${KEY}:"
echo ""
echo "Flushing Redis keys with prefix: $REDIS_PREFIX ..."

if [ -n "$REDIS_HOST" ]; then
    KEY_COUNT=$(redis-cli -h "$REDIS_HOST" -p "${REDIS_PORT:-6379}" \
        --scan --pattern "${REDIS_PREFIX}*" 2>/dev/null | wc -l | tr -d ' ')

    if [ "$KEY_COUNT" -gt 0 ]; then
        redis-cli -h "$REDIS_HOST" -p "${REDIS_PORT:-6379}" \
            --scan --pattern "${REDIS_PREFIX}*" \
            | xargs -r redis-cli -h "$REDIS_HOST" -p "${REDIS_PORT:-6379}" DEL
        echo "$KEY_COUNT key(s) deleted."
    else
        echo "No Redis keys found for this cluster."
    fi
else
    echo "Warning: REDIS_HOST not available — skipping Redis cleanup." >&2
fi

# ── Revoke git deploy key ─────────────────────────────────────────────────────

echo ""
echo "Revoking deploy key ..."

KEY_ID_SECRET="${CLUSTER_NAME}-deploy-key-id"
KEY_ID=$(gcloud secrets versions access latest \
    --secret="$KEY_ID_SECRET" \
    --project="$PROJECT_ID" 2>/dev/null || true)

if [ -n "$KEY_ID" ]; then
    TOKEN="$GITHUB_TOKEN_OPT"
    if [ -n "$TOKEN" ]; then
        # Parse the git URL from saved tfvars to get provider/owner/repo
        SAVED_GIT_URL=$(grep '^git_repo_url' "$VARS_FILE" | awk -F'"' '{print $2}')
        parse_git_url "$SAVED_GIT_URL"
        PROVIDER=$(git_provider_from_host "$PARSED_HOST")
        if [ -n "$PROVIDER" ]; then
            revoke_deploy_key "$KEY_ID" "$PROVIDER" "$PARSED_OWNER" "$PARSED_REPO" "$TOKEN"
        else
            echo "Warning: unrecognised git host '$PARSED_HOST' — deploy key $KEY_ID NOT revoked." >&2
            echo "  Revoke it manually from your git provider." >&2
        fi
    else
        echo "Warning: no token provided — deploy key ID $KEY_ID NOT revoked from GitHub." >&2
        echo "  Re-run with --github-token to revoke, or remove it manually." >&2
    fi
    gcloud secrets delete "$KEY_ID_SECRET" --project="$PROJECT_ID" --quiet 2>/dev/null || true
else
    echo "No stored deploy key ID found (public repo or manually registered key)."
fi

# Delete the private key secret
gcloud secrets delete "${CLUSTER_NAME}-deploy-key" \
    --project="$PROJECT_ID" --quiet 2>/dev/null && echo "Private key secret deleted." \
    || echo "Warning: could not delete private key secret." >&2

# ── Remove saved var file from GCS ────────────────────────────────────────────

gsutil rm "$(cluster_vars_gcs_path "$CLUSTER_NAME")" 2>/dev/null || true

echo ""
echo "Deployment '${KEY}' fully torn down."
