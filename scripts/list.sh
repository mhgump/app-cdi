#!/bin/bash
# List all deployed clusters in this project.
#
# Usage: ./scripts/list.sh
#
# Required env: PROJECT_ID

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

require_env PROJECT_ID

# Fetch all MIGs named "cluster-*" across all regions
MIGS=$(gcloud compute instance-groups managed list \
    --project="$PROJECT_ID" \
    --filter="name:cluster-*" \
    --format="json(name,region,size,status,autoscaled)" 2>/dev/null)

if [ -z "$MIGS" ] || [ "$MIGS" = "[]" ]; then
    echo "No clusters found in project $PROJECT_ID."
    exit 0
fi

# Header
printf "%-28s  %-14s  %5s  %-10s  %s\n" "CLUSTER" "REGION" "SIZE" "STATUS" "LB IP"
printf "%-28s  %-14s  %5s  %-10s  %s\n" "-------" "------" "----" "------" "-----"

echo "$MIGS" | jq -r '.[] | [.name, .region, (.size|tostring), .status] | @tsv' | \
while IFS=$'\t' read -r mig_name region size status; do
    cluster_name="${mig_name#cluster-}"
    region_short="${region##*/}"

    # Look up the forwarding rule for this cluster's HTTP LB
    lb_ip=$(gcloud compute forwarding-rules list \
        --project="$PROJECT_ID" \
        --filter="name=${mig_name}-http" \
        --format="value(IPAddress)" 2>/dev/null | head -1 || echo "N/A")

    printf "%-28s  %-14s  %5s  %-10s  %s\n" \
        "$cluster_name" "$region_short" "$size" "$status" "${lb_ip:-N/A}"
done
