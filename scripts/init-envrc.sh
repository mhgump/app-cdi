#!/bin/bash
# Initialize a .envrc file for this project.
# Run once when setting up a new environment.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENVRC="$REPO_ROOT/.envrc"

if [ -f "$ENVRC" ]; then
    echo ".envrc already exists at $ENVRC"
    read -rp "Overwrite? [y/N] " answer
    [[ "$answer" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
fi

echo ""
echo "=== CDI .envrc Setup ==="
echo "This script creates a .envrc file with the environment variables needed"
echo "to run Terraform and the deploy/takedown scripts in this project."
echo ""
echo "Press Enter to keep the default shown in brackets."
echo ""

# ── GCP project ───────────────────────────────────────────────────────────────
cat <<'MSG'
────────────────────────────────────────────────────────────────────────────────
GCP_PROJECT_ID
  The ID of the Google Cloud project where all infrastructure will be deployed.
  This is NOT the project name or number — it is the unique project ID string
  (e.g. "my-company-dev-123").

  To find or create a project:
    Console → https://console.cloud.google.com/projectselector2/home/dashboard
    - Select an existing project and copy its ID from the top bar, or
    - Click "New Project", fill in the name, and copy the auto-generated ID.

  To find it via CLI:
    gcloud projects list
────────────────────────────────────────────────────────────────────────────────
MSG
read -rp "GCP Project ID [sc-ai-innovation-lab-2-dev]: " PROJECT_ID
PROJECT_ID="${PROJECT_ID:-sc-ai-innovation-lab-2-dev}"

# ── Terraform namespace ───────────────────────────────────────────────────────
cat <<'MSG'

────────────────────────────────────────────────────────────────────────────────
TF_VAR_NAMESPACE
  A unique prefix applied to every GCP resource name created by Terraform
  (VPCs, subnets, Cloud SQL instances, Redis instances, etc.). This prevents
  naming collisions when multiple deployments share the same GCP project.

  Convention used in this project: "<owner>--<app>"
  Example: "aviad--appcdi"

  No GCP resource needs to exist for this — it is just a string prefix.
  Choose something short, lowercase, and unique within the project.
────────────────────────────────────────────────────────────────────────────────
MSG
DEFAULT_NAMESPACE="aviad--appcdi"
read -rp "Terraform namespace [$DEFAULT_NAMESPACE]: " NAMESPACE
NAMESPACE="${NAMESPACE:-$DEFAULT_NAMESPACE}"

# ── Terraform state bucket ────────────────────────────────────────────────────
cat <<MSG

────────────────────────────────────────────────────────────────────────────────
TF_STATE_BUCKET
  The name of the GCS bucket used to store Terraform remote state. All
  terraform commands in this project read and write state to this bucket.

  The bucket must exist before running 'terraform init'. If you have not
  created it yet, run scripts/bootstrap.sh after completing this setup —
  bootstrap.sh will create the bucket for you.

  To create manually via Console:
    https://console.cloud.google.com/storage/browser
    - Click "Create", choose a globally unique name, select your region,
      enable "Uniform bucket-level access", then click "Create".

  Recommended naming convention: "<namespace>--<project-id>-tfstate"
────────────────────────────────────────────────────────────────────────────────
MSG
DEFAULT_BUCKET="${NAMESPACE}--${PROJECT_ID}-tfstate"
read -rp "Terraform state bucket [$DEFAULT_BUCKET]: " TF_STATE_BUCKET
TF_STATE_BUCKET="${TF_STATE_BUCKET:-$DEFAULT_BUCKET}"

# ── Cloud DNS zone ────────────────────────────────────────────────────────────
cat <<'MSG'

────────────────────────────────────────────────────────────────────────────────
DNS_ZONE
  The resource name of a Cloud DNS managed zone in your GCP project. This is
  the short identifier used in gcloud commands (not the DNS name itself).
  Example: "aviadtest-site"  (for a zone managing the domain "aviadtest.site")

  Each deployed cluster gets a DNS record: <cluster-name>.<DNS_DOMAIN>
  That record is created/deleted automatically by deploy.sh and takedown.sh.

  The managed zone must already exist and its NS records must be delegated
  from your domain registrar before DNS will resolve.

  To create a managed zone via Console:
    https://console.cloud.google.com/net-services/dns/zones
    - Click "Create Zone"
    - Zone type: Public
    - Zone name: a short resource identifier (e.g. "aviadtest-site") — this
      is what you enter here
    - DNS name: the domain you own (e.g. "aviadtest.site")
    - Click "Create", then copy the 4 NS records shown and add them as NS
      records at your domain registrar.

  To list existing zones via CLI:
    gcloud dns managed-zones list --project=<PROJECT_ID>
────────────────────────────────────────────────────────────────────────────────
MSG
read -rp "Cloud DNS zone resource name [aviadtest-site]: " DNS_ZONE
DNS_ZONE="${DNS_ZONE:-aviadtest-site}"

# ── Cloud DNS domain ──────────────────────────────────────────────────────────
cat <<'MSG'

────────────────────────────────────────────────────────────────────────────────
DNS_DOMAIN
  The DNS domain name managed by the zone above. Clusters are assigned
  subdomains of this domain: <cluster-name>.<DNS_DOMAIN>
  Example: "aviadtest.site"

  This must match the "DNS name" field of the managed zone you entered above.
────────────────────────────────────────────────────────────────────────────────
MSG
read -rp "DNS domain [aviadtest.site]: " DNS_DOMAIN
DNS_DOMAIN="${DNS_DOMAIN:-aviadtest.site}"

# ── Region (optional) ─────────────────────────────────────────────────────────
cat <<'MSG'

────────────────────────────────────────────────────────────────────────────────
REGION  (optional)
  The GCP region where infrastructure is deployed (Cloud SQL, Redis, VPC
  subnets, GCS bucket, etc.). Defaults to "us-central1" if left blank.

  All resources for a given deployment must be in the same region. Once
  infrastructure is provisioned, changing the region requires a full teardown
  and redeploy.

  Common choices: us-central1, us-east1, us-west1, europe-west1
  Full list: https://cloud.google.com/compute/docs/regions-zones
────────────────────────────────────────────────────────────────────────────────
MSG
read -rp "GCP region (leave blank for us-central1 default) []: " REGION

# ── Write file ────────────────────────────────────────────────────────────────
cat > "$ENVRC" <<EOF
# GCP project — either name works; GOOGLE_PROJECT is the gcloud default
export PROJECT_ID="${PROJECT_ID}"

# Terraform state bucket
export TF_STATE_BUCKET="${TF_STATE_BUCKET}"

# Terraform variable values — picked up automatically by all terraform commands
export TF_VAR_project_id="${PROJECT_ID}"
export TF_VAR_namespace="${NAMESPACE}"

EOF

if [ -n "$REGION" ]; then
cat >> "$ENVRC" <<EOF
export REGION="${REGION}"
export TF_VAR_region="${REGION}"

EOF
else
cat >> "$ENVRC" <<EOF
# export REGION="us-central1"
# export TF_VAR_region="us-central1"

EOF
fi

cat >> "$ENVRC" <<EOF
# Cloud DNS — clusters get <cluster-name>.<DNS_DOMAIN> automatically
export DNS_ZONE="${DNS_ZONE}"
export DNS_DOMAIN="${DNS_DOMAIN}"
EOF

echo ""
echo "✓ .envrc written to $ENVRC"
echo ""
echo "Next steps:"
echo "  1. If the Terraform state bucket does not exist yet, run:"
echo "       ./scripts/bootstrap.sh"
echo "     (creates the bucket and enables required GCP APIs)"
echo ""
echo "  2. Load the environment:"
echo "       direnv allow       # if you use direnv"
echo "       source .envrc      # or load manually"
