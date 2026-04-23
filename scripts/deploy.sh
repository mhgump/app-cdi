#!/bin/bash
# Deploy a new cluster (or update an existing one).
#
# Usage:
#   ./scripts/deploy.sh --key <key> --repo <owner>/<repo> [options]
#
# The key is the primary identifier for a deployment. It determines:
#   - Domain:          <key>.<DNS_DOMAIN>  (e.g. kvstore.aviadtest.site)
#   - Postgres schema: <key>  (overridable with --data-namespace)
#   - Redis prefix:    <key>: (overridable with --data-namespace)
#
# --repo accepts:
#   owner/repo              GitHub repo
#
# Options:
#   --key           <key>    Deployment key — sets domain, Postgres schema, Redis prefix (required)
#   --data-namespace <ns>    Override Postgres schema and Redis prefix (default: same as key)
#   --repo          <o/r>    GitHub repo (required)
#   --machine-type  <type>   GCE machine type            (default: e2-standard-2)
#   --min           <n>      Min instances                (default: 1)
#   --max           <n>      Max instances                (default: 10)
#   --cpu-target    <0.0-1>  Autoscale CPU target         (default: 0.6)
#   --port          <n>      Container port               (default: 8080)
#   --build-context <path>   Subdirectory for Docker build context  (default: repo root)
#   --dockerfile    <path>   Path to Dockerfile relative to repo root (default: Dockerfile in build context)
#   --region        <name>   GCP region                   (default: us-central1)
#   --zones         <z1,z2>  Comma-separated zones        (default: all in region)
#   --disk-size     <gb>     Boot disk size in GB         (default: 50)
#   --github-token  <token>  GitHub PAT for deploy key registration (private repos only)
#   --mtls          <path>   Path to CA cert from gen-ca.sh; enforces mTLS on the HTTPS LB
#
# Required env: PROJECT_ID (or GOOGLE_PROJECT), DNS_DOMAIN, DNS_ZONE
# Optional env: TF_STATE_BUCKET (default: ${PROJECT_ID}-tfstate), REGION

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

check_required_env

# ── Args ──────────────────────────────────────────────────────────────────────

KEY=""
DATA_NAMESPACE=""
REPO_ARG=""
MACHINE_TYPE="e2-standard-2"
MIN_INSTANCES=1
MAX_INSTANCES=10
CPU_TARGET=0.6
CONTAINER_PORT=8080
BUILD_CONTEXT=""
DOCKERFILE=""
REGION="${REGION:-us-central1}"
ZONES=""
DISK_SIZE=50
GITHUB_TOKEN_OPT=""
MTLS_CA_CERT_PATH=""
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --key)            KEY="$2";              shift 2 ;;
        --data-namespace) DATA_NAMESPACE="$2";  shift 2 ;;
        --repo)           REPO_ARG="$2";        shift 2 ;;
        --machine-type)  MACHINE_TYPE="$2";     shift 2 ;;
        --min)           MIN_INSTANCES="$2";    shift 2 ;;
        --max)           MAX_INSTANCES="$2";    shift 2 ;;
        --cpu-target)    CPU_TARGET="$2";       shift 2 ;;
        --port)          CONTAINER_PORT="$2";   shift 2 ;;
        --build-context) BUILD_CONTEXT="$2";    shift 2 ;;
        --dockerfile)    DOCKERFILE="$2";       shift 2 ;;
        --region)        REGION="$2";           shift 2 ;;
        --zones)         ZONES="$2";            shift 2 ;;
        --disk-size)     DISK_SIZE="$2";        shift 2 ;;
        --github-token)  GITHUB_TOKEN_OPT="$2"; shift 2 ;;
        --mtls)          MTLS_CA_CERT_PATH="$2"; shift 2 ;;
        --dry-run)       DRY_RUN=true;           shift ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

if [ -z "$KEY" ]; then
    echo "Error: --key <key> is required." >&2
    echo "Usage: $0 --key <key> --repo <owner>/<repo> [options]" >&2
    exit 1
fi

if [ -z "$REPO_ARG" ]; then
    echo "Error: --repo <owner>/<repo> is required." >&2
    exit 1
fi

if [ -n "$MTLS_CA_CERT_PATH" ] && [ ! -f "$MTLS_CA_CERT_PATH" ]; then
    echo "Error: --mtls cert file not found: $MTLS_CA_CERT_PATH" >&2
    exit 1
fi

# Parse owner/repo
if [[ "$REPO_ARG" =~ ^([^/]+)/([^/]+)$ ]]; then
    PARSED_HOST="github.com"
    PARSED_OWNER="${BASH_REMATCH[1]}"
    PARSED_REPO="${BASH_REMATCH[2]}"
else
    echo "Error: --repo must be <owner>/<repo> (GitHub only)" >&2
    exit 1
fi

HTTPS_CLONE_URL="https://${PARSED_HOST}/${PARSED_OWNER}/${PARSED_REPO}.git"
GIT_REPO_URL="$HTTPS_CLONE_URL"

# ── Derive domain, cluster name, and namespaces from key ─────────────────────

require_env DNS_DOMAIN
require_env DNS_ZONE
CLUSTER_NAME="$KEY"
DOMAIN="${KEY}.${DNS_DOMAIN}"
NAMESPACE="${DATA_NAMESPACE:-$KEY}"
REVIEW_DIR="${REPO_ROOT}/review/${CLUSTER_NAME}"
DRY_RUN_SECRETS=()

echo "Deploying: $KEY"
echo "  Repo:      ${PARSED_HOST}/${PARSED_OWNER}/${PARSED_REPO}"
echo "  Region:    $REGION"
echo "  Type:      $MACHINE_TYPE  (${MIN_INSTANCES}–${MAX_INSTANCES} instances, CPU target ${CPU_TARGET})"
echo "  Domain:    https://${DOMAIN}"
echo "  Namespace: ${NAMESPACE}  (Postgres schema + Redis prefix)"
if [ -n "$MTLS_CA_CERT_PATH" ]; then
    echo "  mTLS:      enabled (CA cert: ${MTLS_CA_CERT_PATH})"
fi
echo ""

# ── Deploy key helpers ────────────────────────────────────────────────────────

# Returns 0 (true) if the repo is publicly accessible without credentials.
repo_is_public() {
    local host="$1" owner="$2" repo="$3"
    local response is_private

    if [ "$host" = "github.com" ]; then
        local api="https://api.github.com/repos/${owner}/${repo}"
        if [ -n "$GITHUB_TOKEN_OPT" ]; then
            response=$(curl -sf -H "Authorization: token ${GITHUB_TOKEN_OPT}" "$api" 2>/dev/null || true)
        else
            response=$(curl -sf "$api" 2>/dev/null || true)
        fi
        is_private=$(echo "$response" | jq -r '.private // "unknown"' 2>/dev/null || echo "unknown")
        if [ "$is_private" = "false" ]; then return 0; fi
        if [ "$is_private" = "true"  ]; then return 1; fi
        # API inconclusive (rate-limited, jq missing, network issue) — fall through
    fi

    # Probe via unauthenticated HTTPS ls-remote (works for any host)
    git ls-remote --exit-code "$HTTPS_CLONE_URL" HEAD &>/dev/null
}

# Prints the path to the first local SSH private key that has a matching .pub file.
find_local_ssh_key() {
    local candidates=(
        "$HOME/.ssh/id_ed25519"
        "$HOME/.ssh/id_ecdsa"
        "$HOME/.ssh/id_rsa"
    )
    for key in "${candidates[@]}"; do
        if [ -f "$key" ] && [ -f "${key}.pub" ]; then
            echo "$key"
            return 0
        fi
    done
    echo "Error: no local SSH key found. Checked: ${candidates[*]}" >&2
    echo "Generate one with: ssh-keygen -t ed25519" >&2
    return 1
}

# ── Resolve deploy key ────────────────────────────────────────────────────────

GIT_DEPLOY_KEY_SECRET=""
GIT_TOKEN_SECRET=""

if [ -n "$GITHUB_TOKEN_OPT" ]; then
    echo "Verifying GitHub token can access repo ..."
    AUTH_URL="https://x-access-token:${GITHUB_TOKEN_OPT}@${PARSED_HOST}/${PARSED_OWNER}/${PARSED_REPO}.git"
    if ! git -c credential.helper= ls-remote --exit-code "$AUTH_URL" HEAD &>/dev/null; then
        echo "Error: token cannot access ${PARSED_HOST}/${PARSED_OWNER}/${PARSED_REPO}. Check that the token has read access to repository contents." >&2
        exit 1
    fi
    echo "  Token verified."
    TOKEN_SECRET="${CLUSTER_NAME}-github-token"
    if [ "$DRY_RUN" = true ]; then
        echo "  [DRY RUN] Would create secret: ${TOKEN_SECRET} (type: github-token)"
        DRY_RUN_SECRETS+=("${TOKEN_SECRET}  type=github-token")
    else
        echo "Repo is private — storing GitHub token in Secret Manager ..."
        echo "$GITHUB_TOKEN_OPT" | create_cluster_secret "$CLUSTER_NAME" "$TOKEN_SECRET" "github-token"
    fi
    GIT_TOKEN_SECRET="$TOKEN_SECRET"
elif repo_is_public "$PARSED_HOST" "$PARSED_OWNER" "$PARSED_REPO"; then
    echo "Repo is public — no deploy key needed, instances will clone via HTTPS."
    GIT_REPO_URL="$HTTPS_CLONE_URL"
else
    echo "Repo is private — setting up read-only deploy key from local SSH key ..."

    LOCAL_KEY=$(find_local_ssh_key)
    PUBLIC_KEY=$(cat "${LOCAL_KEY}.pub")
    echo "  Using local key: ${LOCAL_KEY}.pub"

    SECRET_NAME="${CLUSTER_NAME}-deploy-key"
    if [ "$DRY_RUN" = true ]; then
        echo "  [DRY RUN] Would create secret: ${SECRET_NAME} (type: deploy-key)"
        DRY_RUN_SECRETS+=("${SECRET_NAME}  type=deploy-key")
    else
        echo "  Storing private key in Secret Manager ($SECRET_NAME) ..."
        cat "$LOCAL_KEY" | create_cluster_secret "$CLUSTER_NAME" "$SECRET_NAME" "deploy-key"
    fi

    echo ""
    echo "  No token provided — add this public key to your repo manually"
    echo "  as a read-only deploy key, then press Enter:"
    echo ""
    echo "$PUBLIC_KEY"
    echo ""
    read -rp "  Press Enter once the key is added ..."

    GIT_DEPLOY_KEY_SECRET="$SECRET_NAME"
fi

# ── Pull infra outputs ────────────────────────────────────────────────────────

echo "Reading shared infra outputs ..."
infra_tf_init

NETWORK_SELF_LINK=$(infra_output network_self_link)
SUBNET_SELF_LINK=$(infra_output subnet_self_link)
NETWORK_NAME=$(infra_output network_name)
POSTGRES_HOST=$(infra_output postgres_host)
POSTGRES_USER=$(infra_output postgres_user)
POSTGRES_PASSWORD_SECRET=$(infra_output postgres_password_secret)
REDIS_HOST=$(infra_output redis_host)
REDIS_PORT=$(infra_output redis_port)

# ── Build supervisor-http binary and upload to GCS ───────────────────────────
#
# supervisor-http is a Go binary (linux/amd64) that runs alongside supervisor.sh
# on each instance. It serves /health, /health/local, and /metadata, and
# reverse-proxies all other traffic to the app container.
# Instances download it from GCS at boot (startup.sh).

SUPERVISOR_DIR="$SCRIPT_DIR/../supervisor"
SUPERVISOR_HTTP_BIN="$SUPERVISOR_DIR/supervisor-http"

if [ "$DRY_RUN" = false ]; then
    if ! command -v go &>/dev/null; then
        echo "Error: Go is required to build supervisor-http. Install from https://go.dev/dl/" >&2
        exit 1
    fi

    echo "Building supervisor-http (linux/amd64) ..."
    (cd "$SUPERVISOR_DIR" && go mod tidy && GOOS=linux GOARCH=amd64 go build -o "$SUPERVISOR_HTTP_BIN" .)

    echo "Uploading supervisor-http to gs://${TF_STATE_BUCKET}/supervisor-http ..."
    gsutil cp "$SUPERVISOR_HTTP_BIN" "gs://${TF_STATE_BUCKET}/supervisor-http"
fi

# ── Build var file ────────────────────────────────────────────────────────────

VARS_FILE=$(mktemp /tmp/cluster-XXXXXX)
mv "$VARS_FILE" "${VARS_FILE}.tfvars"
VARS_FILE="${VARS_FILE}.tfvars"
trap 'rm -f "$VARS_FILE"' EXIT

# Convert comma-separated zones to HCL list
if [ -n "$ZONES" ]; then
    ZONES_HCL='["'$(echo "$ZONES" | sed 's/,/","/g')'"]'
else
    ZONES_HCL='[]'
fi

cat > "$VARS_FILE" <<EOF
cluster_name             = "${CLUSTER_NAME}"
project_id               = "${PROJECT_ID}"
region                   = "${REGION}"
zones                    = ${ZONES_HCL}
machine_type             = "${MACHINE_TYPE}"
disk_size_gb             = ${DISK_SIZE}
min_instances            = ${MIN_INSTANCES}
max_instances            = ${MAX_INSTANCES}
target_cpu_utilization   = ${CPU_TARGET}
git_repo_url             = "${GIT_REPO_URL}"
git_deploy_key_secret    = "${GIT_DEPLOY_KEY_SECRET}"
git_token_secret         = "${GIT_TOKEN_SECRET}"
container_port           = ${CONTAINER_PORT}
build_context            = "${BUILD_CONTEXT}"
dockerfile               = "${DOCKERFILE}"
data_namespace           = "${NAMESPACE}"
domain                   = "${DOMAIN}"
network_self_link        = "${NETWORK_SELF_LINK}"
subnet_self_link         = "${SUBNET_SELF_LINK}"
network_name             = "${NETWORK_NAME}"
postgres_host            = "${POSTGRES_HOST}"
postgres_user            = "${POSTGRES_USER}"
postgres_password_secret = "${POSTGRES_PASSWORD_SECRET}"
redis_host               = "${REDIS_HOST}"
redis_port               = ${REDIS_PORT}
state_bucket             = "${TF_STATE_BUCKET}"
EOF

# mtls_ca_cert is a PEM block — append separately to avoid heredoc conflicts
if [ -n "$MTLS_CA_CERT_PATH" ]; then
    printf 'mtls_ca_cert = <<ENDOFCERT\n' >> "$VARS_FILE"
    cat "$MTLS_CA_CERT_PATH" >> "$VARS_FILE"
    printf 'ENDOFCERT\n' >> "$VARS_FILE"
else
    printf 'mtls_ca_cert = ""\n' >> "$VARS_FILE"
fi

# Save vars to GCS so takedown.sh can use them without re-prompting
if [ "$DRY_RUN" = false ]; then
    save_cluster_vars "$CLUSTER_NAME" "$VARS_FILE"
fi

# ── Dry run: plan + export review artifacts, then exit ───────────────────────

if [ "$DRY_RUN" = true ]; then
    mkdir -p "$REVIEW_DIR"

    echo "Planning cluster Terraform (dry run) ..."
    cluster_tf_init "$CLUSTER_NAME"
    terraform -chdir="$TERRAFORM_CLUSTER_DIR" plan \
        -var-file="$VARS_FILE" \
        -input=false \
        -out="${REVIEW_DIR}/plan.tfplan"

    terraform -chdir="$TERRAFORM_CLUSTER_DIR" show "${REVIEW_DIR}/plan.tfplan" \
        | sed 's|https://x-access-token:[^@]*@|https://REDACTED@|g' \
        > "${REVIEW_DIR}/plan.txt"

    terraform -chdir="$TERRAFORM_CLUSTER_DIR" show -json "${REVIEW_DIR}/plan.tfplan" \
        | sed 's|https:\\/\\/x-access-token:[^@]*@|https:\\/\\/REDACTED@|g' \
        > "${REVIEW_DIR}/plan.json"

    sed 's|https://x-access-token:[^@]*@|https://REDACTED@|g' \
        "$VARS_FILE" > "${REVIEW_DIR}/vars.tfvars"

    {
        echo "# Secrets that would be created in Secret Manager"
        echo "# All secrets are labeled: managed-by=cdi, cluster=${CLUSTER_NAME}, secret-type=<type>"
        echo ""
        if [ ${#DRY_RUN_SECRETS[@]} -eq 0 ]; then
            echo "(none — public repo)"
        else
            for s in "${DRY_RUN_SECRETS[@]}"; do
                echo "  $s"
            done
        fi
    } > "${REVIEW_DIR}/secrets.txt"

    echo ""
    echo "Dry run complete. Review artifacts written to: ${REVIEW_DIR}"
    echo "  plan.txt       — human-readable Terraform plan (tokens redacted)"
    echo "  plan.json      — machine-readable plan with full resource diffs (tokens redacted)"
    echo "  plan.tfplan    — binary plan (pass to terraform apply to execute exactly this plan)"
    echo "  vars.tfvars    — effective variable values (tokens redacted)"
    echo "  secrets.txt    — Secret Manager secrets that would be created"
    echo ""
    echo "Note: plan.tfplan reflects current remote state. If this is a new deployment"
    echo "  transitioning to HTTPS, HTTPS resources will show as 'to be created' even"
    echo "  if they already exist — run the real deploy to reconcile state first."
    exit 0
fi

# ── Pre-import orphaned HTTPS resources (handles state drift on redeploy) ─────
#
# When transitioning from no-domain → domain, GCP resources may already exist
# but be absent from state (e.g. from a previous partial apply). terraform import
# is a no-op if already in state, and silently ignored if the resource doesn't
# exist in GCP yet — so this is safe to run unconditionally when a domain is set.

if [ -n "$DOMAIN" ]; then
    cluster_tf_init "$CLUSTER_NAME"
    PREFIX="cluster-${CLUSTER_NAME}"
    _import() {
        terraform -chdir="$TERRAFORM_CLUSTER_DIR" import \
            -var-file="$VARS_FILE" -input=false "$1" "$2" >/dev/null 2>&1 || true
    }
    _import 'google_compute_global_address.cluster[0]' \
        "projects/${PROJECT_ID}/global/addresses/${PREFIX}-ip"
    _import 'google_compute_url_map.cluster_http_redirect[0]' \
        "projects/${PROJECT_ID}/global/urlMaps/${PREFIX}-http-redirect"
    DOMAIN_HASH=$(printf '%s' "${DOMAIN}" | md5sum | cut -c1-8)
    _import 'google_compute_managed_ssl_certificate.cluster[0]' \
        "projects/${PROJECT_ID}/global/sslCertificates/${PREFIX}-cert-${DOMAIN_HASH}"
    _import 'google_compute_target_https_proxy.cluster[0]' \
        "projects/${PROJECT_ID}/global/targetHttpsProxies/${PREFIX}-https-proxy"
    _import 'google_compute_global_forwarding_rule.cluster_https[0]' \
        "projects/${PROJECT_ID}/global/forwardingRules/${PREFIX}-https"

    if [ -n "$MTLS_CA_CERT_PATH" ]; then
        _import 'google_certificate_manager_trust_config.cluster[0]' \
            "projects/${PROJECT_ID}/locations/global/trustConfigs/${PREFIX}-trust-config"
        _import 'google_network_security_server_tls_policy.cluster[0]' \
            "projects/${PROJECT_ID}/locations/global/serverTlsPolicies/${PREFIX}-tls-policy"
    fi
fi

# ── Apply cluster Terraform ───────────────────────────────────────────────────

echo "Applying cluster Terraform ..."
cluster_tf "$CLUSTER_NAME" apply \
    -var-file="$VARS_FILE" \
    -input=false \
    -auto-approve

LB_IP=$(cluster_output "$CLUSTER_NAME" lb_ip)

# ── Roll instances to pick up the new template ────────────────────────────────
# Terraform updates the instance template but GCP won't replace running instances
# unless explicitly told to. This forces a rolling replace using the MIG's existing
# surge/unavailable policy so we don't need to fight GCP's zone-count constraints.

echo "Rolling instance replacement ..."
gcloud compute instance-groups managed rolling-action replace \
    "cluster-${CLUSTER_NAME}" \
    --region="${REGION}" \
    --project="${PROJECT_ID}" \
    --quiet

# ── Fix forwarding rule IP drift ──────────────────────────────────────────────
#
# The GCP terraform provider silently ignores ip_address changes on forwarding
# rules (it suppresses the diff). When transitioning from no-domain→domain the
# forwarding rules can end up on a different IP than the static one, causing
# FAILED_NOT_VISIBLE on the SSL cert. Detect and fix this here.

if [ -n "$DOMAIN" ]; then
    HTTP_FWD_IP=$(gcloud compute forwarding-rules describe "${PREFIX}-http" \
        --global --project="$PROJECT_ID" --format="value(IPAddress)" 2>/dev/null || echo "")
    if [ -n "$HTTP_FWD_IP" ] && [ "$HTTP_FWD_IP" != "$LB_IP" ]; then
        echo "WARNING: Forwarding rule IP mismatch (actual ${HTTP_FWD_IP} ≠ static ${LB_IP})."
        echo "Recreating forwarding rules, HTTPS proxy, and SSL cert on the correct IP ..."

        terraform -chdir="$TERRAFORM_CLUSTER_DIR" state rm \
            'google_compute_global_forwarding_rule.cluster_http' \
            'google_compute_global_forwarding_rule.cluster_https[0]' \
            'google_compute_target_https_proxy.cluster[0]' \
            'google_compute_managed_ssl_certificate.cluster[0]' 2>/dev/null || true

        gcloud compute forwarding-rules delete "${PREFIX}-http" "${PREFIX}-https" \
            --global --project="$PROJECT_ID" --quiet 2>/dev/null || true
        gcloud compute target-https-proxies delete "${PREFIX}-https-proxy" \
            --global --project="$PROJECT_ID" --quiet 2>/dev/null || true
        gcloud compute ssl-certificates list --global --project="$PROJECT_ID" \
            --filter="name~${PREFIX}-cert" --format="value(name)" 2>/dev/null | \
            xargs -I{} gcloud compute ssl-certificates delete {} \
                --global --project="$PROJECT_ID" --quiet 2>/dev/null || true

        cluster_tf "$CLUSTER_NAME" apply -var-file="$VARS_FILE" -input=false -auto-approve
        LB_IP=$(cluster_output "$CLUSTER_NAME" lb_ip)
    fi
fi

# ── Create DNS record ─────────────────────────────────────────────────────────

echo "Creating DNS record: ${DOMAIN} → ${LB_IP} ..."
create_dns_record "$DNS_ZONE" "$DOMAIN" "$LB_IP"

# ── Monitor SSL certificate provisioning ─────────────────────────────────────
#
# Poll for up to 10 minutes. Exit loop early if the cert becomes ACTIVE or
# enters a FAILED state (so the operator knows immediately, not hours later).

if [ -n "$DOMAIN" ]; then
    CERT_NAME=$(gcloud compute ssl-certificates list --global \
        --project="$PROJECT_ID" --filter="name~${PREFIX}-cert" \
        --format="value(name)" --limit=1 2>/dev/null || echo "")
    if [ -n "$CERT_NAME" ]; then
        echo "Monitoring SSL certificate (${CERT_NAME}) ..."
        for i in $(seq 1 20); do
            CERT_STATUS=$(gcloud compute ssl-certificates describe "$CERT_NAME" \
                --global --project="$PROJECT_ID" \
                --format="value(managed.status)" 2>/dev/null || echo "UNKNOWN")
            DOMAIN_STATUS=$(gcloud compute ssl-certificates describe "$CERT_NAME" \
                --global --project="$PROJECT_ID" \
                --format="value(managed.domainStatus['${DOMAIN}'])" 2>/dev/null || echo "")
            if [ "$CERT_STATUS" = "ACTIVE" ]; then
                echo "  SSL certificate ACTIVE. HTTPS is ready."
                break
            elif [[ "$DOMAIN_STATUS" == *"FAILED"* ]]; then
                echo ""
                echo "  ERROR: Certificate provisioning failed: ${DOMAIN_STATUS}"
                echo "  Check that port 80 responds: curl -sv http://${DOMAIN}"
                echo "  To retry the cert: ./scripts/deploy.sh --key ${KEY} --repo ${PARSED_OWNER}/${PARSED_REPO}"
                break
            fi
            echo "  Certificate ${CERT_STATUS} (${DOMAIN_STATUS:-pending}) — check ${i}/20 ..."
            [ $i -lt 20 ] && sleep 30
        done
    fi
fi

echo ""
echo "Deployment '${KEY}' complete."
echo "  Load balancer IP: ${LB_IP}"
echo "  URL: https://${DOMAIN}"
echo ""
echo "Monitor instances:"
echo "  gcloud compute instance-groups managed list-instances cluster-${KEY} --region=${REGION} --project=${PROJECT_ID}"
echo ""
echo "Tail supervisor logs on an instance:"
echo "  gcloud compute ssh <instance-name> --zone=<zone> --project=${PROJECT_ID} -- journalctl -fu supervisor"
