#!/usr/bin/env bash
# NeoSecra V1 — release baseline smoke verification.
#
# Verifies the V1 PACKAGE is self-consistent WITHOUT necessarily booting it:
#   - VERSION / release-manifest present and consistent
#   - edition is baked into the compose (security_health / security-health)
#   - docker compose config validates (needs .env.v1)
#   - preflight passes (Docker/Compose/ports/disk)
#   - IF the stack is running, live health + negative SOC/canonical gates
#
# Safe and non-destructive. Does not boot the stack.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
V1_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=lib/common.sh
source "${V1_ROOT}/lib/common.sh"

usage() {
  cat <<'EOF'
NeoSecra V1 smoke verification — package self-consistency + optional live checks.

Usage:
  verify-v1.sh [--live]            Static + config checks; live checks only if running.
  verify-v1.sh --live --force      Also require live health gates (fail if not running).
  verify-v1.sh --help

Non-destructive. Does not start the stack. Use --force to require live gates.
EOF
}

LIVE_FORCE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h)  usage; exit 0 ;;
    --live)     : ;;   # live checks auto-run when stack is up; flag kept for clarity
    --force)    LIVE_FORCE=1 ;;
    *) usage; die "unexpected argument: $1" 2 ;;
  esac
  shift
done

VERSION="$(read_version)"
log "NeoSecra V1 smoke verification — version ${VERSION}"
require_compose_v2

fails=0
chk_ok()   { ok "$1"; }
chk_fail() { err "$1"; fails=$((fails+1)); }

# --- Package files ---
for f in "$VERSION_FILE" "$MANIFEST_FILE" "$COMPOSE_FILE" "$ENV_EXAMPLE"; do
  [[ -f "$f" ]] && chk_ok "present: ${f##*/}" || chk_fail "missing: $f"
done

# --- Version present in manifest ---
if grep -q "^version: ${VERSION}$" "$MANIFEST_FILE" 2>/dev/null; then
  chk_ok "manifest version matches VERSION (${VERSION})"
else
  chk_fail "manifest version does not match VERSION (${VERSION})"
fi

# --- Edition baked into compose ---
if grep -q 'NEOSECRA_EDITION: security_health' "$COMPOSE_FILE" \
  && grep -q 'VITE_NEOSECRA_EDITION: security-health' "$COMPOSE_FILE"; then
  chk_ok "edition baked into compose (security_health / security-health)"
else
  chk_fail "edition not baked into compose"
fi

# --- OpenVAS is profile-gated (optional), not default ---
if grep -q 'profiles: \["openvas"\]' "$COMPOSE_FILE"; then
  chk_ok "OpenVAS is profile-gated (optional, default off)"
else
  chk_fail "OpenVAS not profile-gated"
fi

# --- Isolation: pinned project name + dedicated volumes ---
if grep -q '^name: neosecra-v1' "$COMPOSE_FILE"; then
  chk_ok "compose project pinned: neosecra-v1"
else
  chk_fail "compose project not pinned to neosecra-v1"
fi

# --- compose config validates (needs .env.v1) ---
if [[ -f "$ENV_FILE" ]]; then
  if docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" config >/dev/null 2>&1; then
    chk_ok "docker compose config valid"
  else
    chk_fail "docker compose config invalid"
  fi
else
  warn ".env.v1 missing — compose config validation skipped (create from .env.v1.example)"
fi

# --- Preflight ---
log "running preflight (read-only)..."
if bash "${V1_ROOT}/install/preflight.sh" >/dev/null 2>&1; then
  chk_ok "preflight passed"
else
  # preflight may exit non-zero on hard failures (port conflict, etc.)
  chk_fail "preflight reported a hard failure — run install/preflight.sh for details"
fi

# --- Live checks (only if stack is running) ---
if stack_is_running; then
  log "stack is running — running live health + negative gates..."
  BACKEND_PORT="$(env_value BACKEND_PORT 23800)"
  BASE="http://127.0.0.1:${BACKEND_PORT}"
  code="$(curl -s -o /tmp/.nv1_h -w '%{http_code}' "${BASE}/health" 2>/dev/null || true)"
  if [[ "$code" == "200" ]] && grep -q '"edition"[[:space:]]*:[[:space:]]*"security_health"' /tmp/.nv1_h 2>/dev/null; then
    chk_ok "live: /health edition=security_health"
  else
    chk_fail "live: /health edition check failed (HTTP ${code:-?})"
  fi
  rm -f /tmp/.nv1_h
  for path in "/api/v1/soc" "/api/v1/assets"; do
    code="$(curl -s -o /dev/null -w '%{http_code}' "${BASE}${path}" 2>/dev/null || true)"
    [[ "$code" == "404" ]] && chk_ok "live: ${path} -> 404 (excluded)" || chk_fail "live: ${path} -> ${code:-?} (expected 404)"
  done
else
  if [[ $LIVE_FORCE -eq 1 ]]; then
    chk_fail "live checks required (--force) but stack is not running"
  else
    warn "stack not running — live health/negative gates skipped (V1_INSTALLER_RUNTIME_NOT_VERIFIED)."
  fi
fi

echo ""
if [[ $fails -eq 0 ]]; then
  ok "V1 smoke verification PASSED (version ${VERSION})."
  exit 0
else
  err "V1 smoke verification FAILED — ${fails} check(s) failed."
  exit 1
fi
