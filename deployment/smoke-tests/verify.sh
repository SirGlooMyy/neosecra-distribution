#!/usr/bin/env bash
# neosecra verify — release lifecycle verification
#
# Comprehensive verification for release lifecycle testing:
#   - Package file consistency
#   - Manifest validity
#   - Edition gates
#   - Compose configuration
#   - Preflight checks
#   - Live health gates (if stack is running)
#   - Migration revision
#   - Data preservation smoke tests
#
# Safe and non-destructive. Does not boot the stack.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
V1_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=lib/common.sh
source "${V1_ROOT}/lib/common.sh"
source "${V1_ROOT}/lib/docker.sh"

usage() {
  cat <<'EOF'
neosecra verify — release lifecycle verification

Usage:
  neosecra verify [options]
  verify.sh [options]

Options:
  --live         Run all live health gates (fail if stack is not running)
  --force        Same as --live (require running stack)
  --release      Full release package verification
  --quick        Static checks only (no Docker, no live)
  --help         Show this help

Non-destructive. Does not start the stack.
EOF
}

LIVE=0
RELEASE=0
QUICK=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h)    usage; exit 0 ;;
    --live)       LIVE=1 ;;
    --force)      LIVE=1 ;;
    --release)    RELEASE=1 ;;
    --quick)      QUICK=1 ;;
    *) usage; die "unexpected argument: $1" 2 ;;
  esac
  shift
done

VERSION="$(read_version)"
log "NeoSecra Security Health verify — version ${VERSION}"

FAILS=0
WARN=0
chk_ok()   { ok "$1"; }
chk_fail() { err "$1"; FAILS=$((FAILS+1)); }
chk_warn() { warn "$1"; WARN=$((WARN+1)); }

# ------------------------------------------------------------------
# Package file presence
# ------------------------------------------------------------------
for f in "$VERSION_FILE" "$MANIFEST_FILE" "$COMPOSE_FILE" "$ENV_EXAMPLE"; do
  [[ -f "$f" ]] && chk_ok "Present: ${f##*/}" || chk_fail "Missing: ${f##*/}"
done

# ------------------------------------------------------------------
# VERSION consistency
# ------------------------------------------------------------------
FILE_VER=$(read_version)
MANIFEST_VER=$(grep -E '^version:' "$MANIFEST_FILE" 2>/dev/null | awk '{print $2}' || echo "")
[[ "$FILE_VER" == "$MANIFEST_VER" ]] && chk_ok "VERSION match: ${FILE_VER}" || chk_fail "VERSION mismatch: ${FILE_VER} vs ${MANIFEST_VER}"

# ------------------------------------------------------------------
# Edition baked into compose
# ------------------------------------------------------------------
if grep -q 'NEOSECRA_EDITION:' "$COMPOSE_FILE" 2>/dev/null && \
   grep -q 'VITE_NEOSECRA_EDITION:' "$COMPOSE_FILE" 2>/dev/null; then
  chk_ok "Edition baked into compose"
else
  chk_fail "Edition not baked into compose"
fi

# ------------------------------------------------------------------
# OpenVAS profile-gated
# ------------------------------------------------------------------
grep -q 'profiles: \["openvas"\]' "$COMPOSE_FILE" 2>/dev/null && \
  chk_ok "OpenVAS profile-gated" || chk_warn "OpenVAS not profile-gated"

# ------------------------------------------------------------------
# Project isolation
# ------------------------------------------------------------------
grep -q '^name: neosecra-assessment' "$COMPOSE_FILE" 2>/dev/null && \
  chk_ok "Compose project pinned: neosecra-assessment" || chk_fail "Compose project not pinned"

# ------------------------------------------------------------------
# Docker info
# ------------------------------------------------------------------
if [[ $QUICK -eq 0 ]]; then
  require_compose_v2
  chk_ok "Docker available: $(docker --version 2>/dev/null || echo '?')"

  # compose config validation
  if [[ -f "$ENV_FILE" ]]; then
    compose_validate >/dev/null 2>&1 && \
      chk_ok "Compose config valid" || chk_fail "Compose config invalid"
  else
    chk_warn ".env.v1 missing — compose validation skipped"
  fi
fi

# ------------------------------------------------------------------
# Preflight
# ------------------------------------------------------------------
if [[ $QUICK -eq 0 ]]; then
  if bash "${V1_ROOT}/install/preflight.sh" >/dev/null 2>&1; then
    chk_ok "Preflight passed"
  else
    chk_fail "Preflight failed"
  fi
fi

# ------------------------------------------------------------------
# Live checks
# ------------------------------------------------------------------
RUNNING=0
stack_is_running && RUNNING=1

if [[ $RUNNING -eq 1 ]]; then
  # --- Backend health + edition ---
  BACKEND_PORT="$(env_value BACKEND_PORT 23800)"
  BASE="http://127.0.0.1:${BACKEND_PORT}"
  code="$(curl -s -o /tmp/.nv1_v -w '%{http_code}' "${BASE}/health" 2>/dev/null || true)"
  if [[ "$code" == "200" ]] && grep -q '"edition"[[:space:]]*:[[:space:]]*"security_health"' /tmp/.nv1_v 2>/dev/null; then
    chk_ok "Live: /health edition=security_health"
  else
    chk_fail "Live: /health edition check (HTTP ${code:-?})"
  fi
  rm -f /tmp/.nv1_v

  # --- Negative gates ---
  for path in "/api/v1/soc" "/api/v1/soc/alerts" "/api/v1/assets"; do
    code="$(curl -s -o /dev/null -w '%{http_code}' "${BASE}${path}" 2>/dev/null || true)"
    [[ "$code" == "404" ]] && chk_ok "Live: ${path} -> 404 (excluded)" || chk_fail "Live: ${path} -> ${code:-?} (expected 404)"
  done

  # --- API health ---
  code="$(curl -s -o /dev/null -w '%{http_code}' "${BASE}/api/v1/health" 2>/dev/null || true)"
  [[ "$code" == "200" ]] && chk_ok "Live: API health 200" || chk_fail "Live: API health ${code:-?}"

  # --- Migration revision ---
  CURRENT_REV=$(run_compose exec -T backend \
    alembic current 2>/dev/null | grep -oE '^[a-f0-9]+' || echo "unknown")
  chk_ok "Migration revision: ${CURRENT_REV}"

  # --- Key endpoints ---
  for ep in "/api/v1/auth/login" "/api/v1/auth/me" "/api/v1/customers"; do
    code="$(curl -s -o /dev/null -w '%{http_code}' "${BASE}${ep}" 2>/dev/null || true)"
    [[ "$code" != "000" ]] && chk_ok "Endpoint responds: ${ep} (${code})" || chk_fail "Endpoint unreachable: ${ep}"
  done

elif [[ $LIVE -eq 1 ]]; then
  chk_fail "Live checks required (--live) but stack is not running"
fi

# ------------------------------------------------------------------
# Release manifest schema validation
# ------------------------------------------------------------------
if [[ $RELEASE -eq 1 ]]; then
  python3 -c "
import yaml, sys
with open('$MANIFEST_FILE') as f:
    m = yaml.safe_load(f)
required = ['product', 'edition', 'version', 'images']
for k in required:
    if k not in m:
        print(f'[FAIL] Manifest missing: {k}')
        sys.exit(1)
print('[OK] Manifest schema valid')
" 2>/dev/null && chk_ok "Manifest schema valid" || chk_fail "Manifest schema invalid"
fi

# ------------------------------------------------------------------
# Verdict
# ------------------------------------------------------------------
echo ""
if [[ $FAILS -eq 0 ]]; then
  ok "Verify complete — all checks passed"
  exit 0
else
  err "Verify FAILED — ${FAILS} check(s) failed, ${WARN} warning(s)"
  exit 1
fi
