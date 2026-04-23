#!/bin/bash
# Trigger a live rebuild on all instances in a cluster.
#
# The supervisor on each instance polls the 'rebuild-trigger' metadata key.
# This script updates that key, which causes each supervisor to:
#   1. Stop the running container
#   2. Pull/checkout the specified commit
#   3. docker build
#   4. docker run
#
# Usage:
#   ./scripts/rebuild.sh --key <key> [commit-or-ref]
#
#   commit-or-ref  Git commit hash, branch, or tag.  Defaults to "latest"
#                  (which means: pull the default branch HEAD).
#
# Required env: PROJECT_ID

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

require_env PROJECT_ID

KEY=""
COMMIT="latest"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --key) KEY="$2"; shift 2 ;;
        --*)   echo "Unknown option: $1" >&2; exit 1 ;;
        *)     COMMIT="$1"; shift ;;
    esac
done

if [ -z "$KEY" ]; then
    echo "Error: --key <key> is required." >&2
    echo "Usage: $0 --key <key> [commit-or-ref]" >&2
    exit 1
fi

CLUSTER_NAME="$KEY"
TIMESTAMP=$(date +%s)
TRIGGER_VALUE="${COMMIT}-${TIMESTAMP}"

echo "Triggering rebuild for cluster '$CLUSTER_NAME'"
echo "  Commit/ref: $COMMIT"
echo "  Trigger:    $TRIGGER_VALUE"
echo ""

# Find all RUNNING instances in the cluster's MIG.
# Filter to RUNNING only — during a rolling update, instances in STOPPING/TERMINATED
# state still appear in the list but will reject metadata updates.
INSTANCES=$(gcloud compute instances list \
    --project="$PROJECT_ID" \
    --filter="metadata.items.key=cluster-name AND metadata.items.value=${CLUSTER_NAME} AND status=RUNNING" \
    --format="value(name,zone)" 2>/dev/null)

if [ -z "$INSTANCES" ]; then
    echo "No running instances found for cluster '$CLUSTER_NAME'." >&2
    echo "Check: gcloud compute instances list --project=$PROJECT_ID --filter=\"metadata.items.key=cluster-name AND metadata.items.value=${CLUSTER_NAME}\"" >&2
    exit 1
fi

# Update metadata on each instance — the supervisor will pick it up within ~10s
INSTANCE_COUNT=0
while IFS=$'\t' read -r instance_name zone; do
    zone_short="${zone##*/}"
    echo "  Updating rebuild-trigger on $instance_name ($zone_short) ..."
    if gcloud compute instances add-metadata "$instance_name" \
        --project="$PROJECT_ID" \
        --zone="$zone_short" \
        --metadata="rebuild-trigger=${TRIGGER_VALUE}" \
        --quiet 2>/dev/null; then
        INSTANCE_COUNT=$((INSTANCE_COUNT + 1))
    else
        echo "  WARNING: $instance_name gone or not ready — skipping."
    fi
done <<< "$INSTANCES"

echo ""
echo "Rebuild triggered on $INSTANCE_COUNT instance(s)."
echo "Each instance will pull, build, and restart within the next ~30 seconds."
echo ""
echo "Monitor progress:"
echo "  gcloud compute ssh <instance> --zone=<zone> --project=$PROJECT_ID -- journalctl -fu supervisor"
