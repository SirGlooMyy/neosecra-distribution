#!/usr/bin/env bash
# Offline contract tests for the distribution channel and host update-agent.
# These tests never contact a live host and never execute Docker/Compose.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TMP="$(mktemp -d /tmp/neosecra-agent-contract-XXXXXX)"
trap 'rm -rf "${TMP}"' EXIT

PASS=0
FAIL=0
pass() { printf 'PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }
expect_fail() {
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then fail "$name (unexpected success)"; else pass "$name"; fi
}

CHANNEL_ROOT="${TMP}/channels-root"
mkdir -p "${CHANNEL_ROOT}/channels" "${CHANNEL_ROOT}/public-keys"
cp -a "${ROOT}/channels/." "${CHANNEL_ROOT}/channels/"
cp "${ROOT}/public-keys/update-neosecra-com.pub" "${CHANNEL_ROOT}/public-keys/"

if "${ROOT}/bin/validate-channels.sh" "${ROOT}" "${ROOT}/update-server/www" >/dev/null; then
  pass "canonical channels and generated WWW copies validate"
else
  fail "canonical channels and generated WWW copies validate"
fi

cp -a "${CHANNEL_ROOT}" "${TMP}/missing-signature"
rm -f "${TMP}/missing-signature/channels/hotspot-stable.json.minisig"
expect_fail "missing channel minisig is rejected" \
  "${ROOT}/bin/validate-channels.sh" "${TMP}/missing-signature"

cp -a "${CHANNEL_ROOT}" "${TMP}/channel-mismatch"
python3 - "${TMP}/channel-mismatch/channels/assessment-stable.json" <<'PY'
import json, pathlib, sys
p = pathlib.Path(sys.argv[1])
data = json.loads(p.read_text())
data["channel"] = "soc-stable"
p.write_text(json.dumps(data, indent=2) + "\n")
PY
expect_fail "channel name/signature mismatch is rejected" \
  "${ROOT}/bin/validate-channels.sh" "${TMP}/channel-mismatch"

source "${ROOT}/deployment/v1/agent/artifact-verifier.sh"
printf 'signed artifact fixture\n' > "${TMP}/artifact.bin"
sha256sum "${TMP}/artifact.bin" > "${TMP}/artifact.bin.sha256"
if verify_sha256_sidecar "${TMP}/artifact.bin"; then pass "valid SHA-256 sidecar accepted"; else fail "valid SHA-256 sidecar accepted"; fi
printf 'tampered artifact\n' > "${TMP}/artifact.bin"
expect_fail "SHA-256 mismatch is rejected" verify_sha256_sidecar "${TMP}/artifact.bin"

cp "${ROOT}/channels/assessment-stable.json" "${TMP}/channel.json"
cp "${ROOT}/channels/assessment-stable.json.minisig" "${TMP}/channel.json.minisig"
if verify_minisign_file "${TMP}/channel.json" "${TMP}/channel.json.minisig" "${ROOT}/public-keys/update-neosecra-com.pub"; then
  pass "valid minisign signature accepted"
else
  fail "valid minisign signature accepted"
fi
printf '\n' >> "${TMP}/channel.json"
expect_fail "archive/channel minisig mismatch is rejected" \
  verify_minisign_file "${TMP}/channel.json" "${TMP}/channel.json.minisig" "${ROOT}/public-keys/update-neosecra-com.pub"

AGENT="${ROOT}/deployment/v1/agent/update-agent.sh"
HOTSPOT="${ROOT}/deployment/v1/agent/hotspot-updater.sh"
INSTALLER="${ROOT}/deployment/v1/agent/install-agent.sh"
HOTSPOT_INSTALLER="${ROOT}/deployment/v1/agent/install-hotspot-agent.sh"
if rg -q 'artifact-verifier\.sh' "${INSTALLER}" && rg -q 'artifact-verifier\.sh' "${HOTSPOT_INSTALLER}"; then
  pass "both installers provision the artifact verifier helper"
else
  fail "both installers provision the artifact verifier helper"
fi
if [[ -x "${INSTALLER}" && -x "${HOTSPOT_INSTALLER}" ]]; then
  pass "both installers are executable"
else
  fail "both installers are executable"
fi
if rg -q 'UPGRADE_CHANNEL_URL not set; refusing unsigned channel metadata' "${AGENT}"; then
  pass "missing channel URL fails closed"
else
  fail "missing channel URL fails closed"
fi
if rg -q 'HEALTH_CHECK_FAILED' "${HOTSPOT}" && rg -q 'ROLLED_BACK' "${HOTSPOT}" && rg -q 'run_compose.*migrate' "${HOTSPOT}"; then
  pass "Hotspot migration/health failure and rollback journal paths are present"
else
  fail "Hotspot migration/health failure and rollback journal paths are present"
fi

printf '\n%d passed, %d failed\n' "${PASS}" "${FAIL}"
(( FAIL == 0 ))
