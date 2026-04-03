#!/bin/bash
# Shared helpers — source this file; do not execute directly.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TERRAFORM_INFRA_DIR="$REPO_ROOT/terraform/infra"
TERRAFORM_CLUSTER_DIR="$REPO_ROOT/terraform/cluster"

# ── Env var helpers ───────────────────────────────────────────────────────────

require_env() {
    local var="$1"
    if [ -z "${!var:-}" ]; then
        echo "Error: \$$var is required. Set it in your environment or .envrc." >&2
        exit 1
    fi
}

check_required_env() {
    # Accept GOOGLE_PROJECT as an alias for PROJECT_ID (gcloud default env var)
    if [ -z "${PROJECT_ID:-}" ] && [ -n "${GOOGLE_PROJECT:-}" ]; then
        export PROJECT_ID="$GOOGLE_PROJECT"
    fi
    require_env PROJECT_ID
    require_env TF_STATE_BUCKET
}

# ── Git URL parsing ───────────────────────────────────────────────────────────

# Parse a git URL (SSH or HTTPS) into components.
# Sets: PARSED_HOST, PARSED_OWNER, PARSED_REPO, HTTPS_CLONE_URL
parse_git_url() {
    local url="$1"
    if [[ "$url" =~ ^git@([^:]+):([^/]+)/(.+)$ ]]; then
        PARSED_HOST="${BASH_REMATCH[1]}"
        PARSED_OWNER="${BASH_REMATCH[2]}"
        PARSED_REPO="${BASH_REMATCH[3]%.git}"
        HTTPS_CLONE_URL="https://${PARSED_HOST}/${PARSED_OWNER}/${PARSED_REPO}.git"
    elif [[ "$url" =~ ^https://([^/]+)/([^/]+)/(.+)$ ]]; then
        PARSED_HOST="${BASH_REMATCH[1]}"
        PARSED_OWNER="${BASH_REMATCH[2]}"
        PARSED_REPO="${BASH_REMATCH[3]%.git}"
        HTTPS_CLONE_URL="https://${PARSED_HOST}/${PARSED_OWNER}/${PARSED_REPO}.git"
    else
        echo "Error: cannot parse git URL: $url" >&2
        exit 1
    fi
}

# Derive git provider name from the parsed host
git_provider_from_host() {
    case "$1" in
        github.com) echo "github" ;;
        *)          echo "" ;;
    esac
}

# ── Terraform wrappers ────────────────────────────────────────────────────────

# Initialize infra Terraform (idempotent)
infra_tf_init() {
    terraform -chdir="$TERRAFORM_INFRA_DIR" init -reconfigure \
        -backend-config="bucket=${TF_STATE_BUCKET}" \
        -backend-config="prefix=infra" \
        -input=false -no-color | grep -v "^$" || true
}

# Run arbitrary terraform commands against infra
infra_tf() {
    infra_tf_init
    terraform -chdir="$TERRAFORM_INFRA_DIR" "$@"
}

# Get a single output value from infra state
infra_output() {
    terraform -chdir="$TERRAFORM_INFRA_DIR" output -raw "$1" 2>/dev/null
}

# Initialize cluster Terraform for a given cluster name (idempotent)
cluster_tf_init() {
    local cluster_name="$1"
    terraform -chdir="$TERRAFORM_CLUSTER_DIR" init -reconfigure \
        -backend-config="bucket=${TF_STATE_BUCKET}" \
        -backend-config="prefix=clusters/${cluster_name}" \
        -input=false -no-color | grep -v "^$" || true
}

# Run arbitrary terraform commands against a cluster
cluster_tf() {
    local cluster_name="$1"
    shift
    cluster_tf_init "$cluster_name"
    terraform -chdir="$TERRAFORM_CLUSTER_DIR" "$@"
}

# Get a single output value from a cluster state
cluster_output() {
    local cluster_name="$1"
    local key="$2"
    cluster_tf_init "$cluster_name" >/dev/null 2>&1
    terraform -chdir="$TERRAFORM_CLUSTER_DIR" output -raw "$key" 2>/dev/null
}

# ── Cluster var-file helpers ──────────────────────────────────────────────────

# Path in GCS where we store the cluster var file for later destroy/rebuild
cluster_vars_gcs_path() {
    local cluster_name="$1"
    echo "gs://${TF_STATE_BUCKET}/clusters/${cluster_name}/cluster.tfvars"
}

save_cluster_vars() {
    local cluster_name="$1"
    local vars_file="$2"
    gsutil cp "$vars_file" "$(cluster_vars_gcs_path "$cluster_name")"
}

load_cluster_vars() {
    local cluster_name="$1"
    local dest="$2"
    gsutil cp "$(cluster_vars_gcs_path "$cluster_name")" "$dest" 2>/dev/null || {
        echo "Error: no saved vars for cluster '$cluster_name'. Was it deployed with deploy.sh?" >&2
        exit 1
    }
}

# ── Cloud DNS helpers ─────────────────────────────────────────────────────────

# Create (or replace) an A record in a Cloud DNS managed zone.
create_dns_record() {
    local zone="$1" fqdn="$2" ip="$3"
    # Delete first to make this idempotent
    gcloud dns record-sets delete "${fqdn}." \
        --zone="$zone" --type=A --project="$PROJECT_ID" --quiet 2>/dev/null || true
    gcloud dns record-sets create "${fqdn}." \
        --zone="$zone" --type=A --ttl=60 \
        --rrdatas="$ip" --project="$PROJECT_ID"
    echo "DNS: ${fqdn} → ${ip}"
}

# Delete an A record from a Cloud DNS managed zone (no-op if not found).
delete_dns_record() {
    local zone="$1" fqdn="$2"
    gcloud dns record-sets delete "${fqdn}." \
        --zone="$zone" --type=A --project="$PROJECT_ID" --quiet 2>/dev/null \
        && echo "DNS record deleted: ${fqdn}" \
        || echo "No DNS record found for ${fqdn} — skipping."
}

# ── Git provider deploy key management ───────────────────────────────────────

# Register a read-only deploy key on GitHub.
# Usage: create_deploy_key <cluster_name> <public_key> <provider> <owner> <repo> <token>
# Prints the key ID on stdout.
create_deploy_key() {
    local cluster_name="$1"
    local public_key="$2"
    local provider="$3"
    local owner="$4"
    local repo="$5"
    local token="$6"
    local title="cluster-${cluster_name}"
    local response key_id

    case "$provider" in
        github)
            response=$(curl -s -X POST \
                -H "Authorization: token ${token}" \
                -H "Content-Type: application/json" \
                -d "{\"title\":\"${title}\",\"key\":\"${public_key}\",\"read_only\":true}" \
                "https://api.github.com/repos/${owner}/${repo}/keys")
            key_id=$(echo "$response" | jq -r '.id')
            ;;
        *)
            echo "Error: unknown provider '${provider}'. Only GitHub is supported." >&2
            exit 1
            ;;
    esac

    if [ -z "$key_id" ] || [ "$key_id" = "null" ]; then
        echo "Error: failed to create deploy key. Response: $response" >&2
        exit 1
    fi
    echo "$key_id"
}

# Revoke a deploy key from GitHub.
# Usage: revoke_deploy_key <key_id> <provider> <owner> <repo> <token>
revoke_deploy_key() {
    local key_id="$1"
    local provider="$2"
    local owner="$3"
    local repo="$4"
    local token="$5"

    case "$provider" in
        github)
            curl -sf -X DELETE \
                -H "Authorization: token ${token}" \
                "https://api.github.com/repos/${owner}/${repo}/keys/${key_id}" \
                && echo "Deploy key ${key_id} revoked from GitHub." \
                || echo "Warning: could not revoke GitHub deploy key ${key_id}." >&2
            ;;
    esac
}
