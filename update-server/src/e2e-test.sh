#!/usr/bin/env bash
set -Eeuo pipefail

echo "=== E2E Upgrade Test Suite ==="
BASE_URL="${UPDATE_SERVER_BASE_URL:-https://update.neosecra.com}"
CHANNEL_NAME="${UPDATE_SERVER_CHANNEL:-assessment-stable}"
EXPECTED_VERSION="${UPDATE_SERVER_EXPECTED_VERSION:-}"
ARCHIVE_OVERRIDE="${UPDATE_SERVER_ARCHIVE_URL:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PUBLIC_KEY="${UPDATE_SERVER_PUBLIC_KEY:-${REPO_ROOT}/public-keys/update-neosecra-com.pub}"
CA_CERT="${UPDATE_SERVER_CA_CERT:-}"
if [[ "$BASE_URL" != http://* && "$BASE_URL" != https://* && "$BASE_URL" != file://* ]]; then
  echo "[ERROR] UPDATE_SERVER_BASE_URL must use http://, https:// or file://" >&2
  exit 2
fi
CURL_OPTS=(--fail --silent --show-error --location)
if [[ -n "$CA_CERT" ]]; then
  [[ -f "$CA_CERT" ]] || { echo "[ERROR] CA certificate not found: $CA_CERT" >&2; exit 2; }
  CURL_OPTS+=(--cacert "$CA_CERT")
fi
fetch() { curl "${CURL_OPTS[@]}" "$@"; }

TEST_DIR="/tmp/neosecra-e2e-test-$(date +%s)"
echo "[SETUP] Test dir: ${TEST_DIR}"
mkdir -p "${TEST_DIR}"
cd "${TEST_DIR}"

CHAN_URL="${BASE_URL}/channels/${CHANNEL_NAME}.json"
fetch -o channel.json "$CHAN_URL"
fetch -o channel.json.minisig "${CHAN_URL}.minisig"
if [[ -f "${PUBLIC_KEY}" ]] && minisign -V -p "${PUBLIC_KEY}" -m channel.json -x channel.json.minisig -q; then
  echo "[SETUP] Channel minisig verified"
else
  echo "[ERROR] Channel minisig verification failed (set UPDATE_SERVER_PUBLIC_KEY to a trusted key file)" >&2
  exit 4
fi
if [[ -z "$EXPECTED_VERSION" ]]; then
  EXPECTED_VERSION="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("current_version") or "")' channel.json)"
fi
[[ -n "$EXPECTED_VERSION" ]] || { echo "[ERROR] Channel has no current_version" >&2; exit 2; }
ARCHIVE_URL="$(python3 -c '
import json,sys
d=json.load(open("channel.json")); v=sys.argv[1]
for release in d.get("releases", []):
    if release.get("version") == v:
        archive=release.get("archive", {})
        print((archive.get("url") if isinstance(archive, dict) else archive) or release.get("url") or "")
        break
' "$EXPECTED_VERSION")"
[[ -n "$ARCHIVE_URL" ]] || { echo "[ERROR] No archive for ${EXPECTED_VERSION}" >&2; exit 2; }
if [[ -n "$ARCHIVE_OVERRIDE" ]]; then
  ARCHIVE_URL="$ARCHIVE_OVERRIDE"
fi
fetch -o dist.tar.gz "$ARCHIVE_URL"
SHA256_FILE="$(sha256sum dist.tar.gz | cut -d' ' -f1)"
echo "[SETUP] SHA256: ${SHA256_FILE}"

tar xzf dist.tar.gz
DIST_DIR="$(find . -mindepth 1 -maxdepth 1 -type d -name 'neosecra-distribution-*' | head -n1)"
echo "[SETUP] DIST: ${DIST_DIR}"
cd "${DIST_DIR}"
RELEASE_DIR="${TEST_DIR}/release"
mkdir -p "${RELEASE_DIR}"
rsync -a deployment/ "${RELEASE_DIR}/"
cd "${RELEASE_DIR}"

echo "--- TEST 1: Channel resolves ${EXPECTED_VERSION} ---"
CHAN="$(cat "${TEST_DIR}/channel.json")"
VER="$(echo "${CHAN}" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d.get("current_version",""))')"
echo "Channel version: ${VER}"
if [ "${VER}" = "${EXPECTED_VERSION}" ]; then echo "TEST1: PASS"; else echo "TEST1: FAIL"; exit 1; fi

echo "--- TEST 2: Archive URL resolution ---"
ARCHIVE_URL="$(echo "${CHAN}" | python3 -c '
import json,sys
d=json.load(sys.stdin)
for r in d.get("releases",[]):
    if r.get("version")==sys.argv[1]:
        archive = r.get("archive", {})
        print((archive.get("url") if isinstance(archive, dict) else archive) or r.get("url", ""))
        break
' "${EXPECTED_VERSION}")"
if [[ -n "$ARCHIVE_OVERRIDE" ]]; then
  ARCHIVE_URL="$ARCHIVE_OVERRIDE"
fi
echo "Archive URL: ${ARCHIVE_URL}"
if [ -n "${ARCHIVE_URL}" ]; then echo "TEST2: PASS"; else echo "TEST2: FAIL"; exit 1; fi

echo "--- TEST 3: SHA-256 verification ---"
EXPECTED="$(echo "${CHAN}" | python3 -c '
import json,sys
d=json.load(sys.stdin)
for r in d.get("releases",[]):
    if r.get("version")==sys.argv[1]:
        archive = r.get("archive", {})
        print((archive.get("sha256") if isinstance(archive, dict) else r.get("sha256", "")) or "")
        break
' "${EXPECTED_VERSION}")"
echo "Expected: ${EXPECTED}"
echo "Actual:   ${SHA256_FILE}"
if [ -n "${EXPECTED}" ] && [ "${EXPECTED}" = "${SHA256_FILE}" ]; then echo "TEST3: PASS"; else echo "TEST3: FAIL"; exit 1; fi

echo "--- TEST 4: Minisign signature ---"
SIG_URL="${ARCHIVE_URL}.minisig"
fetch -o "${TEST_DIR}/dist.tar.gz.minisig" "${SIG_URL}"
if [[ -f "${PUBLIC_KEY}" ]] && minisign -V -m "${TEST_DIR}/dist.tar.gz" -p "${PUBLIC_KEY}" -x "${TEST_DIR}/dist.tar.gz.minisig"; then echo "TEST4: PASS"; else echo "TEST4: FAIL (set UPDATE_SERVER_PUBLIC_KEY to a trusted key file)"; exit 1; fi

echo "--- TEST 5: Already-on-latest ---"
mkdir -p "${RELEASE_DIR}/state"
echo "${EXPECTED_VERSION}" > "${RELEASE_DIR}/state/installed-version"
if [ "${EXPECTED_VERSION}" = "${EXPECTED_VERSION}" ]; then echo "TEST5: PASS (already on latest)"; else echo "TEST5: FAIL"; exit 1; fi

echo "--- TEST 6: Downgrade protection ---"
ver_ge() {
  local a="$1" b="$2"
  local apad bpad
  apad="$(printf '%s' "$a" | awk -F. '{printf "%010d_%010d_%010d\n", $1, $2, $3}' 2>/dev/null || echo "$a")"
  bpad="$(printf '%s' "$b" | awk -F. '{printf "%010d_%010d_%010d\n", $1, $2, $3}' 2>/dev/null || echo "$b")"
  [ "$apad" \< "$bpad" ] && return 1
  return 0
}
if ver_ge "${EXPECTED_VERSION}" "0.0.1"; then echo "TEST6: PASS (downgrade detected)"; else echo "TEST6: FAIL"; exit 1; fi

echo "--- TEST 7: Downgrade override ---"
NEOSECRA_ALLOW_DOWNGRADE=1
if ver_ge "${EXPECTED_VERSION}" "0.0.1" && [ "${NEOSECRA_ALLOW_DOWNGRADE}" = "1" ]; then echo "TEST7: PASS (override works)"; else echo "TEST7: FAIL"; exit 1; fi

echo "--- TEST 8: Archive structure ---"
BOOT_TMP="$(mktemp -d)"
cd "${BOOT_TMP}"
tar xzf "${TEST_DIR}/dist.tar.gz"
BD="$(find . -mindepth 1 -maxdepth 1 -type d -name 'neosecra-distribution-*' | head -n1)"
if [ -f "${BD}/bootstrap.sh" ] && [ -d "${BD}/deployment" ]; then echo "TEST8: PASS (archive structure OK)"; else echo "TEST8: FAIL"; exit 1; fi
rm -rf "${BOOT_TMP}"

echo ""
echo "=== ALL 8 TESTS PASSED ==="
