# Shell helpers for poking at a cluster from your terminal.
# Source this file (done automatically by .envrc) to get:
#   inst-source <key>   pick a RUNNING instance; exports KEY, INSTANCE_NAME, ZONE
#   docker-logs         tail the Docker container log on the selected instance
#   instance-logs       tail the supervisor log on the selected instance
# Works in bash and zsh.

inst-source() {
    local key="$1"
    if [ -z "$key" ]; then
        echo "Usage: inst-source <key>" >&2
        return 1
    fi
    if [ -z "${PROJECT_ID:-}" ]; then
        echo "Error: PROJECT_ID not set (source .envrc)" >&2
        return 1
    fi
    local region="${REGION:-us-central1}"
    local cluster="cluster-${key}"
    local url
    url=$(gcloud compute instance-groups managed list-instances "$cluster" \
        --region="$region" --project="$PROJECT_ID" \
        --filter="instanceStatus=RUNNING" \
        --format="csv[no-heading,no-transforms](instance)" 2>/dev/null | head -1)
    if [ -z "$url" ]; then
        echo "Error: no RUNNING instances in cluster '${cluster}'." >&2
        return 1
    fi
    # url: .../zones/<zone>/instances/<name>
    local rest="${url%/instances/*}"
    export KEY="$key"
    export INSTANCE_NAME="${url##*/}"
    export ZONE="${rest##*/}"
    echo "KEY=$KEY INSTANCE_NAME=$INSTANCE_NAME ZONE=$ZONE"
}

_inst_ssh() {
    if [ -z "${INSTANCE_NAME:-}" ] || [ -z "${ZONE:-}" ] || [ -z "${PROJECT_ID:-}" ]; then
        echo "Error: run 'inst-source <key>' first." >&2
        return 1
    fi
    gcloud compute ssh "$INSTANCE_NAME" \
        --zone="$ZONE" --project="$PROJECT_ID" \
        --command="$1"
}

docker-logs()   { _inst_ssh "sudo docker logs app -f"; }
instance-logs() { _inst_ssh "sudo journalctl -u supervisor -f"; }
