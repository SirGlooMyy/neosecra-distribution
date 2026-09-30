#!/usr/bin/env bash
# Offline stable-promotion gate for Hotspot source releases.
#
# A clean-VM gate for Assessment cannot validate the Hotspot Compose contract.
# This gate is deterministic and network-free: it verifies the release input's
# structure before publish stages or signs anything.
set +x
set -Eeuo pipefail
umask 077

usage() {
  cat <<'EOF'
Usage: prerelease-gate-hotspot.sh --archive <path> --version <semver>
EOF
}

ARCHIVE=""
VERSION=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --archive) shift; ARCHIVE="${1:-}" ;;
    --version) shift; VERSION="${1:-}" ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Invalid Hotspot version" >&2; exit 2; }
[[ -f "$ARCHIVE" && ! -L "$ARCHIVE" && -s "$ARCHIVE" ]] || { echo "Hotspot archive is missing" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "python3 is required" >&2; exit 2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIST_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
EXTRACTOR="${DIST_ROOT}/deployment/v1/upgrade/secure_extract.py"
[[ -f "$EXTRACTOR" && ! -L "$EXTRACTOR" ]] || { echo "Hotspot secure extractor is missing" >&2; exit 4; }

TMP_DIR="$(mktemp -d /tmp/neosecra-hotspot-gate.XXXXXXXXXX)"
trap 'rm -rf -- "$TMP_DIR"' EXIT
python3 "$EXTRACTOR" hotspot "$ARCHIVE" "$TMP_DIR/extract" "$VERSION"
PAYLOAD="$(find "$TMP_DIR/extract" -mindepth 1 -maxdepth 1 -type d -print -quit)"
[[ -n "$PAYLOAD" ]] || { echo "Hotspot archive payload root is missing" >&2; exit 4; }

required_files=(
  docker-compose.yml
  backend/.env.example
  deployment/v1/agent/install-hotspot-agent.sh
  deployment/v1/agent/update-agent.sh
  deployment/v1/agent/hotspot-updater.sh
  deployment/v1/agent/artifact-verifier.sh
  deployment/v1/upgrade/secure_extract.py
  deployment/v1/upgrade/verify_rollback_auth.py
  deployment/v1/upgrade/recovery.py
  deployment/v1/lib/common.sh
  deployment/v1/lib/manifest.sh
  deployment/v1/lib/state.sh
  deployment/v1/ca/update-neosecra-com.pub
  deployment/v1/ca/update-neosecra-com-20260904.pub
  deploy/ca/update-neosecra-com.pub
  deploy/ca/update-neosecra-com-20260904.pub
)
for relative in "${required_files[@]}"; do
  [[ -f "$PAYLOAD/$relative" && ! -L "$PAYLOAD/$relative" ]] || {
    echo "Hotspot archive is missing required payload: $relative" >&2
    exit 4
  }
done

if find "$PAYLOAD" \( -type l -o -type b -o -type c -o -type p \) -print -quit | grep -q .; then
  echo "Hotspot archive contains an unsafe filesystem entry" >&2
  exit 4
fi
if find "$PAYLOAD" -type f \( -name '.env' -o -name '*.key' -o -name '*.pem' -o -name '*.p12' -o -name '*.pfx' -o -name '*.jks' \) -print -quit | grep -q .; then
  echo "Hotspot archive contains runtime secrets or private key material" >&2
  exit 4
fi

for script in \
  "$PAYLOAD/deployment/v1/agent/install-hotspot-agent.sh" \
  "$PAYLOAD/deployment/v1/agent/update-agent.sh" \
  "$PAYLOAD/deployment/v1/agent/hotspot-updater.sh"; do
  bash -n "$script"
done

echo "HOTSPOT_GATE|PASS|archive|signed Hotspot payload contract is valid"
