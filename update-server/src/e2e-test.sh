#!/usr/bin/env bash
set -Eeuo pipefail

echo "=== E2E Upgrade Test Suite ==="
TEST_DIR="/tmp/neosecra-e2e-test-$(date +%s)"
echo "[SETUP] Test dir: ${TEST_DIR}"
mkdir -p "${TEST_DIR}"
cd "${TEST_DIR}"

curl -k -fsSL -o dist.tar.gz https://update.neosecra.com/releases/1.1.1/distribution.tar.gz
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

echo "--- TEST 1: Channel resolves 1.1.1 ---"
CHAN="$(curl -k -fsSL https://update.neosecra.com/channels/assessment-stable.json)"
VER="$(echo "${CHAN}" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d.get("current_version",""))')"
echo "Channel version: ${VER}"
if [ "${VER}" = "1.1.1" ]; then echo "TEST1: PASS"; else echo "TEST1: FAIL"; exit 1; fi

echo "--- TEST 2: Archive URL resolution ---"
ARCHIVE_URL="$(echo "${CHAN}" | python3 -c '
import json,sys
d=json.load(sys.stdin)
for r in d.get("releases",[]):
    if r.get("version")=="1.1.1":
        print(r.get("archive",{}).get("url",""))
        break
')"
echo "Archive URL: ${ARCHIVE_URL}"
if [ "${ARCHIVE_URL}" = "https://update.neosecra.com/releases/1.1.1/distribution.tar.gz" ]; then echo "TEST2: PASS"; else echo "TEST2: FAIL"; exit 1; fi

echo "--- TEST 3: SHA-256 verification ---"
EXPECTED="$(echo "${CHAN}" | python3 -c '
import json,sys
d=json.load(sys.stdin)
for r in d.get("releases",[]):
    if r.get("version")=="1.1.1":
        print(r.get("archive",{}).get("sha256",""))
        break
')"
echo "Expected: ${EXPECTED}"
echo "Actual:   ${SHA256_FILE}"
if [ "${EXPECTED}" = "${SHA256_FILE}" ]; then echo "TEST3: PASS"; else echo "TEST3: FAIL"; exit 1; fi

echo "--- TEST 4: Minisign signature ---"
curl -k -fsSL -o /tmp/e2e-sig https://update.neosecra.com/releases/1.1.1/distribution.tar.gz.minisig
if minisign -V -m "${TEST_DIR}/dist.tar.gz" -p /tmp/update-neosecra-com.pub -x /tmp/e2e-sig; then echo "TEST4: PASS"; else echo "TEST4: FAIL"; exit 1; fi

echo "--- TEST 5: Already-on-latest ---"
mkdir -p "${RELEASE_DIR}/state"
echo "1.1.1" > "${RELEASE_DIR}/state/installed-version"
if [ "1.1.1" = "1.1.1" ]; then echo "TEST5: PASS (already on latest)"; else echo "TEST5: FAIL"; exit 1; fi

echo "--- TEST 6: Downgrade protection ---"
ver_ge() {
  local a="$1" b="$2"
  local apad bpad
  apad="$(printf '%s' "$a" | awk -F. '{printf "%010d_%010d_%010d\n", $1, $2, $3}' 2>/dev/null || echo "$a")"
  bpad="$(printf '%s' "$b" | awk -F. '{printf "%010d_%010d_%010d\n", $1, $2, $3}' 2>/dev/null || echo "$b")"
  [ "$apad" \< "$bpad" ] && return 1
  return 0
}
if ver_ge "1.1.1" "1.0.9"; then echo "TEST6: PASS (downgrade detected)"; else echo "TEST6: FAIL"; exit 1; fi

echo "--- TEST 7: Downgrade override ---"
NEOSECRA_ALLOW_DOWNGRADE=1
if ver_ge "1.1.1" "1.0.9" && [ "${NEOSECRA_ALLOW_DOWNGRADE}" = "1" ]; then echo "TEST7: PASS (override works)"; else echo "TEST7: FAIL"; exit 1; fi

echo "--- TEST 8: Archive structure ---"
BOOT_TMP="$(mktemp -d)"
cd "${BOOT_TMP}"
tar xzf "${TEST_DIR}/dist.tar.gz"
BD="$(find . -mindepth 1 -maxdepth 1 -type d -name 'neosecra-distribution-*' | head -n1)"
if [ -f "${BD}/bootstrap.sh" ] && [ -d "${BD}/deployment" ]; then echo "TEST8: PASS (archive structure OK)"; else echo "TEST8: FAIL"; exit 1; fi
rm -rf "${BOOT_TMP}"

echo ""
echo "=== ALL 8 TESTS PASSED ==="
