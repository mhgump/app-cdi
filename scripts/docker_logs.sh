#!/bin/bash
# Tail the Docker container log on the selected instance.
# Requires INSTANCE_NAME, ZONE, and PROJECT_ID (set via: source ./scripts/instance.sh --key <key>)
#
# Equivalent to:
#   gcloud compute ssh ${INSTANCE_NAME} --zone=${ZONE} --project=${PROJECT_ID} --command="sudo docker logs app -f"

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

require_env PROJECT_ID
require_env INSTANCE_NAME
require_env ZONE

gcloud compute ssh "$INSTANCE_NAME" \
    --zone="$ZONE" \
    --project="$PROJECT_ID" \
    --command="sudo docker logs app -f"
