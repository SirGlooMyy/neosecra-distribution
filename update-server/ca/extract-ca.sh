#!/usr/bin/env bash
# NeoSecra Update Server — Extract Caddy Root CA from running container
# Run this after the update server is deployed to extract the root CA
# so it can be bundled with releases and trusted by clients.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CA_OUT="${SCRIPT_DIR}/ca/update-neosecra-com-root.crt"
CADDY_CONTAINER="${1:-neosecra-update-caddy-1}"

if [[ ! -f "$CA_OUT" ]]; then
    echo "[extract-ca] No CA found at ${CA_OUT}"
    echo "[extract-ca] Attempting to extract from Caddy container '${CADDY_CONTAINER}'..."

    if docker exec "$CADDY_CONTAINER" test -f /data/caddy/pki/authorities/local/root.crt 2>/dev/null; then
        docker cp "${CADDY_CONTAINER}:/data/caddy/pki/authorities/local/root.crt" "$CA_OUT"
        echo "[extract-ca] CA extracted to ${CA_OUT}"
    else
        echo "[extract-ca] Caddy internal CA not yet generated."
        echo "[extract-ca] Make a TLS request to the server first, then re-run this script."
        echo ""
        echo "  curl -fsSL --cacert '${CA_OUT}' https://update.neosecra.com/channels/assessment-stable.json"
        echo ""
        echo "Or generate a fresh CA with openssl (see docs/TLS-CA.md)."
        exit 1
    fi
else
    echo "[extract-ca] CA already present: ${CA_OUT}"
    openssl x509 -in "$CA_OUT" -text -noout | head --lines=10
fi

# Generate base64-encoded version for embedding in bootstrap.sh
CA_B64="${SCRIPT_DIR}/ca/update-neosecra-com-root.crt.b64"
openssl base64 -in "$CA_OUT" -out "$CA_B64"
echo "[extract-ca] Base64-encoded CA written to ${CA_B64}"
echo "[extract-ca] CA fingerprint:"
openssl x509 -in "$CA_OUT" -fingerprint -sha256 -noout | cut -d= -f2
