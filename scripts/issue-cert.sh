#!/bin/bash
# Issue a client certificate signed by a CDI mTLS CA.
# Distribute the resulting .crt and .key files to the trusted client.
#
# Usage:
#   ./scripts/issue-cert.sh --ca-cert <ca.crt> --ca-key <ca.key> --cn <name> [options]
#
# Options:
#   --ca-cert <path>   Path to CA certificate (required)
#   --ca-key  <path>   Path to CA private key (required)
#   --cn      <name>   Common name for the client cert (required, e.g. "alice")
#   --days    <n>      Certificate validity in days (default: 30)
#   --out     <prefix> Output path prefix — writes <prefix>.crt and <prefix>.key
#                      (default: ./<cn>)

set -euo pipefail

CA_CERT=""
CA_KEY=""
CN=""
DAYS=30
OUT=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ca-cert) CA_CERT="$2"; shift 2 ;;
        --ca-key)  CA_KEY="$2";  shift 2 ;;
        --cn)      CN="$2";      shift 2 ;;
        --days)    DAYS="$2";    shift 2 ;;
        --out)     OUT="$2";     shift 2 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

if [ -z "$CA_CERT" ] || [ -z "$CA_KEY" ] || [ -z "$CN" ]; then
    echo "Usage: $0 --ca-cert <ca.crt> --ca-key <ca.key> --cn <name> [--days <n>] [--out <prefix>]" >&2
    exit 1
fi

if [ ! -f "$CA_CERT" ]; then
    echo "Error: CA cert not found: $CA_CERT" >&2
    exit 1
fi

if [ ! -f "$CA_KEY" ]; then
    echo "Error: CA key not found: $CA_KEY" >&2
    exit 1
fi

if ! command -v openssl &>/dev/null; then
    echo "Error: openssl is required but not found in PATH." >&2
    exit 1
fi

OUT="${OUT:-./${CN}}"
CLIENT_KEY="${OUT}.key"
CLIENT_CERT="${OUT}.crt"

CLIENT_CSR=$(mktemp /tmp/csr-XXXXXX.pem)
EXT_FILE=$(mktemp /tmp/ext-XXXXXX.cnf)
trap 'rm -f "$CLIENT_CSR" "$EXT_FILE"' EXIT

if [ -f "$CLIENT_KEY" ] || [ -f "$CLIENT_CERT" ]; then
    echo "Error: $CLIENT_KEY or $CLIENT_CERT already exists. Remove them first." >&2
    exit 1
fi

cat > "$EXT_FILE" <<'EOF'
[v3_client]
basicConstraints = CA:FALSE
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = clientAuth
EOF

echo "Issuing client certificate ..."
echo "  CN:        $CN"
echo "  Valid:     $DAYS days"
echo "  Signed by: $CA_CERT"
echo ""

openssl genrsa -out "$CLIENT_KEY" 2048 2>/dev/null
openssl req -new \
    -key "$CLIENT_KEY" \
    -subj "/CN=${CN}" \
    -out "$CLIENT_CSR" 2>/dev/null
openssl x509 -req \
    -days "$DAYS" \
    -in "$CLIENT_CSR" \
    -CA "$CA_CERT" \
    -CAkey "$CA_KEY" \
    -CAcreateserial \
    -out "$CLIENT_CERT" \
    -extfile "$EXT_FILE" \
    -extensions v3_client 2>/dev/null

chmod 600 "$CLIENT_KEY"
chmod 644 "$CLIENT_CERT"

EXPIRY=$(openssl x509 -noout -enddate -in "$CLIENT_CERT" | cut -d= -f2)

echo "Client certificate issued:"
echo "  Key:     $CLIENT_KEY"
echo "  Cert:    $CLIENT_CERT"
echo "  Expires: $EXPIRY"
echo ""
echo "Distribute both files. Connect with:"
echo "  curl --cert $CLIENT_CERT --key $CLIENT_KEY https://<domain>/..."
