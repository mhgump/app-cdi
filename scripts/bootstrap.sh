#!/bin/bash
# One-time bootstrap: enable GCP APIs and create the Terraform state bucket.
# Run this once per GCP project before deploying any infra or clusters.
#
# Required env: PROJECT_ID, TF_STATE_BUCKET, REGION (optional, default us-central1)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

check_required_env

REGION="${REGION:-us-central1}"

echo "Bootstrapping project: $PROJECT_ID"
echo "State bucket:          gs://$TF_STATE_BUCKET"
echo "Region:                $REGION"
echo ""

# ── Enable required APIs ──────────────────────────────────────────────────────

APIS=(
    compute.googleapis.com
    servicenetworking.googleapis.com
    sqladmin.googleapis.com
    redis.googleapis.com
    secretmanager.googleapis.com
    logging.googleapis.com
    monitoring.googleapis.com
    cloudresourcemanager.googleapis.com
    certificatemanager.googleapis.com
    networksecurity.googleapis.com
)

echo "Enabling GCP APIs (this may take a minute) ..."
gcloud services enable "${APIS[@]}" --project="$PROJECT_ID"
echo "APIs enabled."

# ── Create Terraform state bucket ─────────────────────────────────────────────

if gsutil ls "gs://$TF_STATE_BUCKET" &>/dev/null; then
    echo "State bucket gs://$TF_STATE_BUCKET already exists."
else
    echo "Creating state bucket gs://$TF_STATE_BUCKET ..."
    gcloud storage buckets create "gs://$TF_STATE_BUCKET" \
        --project="$PROJECT_ID" \
        --location="$REGION" \
        --uniform-bucket-level-access
    # Enable versioning so we can recover from accidental state corruption
    gsutil versioning set on "gs://$TF_STATE_BUCKET"
    echo "State bucket created."
fi

echo ""
echo "Bootstrap complete. Next steps:"
echo "  1. cd terraform/infra && terraform init -backend-config=bucket=$TF_STATE_BUCKET -backend-config=prefix=infra"
echo "  2. terraform apply -var=project_id=$PROJECT_ID -var=region=${REGION:-us-central1}"
echo "  3. cd ../.. && ./scripts/deploy.sh <cluster-name> <git-url>"
