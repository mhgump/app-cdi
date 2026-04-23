#!/bin/bash
# Select the first RUNNING instance in a cluster and export its name and zone.
# Must be sourced to persist the exports into the calling shell.
#
# Usage:   source ./scripts/instance.sh --key <key> [--region <region>]
# Exports: KEY, INSTANCE_NAME, ZONE

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

_KEY=""
_REGION="${REGION:-us-central1}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --key)    _KEY="$2";    shift 2 ;;
        --region) _REGION="$2"; shift 2 ;;
        *) echo "Unknown option: $1" >&2; return 1 2>/dev/null || exit 1 ;;
    esac
done

if [ -z "$_KEY" ]; then
    echo "Error: --key <key> is required." >&2
    echo "Usage: source ./scripts/instance.sh --key <key>" >&2
    return 1 2>/dev/null || exit 1
fi

require_env PROJECT_ID

_CLUSTER_NAME="cluster-${_KEY}"

_INSTANCE_LINE=$(gcloud compute instance-groups managed list-instances "$_CLUSTER_NAME" \
    --region="$_REGION" \
    --project="$PROJECT_ID" \
    --format="csv[no-heading](name,zone)" \
    --filter="status=RUNNING" 2>/dev/null | head -1)

if [ -z "$_INSTANCE_LINE" ]; then
    echo "Error: no RUNNING instances found in cluster '${_CLUSTER_NAME}'." >&2
    return 1 2>/dev/null || exit 1
fi

export KEY="$_KEY"
export INSTANCE_NAME="${_INSTANCE_LINE%%,*}"
export ZONE="${_INSTANCE_LINE##*,}"
ZONE="${ZONE##*/}"  # strip zones/ prefix if present

echo "KEY=$KEY"
echo "INSTANCE_NAME=$INSTANCE_NAME"
echo "ZONE=$ZONE"

unset _KEY _REGION _CLUSTER_NAME _INSTANCE_LINE
