#!/usr/bin/env bash
# neosecra support-bundle — collect diagnostic information
#
# Produces a tarball with diagnostic data for troubleshooting.
# Does NOT include secrets, credentials, .env content, or customer data.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
V1_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=lib/common.sh
source "${V1_ROOT}/lib/common.sh"

INSTALL_DIR="/opt/neosecra/security-health"
JOURNAL_DIR="${INSTALL_DIR}/upgrade-journal"
STATE_DIR="${INSTALL_DIR}/state"

usage() {
  cat <<'EOF'
neosecra support-bundle — collect diagnostic information

Usage:
  neosecra support-bundle [--output <path>]
  support-bundle.sh [--output <path>]
  support-bundle.sh --help

Options:
  --output <path>   Output path for the bundle tarball (default: ./support-bundle-<timestamp>.tar.gz)
  --help            Show this help

Produces a diagnostic tarball containing:
  - Active version and product info
  - Container status
  - Health check results
  - Migration revision
  - Recent application logs
  - Upgrade journal summary
  - System information
  - Docker version and disk usage

Does NOT include:
  - .env file content
  - Passwords or tokens
  - Private keys
  - Database dumps
  - Customer report content
EOF
}

OUTPUT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h)     usage; exit 0 ;;
    --output)      shift; OUTPUT="$1" ;;
    *) usage; die "unexpected argument: $1" 2 ;;
  esac
  shift
done

VERSION="$(read_version)"
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
TMP_DIR=$(mktemp -d)
BUNDLE_DIR="${TMP_DIR}/neosecra-support-${STAMP}"
mkdir -p "$BUNDLE_DIR"

if [[ -z "$OUTPUT" ]]; then
  OUTPUT="${PWD}/support-bundle-${STAMP}.tar.gz"
fi

# Credential redaction patterns — never include secrets in support bundle
REDACT='<REDACTED>'
_redact_value() {
  sed -E \
    -e 's/(ghp_[a-zA-Z0-9]{36}|ghp_[a-zA-Z0-9]{36,})/'"$REDACT"'/g' \
    -e 's/(github_pat_[a-zA-Z0-9]{36,})/'"$REDACT"'/g' \
    -e 's/(Authorization: Bearer\s+)[a-zA-Z0-9_.-]+/\1'"$REDACT"'/g' \
    -e 's/(token\s*=\s*)[a-zA-Z0-9_]+/\1'"$REDACT"'/g' \
    -e 's/(password\s*=\s*)[a-zA-Z0-9_]+/\1'"$REDACT"'/g' \
    -e 's/(secret\s*=\s*)[a-zA-Z0-9_]+/\1'"$REDACT"'/g'
}

log "NeoSecra Security Health support-bundle -> ${OUTPUT}"

# --- Product info ---
{
  echo "product: neosecra-security-health"
  echo "edition: security-health"
  echo "version: ${VERSION}"
  echo "collection_time: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "hostname: $(hostname 2>/dev/null || echo 'unknown')"
} > "${BUNDLE_DIR}/product-info.yaml"

# --- Active version ---
if [[ -f "${STATE_DIR}/installed-version" ]]; then
  cp "${STATE_DIR}/installed-version" "${BUNDLE_DIR}/installed-version"
fi

# --- Container status ---
if stack_is_running 2>/dev/null; then
  run_compose ps > "${BUNDLE_DIR}/container-status.txt" 2>&1 || true
  docker stats --no-stream --no-trunc 2>/dev/null > "${BUNDLE_DIR}/container-stats.txt" || true
  echo "RUNNING" > "${BUNDLE_DIR}/stack-status"
else
  echo "NOT RUNNING" > "${BUNDLE_DIR}/stack-status"
fi

# --- Sanitized compose config ---
# Remove .env variable values from the config
if [[ -f "$COMPOSE_FILE" ]]; then
  # Strip potential sensitive content
  sed 's/POSTGRES_PASSWORD=.*/POSTGRES_PASSWORD=<redacted>/g' "$COMPOSE_FILE" \
    | sed 's/SECRET_KEY=.*/SECRET_KEY=<redacted>/g' \
    | sed 's/OTP_SECRET=.*/OTP_SECRET=<redacted>/g' \
    | sed 's/JWT_SECRET=.*/JWT_SECRET=<redacted>/g' \
    | sed 's/ENCRYPTION_KEY=.*/ENCRYPTION_KEY=<redacted>/g' \
    | sed 's/FIRST_ADMIN_PASSWORD=.*/FIRST_ADMIN_PASSWORD=<redacted>/g' \
    | sed 's/ADMIN_RECOVERY_KEY=.*/ADMIN_RECOVERY_KEY=<redacted>/g' \
    > "${BUNDLE_DIR}/docker-compose.sanitized.yml" 2>/dev/null || true
fi

# --- Health results (redacted) ---
bash "${V1_ROOT}/install/postflight.sh" --timeout 30 2>&1 | _redact_value > "${BUNDLE_DIR}/health-results.txt" || true

# --- Migration revision ---
if stack_is_running 2>/dev/null; then
  run_compose exec -T backend \
    alembic current 2>/dev/null > "${BUNDLE_DIR}/migration-revision.txt" || true
  run_compose exec -T backend \
    alembic history 2>/dev/null > "${BUNDLE_DIR}/migration-history.txt" || true
fi

# --- Application logs (last 200 lines, redacted) ---
if stack_is_running 2>/dev/null; then
  for service in backend frontend worker postgres redis; do
    run_compose logs --tail=200 "$service" \
      2>/dev/null | _redact_value > "${BUNDLE_DIR}/logs-${service}.txt" || true
  done
fi

# --- Upgrade journal summary ---
if [[ -d "$JOURNAL_DIR" ]]; then
  ls -lt "$JOURNAL_DIR" > "${BUNDLE_DIR}/upgrade-journal-index.txt" 2>/dev/null || true
  # Copy last 5 journals (safe — no secrets by contract)
  ls -t "$JOURNAL_DIR"/*.json 2>/dev/null | head -5 | while read -r jf; do
    cp "$jf" "${BUNDLE_DIR}/" 2>/dev/null || true
  done
fi

# --- System information ---
{
  echo "=== System Information ==="
  uname -a
  echo ""
  echo "=== OS Release ==="
  cat /etc/os-release 2>/dev/null || true
  echo ""
  echo "=== Memory ==="
  free -h
  echo ""
  echo "=== Disk ==="
  df -h / /var/lib/docker 2>/dev/null || true
  echo ""
  echo "=== Docker ==="
  docker --version 2>/dev/null || true
  docker info --format '{{.ServerVersion}} {{.StorageDriver}} {{.DockerRootDir}}' 2>/dev/null || true
  echo ""
  echo "=== Docker Disk Usage ==="
  docker system df 2>/dev/null || true
  echo ""
  echo "=== CPU ==="
  nproc 2>/dev/null || true
  echo ""
  echo "=== Uptime ==="
  uptime
  echo ""
  echo "=== Network ==="
  ip addr show 2>/dev/null | grep -E '^[0-9]|inet ' | head -20 || true
} > "${BUNDLE_DIR}/system-info.txt"

# --- Create tarball ---
tar czf "$OUTPUT" -C "$TMP_DIR" "neosecra-support-${STAMP}"
rm -r -- "$TMP_DIR"

ok "Support bundle: ${OUTPUT}"
log "Review the bundle before sharing — confirm no secrets are exposed."
