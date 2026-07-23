#!/usr/bin/env bash
# neosecra verify — post-install health verification
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
V1_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${V1_ROOT}/lib/common.sh"
source "${V1_ROOT}/lib/manifest.sh"
source "${V1_ROOT}/lib/state.sh"

TIMEOUT=60; FAILS=0
usage() { cat <<'EOF'
neosecra verify — stack health verification
Usage: neosecra verify [--timeout 60] [--help]
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h)    usage; exit 0 ;;
    --timeout)    shift; TIMEOUT="$1" ;;
    *) usage; die "unexpected argument: $1" 2 ;;
  esac
  shift
done

VERSION="$(read_version)"
log "NeoSecra Assessment verify — version ${VERSION}"

chk_pass() { ok "$1"; }
chk_fail() { err "$1"; FAILS=$((FAILS+1)); }

require_compose_v2
stack_is_running || die "Stack not running — start with: neosecra install" 1

# --- PostgreSQL ---
PGUSER="$(env_value POSTGRES_USER neosecra)"
PGDB="$(env_value POSTGRES_DB neosecra_assessment)"
run_compose exec -T postgres pg_isready -U "$PGUSER" -d "$PGDB" >/dev/null 2>&1 && \
  chk_pass "PostgreSQL healthy" || chk_fail "PostgreSQL not healthy"

# --- Redis ---
run_compose exec -T redis redis-cli ping 2>/dev/null | grep -q PONG && \
  chk_pass "Redis healthy" || chk_fail "Redis not healthy"

# --- Backend ---
BACKEND_PORT="$(env_value BACKEND_PORT 25800)"
BASE="http://127.0.0.1:${BACKEND_PORT}"
HEALTHY=0
for _ in $(seq 1 "$TIMEOUT"); do
  code=$(curl -s -o /tmp/.nv_h -w '%{http_code}' "${BASE}/health" 2>/dev/null || true)
  if [[ "$code" == "200" ]]; then
    edition=$(grep -oE '"edition"[[:space:]]*:[[:space:]]*"[^"]*"' /tmp/.nv_h 2>/dev/null | head -1 | sed -E 's/.*"([^"]+)".*/\1/')
    [[ "$edition" == "security_health" ]] && { chk_pass "Backend healthy, edition=security_health"; HEALTHY=1; break; }
  fi
  sleep 1
done
rm -f /tmp/.nv_h
[[ $HEALTHY -eq 1 ]] || chk_fail "Backend not healthy within ${TIMEOUT}s"

# --- Worker ---
run_compose ps --status running worker 2>/dev/null | grep -q worker && \
  chk_pass "Worker running" || chk_warn "Worker not running"

# --- Frontend ---
FRONTEND_PORT="$(env_value FRONTEND_PORT 25300)"
f_code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${FRONTEND_PORT}" 2>/dev/null || true)
[[ "$f_code" =~ ^(200|304|301|302)$ ]] && chk_pass "Frontend responds (HTTP ${f_code})" || chk_warn "Frontend HTTP ${f_code:-?}"

# --- API endpoints ---
if [[ $HEALTHY -eq 1 ]]; then
  for ep in "/api/v1/health" "/api/v1/auth/login" "/api/v1/auth/me" "/api/v1/customers" "/api/v1/assets/device" \
            "/api/v1/fortigate" "/api/v1/active-directory" "/api/v1/veeam" "/api/v1/m365" \
            "/api/v1/scans" "/api/v1/findings" "/api/v1/reports"; do
    code=$(curl -s -o /dev/null -w '%{http_code}' "${BASE}${ep}" 2>/dev/null || true)
    [[ "$code" != "000" ]] && chk_pass "  ${ep} (${code})" || chk_fail "  ${ep} unreachable"
  done
fi

# --- Migration revision ---
cur_rev=$(run_compose exec -T backend alembic current 2>/dev/null | grep -oE '^[a-f0-9]+' || echo "?")
chk_pass "Migration revision: ${cur_rev}"

# --- Product identity ---
check_product_identity

# --- Version ---
act_ver=$(read_installed_version 2>/dev/null || echo "?")
chk_pass "Active version: ${act_ver}"

echo ""
if [[ $FAILS -eq 0 ]]; then
  ok "Verify PASSED — all ${FAILS} checks"
  exit 0
else
  err "Verify FAILED — ${FAILS} failure(s)"
  exit 1
fi
