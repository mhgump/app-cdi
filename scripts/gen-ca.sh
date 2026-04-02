#!/bin/bash
# Generate a self-signed CA certificate and private key for mTLS deployments.
# The CA cert (not the key) is passed to deploy.sh --mtls.
#
# Usage:
#   ./scripts/gen-ca.sh [--out <dir>] [--days <n>] [--cn <name>]
#
# Options:
#   --out   <dir>   Output directory          (default: ./mtls)
#   --days  <n>     Certificate validity days  (default: 3650)
#   --cn    <name>  Common Name for the CA     (default: "CDI mTLS CA")

set -euo pipefail

OUT_DIR="./mtls"
DAYS=3650
CN="CDI mTLS CA"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --out)  OUT_DIR="$2"; shift 2 ;;
        --days) DAYS="$2";    shift 2 ;;
        --cn)   CN="$2";      shift 2 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

if ! command -v openssl &>/dev/null; then
    echo "Error: openssl is required but not found in PATH." >&2
    exit 1
fi

mkdir -p "$OUT_DIR"
CA_KEY="$OUT_DIR/ca.key"
CA_CERT="$OUT_DIR/ca.crt"

if [ -f "$CA_KEY" ] || [ -f "$CA_CERT" ]; then
    echo "Error: $CA_KEY or $CA_CERT already exists." >&2
    echo "Remove them first or choose a different --out directory." >&2
    exit 1
fi

echo "Generating CA key and certificate ..."
echo "  Output: $OUT_DIR"
echo "  CN:     $CN"
echo "  Valid:  $DAYS days"
echo ""

openssl genrsa -out "$CA_KEY" 4096 2>/dev/null
openssl req -new -x509 \
    -days "$DAYS" \
    -key "$CA_KEY" \
    -subj "/CN=${CN}" \
    -out "$CA_CERT" \
    -addext "basicConstraints=critical,CA:TRUE" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" 2>/dev/null

chmod 600 "$CA_KEY"
chmod 644 "$CA_CERT"

echo "CA generated:"
echo "  Private key: $CA_KEY  (keep secret — never share or commit this)"
echo "  Certificate: $CA_CERT (pass to deploy: ./scripts/deploy.sh ... --mtls $CA_CERT)"
echo ""
echo "Issue client certs with:"
echo "  ./scripts/issue-cert.sh --ca-cert $CA_CERT --ca-key $CA_KEY --cn <name> --out <outdir>"
