#!/usr/bin/env bash
# Regression Test Suite for T4 (TLS) + T5 (Schema) fixes
# Runs locally without touching live update server.
set -Euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cd "$REPO_ROOT"

PASS=0; FAIL=0
TEST_DIR=/tmp/neosecra-reg-test-fixed
mkdir -p "/tmp/neosecra-reg-test-fixed"
trap "rm -rf '/tmp/neosecra-reg-test-fixed'" EXIT

pass() { echo "  PASS: $1"; ((PASS++)); }
fail() { echo "  FAIL: $1"; ((FAIL++)); }
check() {
  if "$@"; then
    pass "$1 $2"
  else
    fail "$1 $2"
  fi
}

echo ""
echo "=========================================="
echo " NeoSecra Regression Tests -- T4 + T5"
echo "=========================================="

# ===== T4 TLS: CA Trust =====
echo ""
echo "--- T4 TLS: CA Trust ---"

echo -n "T4.1: CA cert is valid PEM ... "
if openssl x509 -in update-server/ca/update-neosecra-com-root.crt -noout 2>/dev/null; then
  pass "CA cert is valid PEM"
else
  fail "CA cert is invalid"
fi

echo -n "T4.2: CA cert has CA:TRUE ... "
if openssl x509 -in update-server/ca/update-neosecra-com-root.crt -text -noout 2>/dev/null | grep -q "CA:TRUE"; then
  pass "CA has CA:TRUE"
else
  fail "CA missing CA:TRUE"
fi

echo -n "T4.3: Leaf cert signed by CA ... "
if openssl verify -CAfile update-server/ca/update-neosecra-com-root.crt update-server/certs/update-neosecra-com.crt >/dev/null 2>&1; then
  pass "Leaf cert signed by CA"
else
  fail "Leaf cert NOT signed by CA"
fi

echo -n "T4.4: Leaf cert SAN includes update.neosecra.com ... "
if openssl x509 -in update-server/certs/update-neosecra-com.crt -text -noout 2>/dev/null | grep -A1 "Subject Alternative Name" | grep -q "DNS:update.neosecra.com"; then
  pass "Leaf cert SAN includes update.neosecra.com"
else
  fail "Leaf cert missing update.neosecra.com SAN"
fi

echo -n "T4.5: bootstrap.sh embedded CA matches actual CA ... "
CA_FP_FILE=$(openssl x509 -in update-server/ca/update-neosecra-com-root.crt -fingerprint -sha256 -noout 2>/dev/null)
# Use python to reliably extract + decode the base64
PY_OUT=$(python3 -c "
import base64, re
with open('bootstrap.sh') as f:
    c = f.read()
m = re.search(r\"NEOSECRA_CA_B64='([^']+)'\", c)
if m:
    decoded = base64.b64decode(m.group(1))
    with open('/tmp/ca_extracted.crt', 'wb') as f:
        f.write(decoded)
    print('OK')
else:
    print('FAIL')
" 2>&1)
if [[ "$PY_OUT" == "OK" ]]; then
  CA_FP_EXTRACTED=$(openssl x509 -in /tmp/ca_extracted.crt -fingerprint -sha256 -noout 2>/dev/null || echo "FAIL")
  if [[ "$CA_FP_FILE" == "$CA_FP_EXTRACTED" ]]; then
    pass "bootstrap.sh embedded CA fingerprint matches"
  else
    fail "bootstrap.sh embedded CA fingerprint MISMATCH"
    echo "      File: ${CA_FP_FILE}"
    echo "      Embedded: ${CA_FP_EXTRACTED}"
  fi
  rm -f /tmp/ca_extracted.crt
else
  fail "Could not extract base64 from bootstrap.sh"
fi

# ===== T5 Schema: Backward-compatible JSON parsing =====
echo ""
echo "--- T5 Schema: Backward-compatible JSON parsing ---"

# Create test JSONs
cat > "/tmp/neosecra-reg-test-fixed/nested.json" << 'JSONEOF'
{
  "channel": "assessment-stable",
  "current_version": "1.1.1",
  "releases": [
    {
      "version": "1.1.1",
      "archive": {
        "url": "https://update.neosecra.com/releases/1.1.1/distribution.tar.gz",
        "sha256": "8df44f104adb4147e55a7d66f33ea75f79a1088b697d8974e94b6922b3974530",
        "size_bytes": 78028
      }
    }
  ]
}
JSONEOF

cat > "/tmp/neosecra-reg-test-fixed/flat.json" << 'JSONEOF'
{
  "channel": "assessment-stable",
  "current_version": "1.0.9",
  "releases": [
    {
      "version": "1.0.9",
      "archive": "https://github.com/SirGlooMyy/neosecra-distribution/archive/refs/heads/fix/assessment-live-installer.tar.gz",
      "sha256": "abc123"
    }
  ]
}
JSONEOF

# Python3: archive URL resolution (nested)
echo -n "T5.1: Python3 nested -> archive URL ... "
RESULT=$(python3 -c "
import json
with open('/tmp/neosecra-reg-test-fixed/nested.json') as f:
    d = json.load(f)
for r in d.get('releases',[]):
    if r.get('version')=='1.1.1':
        a = r.get('archive',{})
        if isinstance(a, dict):
            print(a.get('url','') or '')
        else:
            print(a or r.get('url','') or '')
        break
" 2>/dev/null)
[[ "$RESULT" == "https://update.neosecra.com/releases/1.1.1/distribution.tar.gz" ]] \
  && pass "Python3 nested URL" \
  || fail "Python3 nested got: $RESULT"

# Python3: archive URL resolution (flat)
echo -n "T5.2: Python3 flat -> archive URL ... "
RESULT=$(python3 -c "
import json
with open('/tmp/neosecra-reg-test-fixed/flat.json') as f:
    d = json.load(f)
for r in d.get('releases',[]):
    if r.get('version')=='1.0.9':
        a = r.get('archive',{})
        if isinstance(a, dict):
            print(a.get('url','') or '')
        else:
            print(a or r.get('url','') or '')
        break
" 2>/dev/null)
[[ "$RESULT" == "https://github.com/SirGlooMyy/neosecra-distribution/archive/refs/heads/fix/assessment-live-installer.tar.gz" ]] \
  && pass "Python3 flat URL" \
  || fail "Python3 flat got: $RESULT"

# Python3: sha256 resolution (nested)
echo -n "T5.3: Python3 nested -> sha256 ... "
RESULT=$(python3 -c "
import json
with open('/tmp/neosecra-reg-test-fixed/nested.json') as f:
    d = json.load(f)
for r in d.get('releases',[]):
    if r.get('version')=='1.1.1':
        a = r.get('archive',{})
        if isinstance(a, dict):
            print(a.get('sha256','') or '')
        else:
            print(r.get('sha256','') or '')
        break
" 2>/dev/null)
[[ "$RESULT" == "8df44f104adb4147e55a7d66f33ea75f79a1088b697d8974e94b6922b3974530" ]] \
  && pass "Python3 nested sha256" \
  || fail "Python3 nested sha256 got: $RESULT"

# Python3: sha256 resolution (flat)
echo -n "T5.4: Python3 flat -> sha256 ... "
RESULT=$(python3 -c "
import json
with open('/tmp/neosecra-reg-test-fixed/flat.json') as f:
    d = json.load(f)
for r in d.get('releases',[]):
    if r.get('version')=='1.0.9':
        a = r.get('archive',{})
        if isinstance(a, dict):
            print(a.get('sha256','') or '')
        else:
            print(r.get('sha256','') or '')
        break
" 2>/dev/null)
[[ "$RESULT" == "abc123" ]] \
  && pass "Python3 flat sha256" \
  || fail "Python3 flat sha256 got: $RESULT"

# jq parser
if command -v jq &>/dev/null; then
  echo -n "T5.5: jq nested -> archive URL ... "
  RESULT=$(jq -r --arg v "1.1.1" '.releases[] | select(.version==$v) | ((.archive | if type=="object" then .url else . end) // .url // empty)' "/tmp/neosecra-reg-test-fixed/nested.json" 2>/dev/null)
  [[ "$RESULT" == "https://update.neosecra.com/releases/1.1.1/distribution.tar.gz" ]] \
    && pass "jq nested URL" \
    || fail "jq nested got: $RESULT"

  echo -n "T5.6: jq nested -> sha256 ... "
  RESULT=$(jq -r --arg v "1.1.1" '.releases[] | select(.version==$v) | ((.archive | if type=="object" then .sha256 else empty end) // .sha256 // empty)' "/tmp/neosecra-reg-test-fixed/nested.json" 2>/dev/null)
  [[ "$RESULT" == "8df44f104adb4147e55a7d66f33ea75f79a1088b697d8974e94b6922b3974530" ]] \
    && pass "jq nested sha256" \
    || fail "jq nested sha256 got: $RESULT"

  echo -n "T5.7: jq flat -> archive URL ... "
  RESULT=$(jq -r --arg v "1.0.9" '.releases[] | select(.version==$v) | ((.archive | if type=="object" then .url else . end) // .url // empty)' "/tmp/neosecra-reg-test-fixed/flat.json" 2>/dev/null)
  [[ "$RESULT" == "https://github.com/SirGlooMyy/neosecra-distribution/archive/refs/heads/fix/assessment-live-installer.tar.gz" ]] \
    && pass "jq flat URL" \
    || fail "jq flat got: $RESULT"

  echo -n "T5.8: jq flat -> sha256 ... "
  RESULT=$(jq -r --arg v "1.0.9" '.releases[] | select(.version==$v) | ((.archive | if type=="object" then .sha256 else empty end) // .sha256 // empty)' "/tmp/neosecra-reg-test-fixed/flat.json" 2>/dev/null)
  [[ "$RESULT" == "abc123" ]] \
    && pass "jq flat sha256" \
    || fail "jq flat sha256 got: $RESULT"
else
  echo "  SKIP: jq not installed (tests 5.5-5.8)"
fi

# grep/sed fallback
echo -n "T5.9: grep/sed nested -> archive URL ... "
RESULT=$(VBLOCK=$(grep -A10 '"version":[[:space:]]*"1.1.1"' "/tmp/neosecra-reg-test-fixed/nested.json" 2>/dev/null); printf '%s\n' "$VBLOCK" | grep -A6 '"archive":[[:space:]]*{' | grep '"url"' | sed -nE 's/.*"url"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' | head -n1)
[[ "$RESULT" == "https://update.neosecra.com/releases/1.1.1/distribution.tar.gz" ]] \
  && pass "grep/sed nested URL" \
  || fail "grep/sed nested URL got: $RESULT"

echo -n "T5.10: grep/sed flat -> archive URL ... "
RESULT=$(grep -A5 '"version":[[:space:]]*"1.0.9"' "/tmp/neosecra-reg-test-fixed/flat.json" 2>/dev/null | sed -nE 's/.*"(archive|url)"[[:space:]]*:[[:space:]]*"([^"]+)".*/\2/p' | head -n1)
[[ "$RESULT" == "https://github.com/SirGlooMyy/neosecra-distribution/archive/refs/heads/fix/assessment-live-installer.tar.gz" ]] \
  && pass "grep/sed flat URL" \
  || fail "grep/sed flat URL got: $RESULT"

echo -n "T5.11: grep/sed nested -> sha256 ... "
RESULT=$(VBLOCK=$(grep -A10 '"version":[[:space:]]*"1.1.1"' "/tmp/neosecra-reg-test-fixed/nested.json" 2>/dev/null); printf '%s\n' "$VBLOCK" | grep -A6 '"archive":[[:space:]]*{' | grep '"sha256"' | sed -nE 's/.*"sha256"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' | head -n1)
[[ "$RESULT" == "8df44f104adb4147e55a7d66f33ea75f79a1088b697d8974e94b6922b3974530" ]] \
  && pass "grep/sed nested sha256" \
  || fail "grep/sed nested sha256 got: $RESULT"

echo -n "T5.12: grep/sed flat -> sha256 ... "
RESULT=$(grep -A8 '"version":[[:space:]]*"1.0.9"' "/tmp/neosecra-reg-test-fixed/flat.json" 2>/dev/null | sed -nE 's/.*"sha256"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' | head -n1)
[[ "$RESULT" == "abc123" ]] \
  && pass "grep/sed flat sha256" \
  || fail "grep/sed flat sha256 got: $RESULT"

# ===== T1-T3, T6 Regression: Existing channel structure preserved =====
echo ""
echo "--- T1-T3, T6 Regression: Channel structure ---"

echo -n "Regression: channels/*.json valid JSON ... "
ALL_VALID=0
for f in channels/*.json; do
  python3 -c "import json; json.load(open('$f'))" 2>/dev/null || { ALL_VALID=1; break; }
done
[[ $ALL_VALID -eq 0 ]] && pass "all channel JSONs valid" || fail "some channel JSON invalid"

echo -n "Regression: current_version field ... "
VER=$(python3 -c "import json; d=json.load(open('channels/assessment-stable.json')); print(d.get('current_version','MISSING'))" 2>/dev/null)
[[ "$VER" != "MISSING" ]] \
  && pass "assessment-stable current_version=$VER" \
  || fail "assessment-stable missing current_version"

# ===== Summary =====
echo ""
echo "=========================================="
echo " Results: ${PASS} passed, ${FAIL} failed"
echo "=========================================="
[[ $FAIL -gt 0 ]] && exit 1 || exit 0
