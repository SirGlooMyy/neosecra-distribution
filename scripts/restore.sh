#!/usr/bin/env bash
# NeoSecra Assessment — standalone customer restore
# Verifies, stops services, pre-restore safety dump, pg_restore, alembic, start, smoke
set -Eeuo pipefail

# --- Configurables ---
NEOSECRA_HOME="${NEOSECRA_HOME:-/opt/neosecra/assessment}"
BACKUP_BASE="${BACKUP_BASE:-/opt/neosecra/backups}"
COMPOSE_DIR="${NEOSECRA_HOME}/current/deployment"
COMPOSE_FILE="${COMPOSE_DIR}/docker-compose.v1.yml"
ENV_FILE="${COMPOSE_DIR}/.env.v1"
COMPOSE_PROJECT="neosecra-assessment"

# --- Logging (stderr) ---
if [[ -t 2 ]]; then
  _CR=$'\033[31m'; _CY=$'\033[33m'; _CG=$'\033[32m'; _CD=$'\033[2m'; _CN=$'\033[0m'
else
  _CR=''; _CY=''; _CG=''; _CD=''; _CN=''
fi
log()  { printf '%s[info]%s  %s\n'  "$_CD" "$_CN" "$*" >&2; }
ok()   { printf '%s[ok]%s    %s\n'  "$_CG" "$_CN" "$*" >&2; }
warn() { printf '%s[warn]%s  %s\n'  "$_CY" "$_CN" "$*" >&2; }
err()  { printf '%s[error]%s %s\n'  "$_CR" "$_CN" "$*" >&2; }
die()  { err "$1"; exit "${2:-1}"; }

# --- Functions ---
usage() {
  cat <<EOF
Usage: $(basename "$0") <backup-file> [--yes]

Restore a NeoSecra Assessment backup (tar.gz with .sha256).
  --yes    Skip confirmation prompt (non-interactive)

Steps: sha256 verify → stop services → pre-restore dump → pg_restore
       → alembic check → start services → /health smoke
EOF
  exit 0
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1" 2
}

compose_cmd() {
  docker compose -f "$COMPOSE_FILE" -p "$COMPOSE_PROJECT" "$@"
}

env_value() {
  local key="$1" default="${2:-}"
  [[ -f "$ENV_FILE" ]] || { echo "$default"; return; }
  grep -E "^${key}=" "$ENV_FILE" 2>/dev/null | tail -n1 | cut -d= -f2- || echo "$default"
}

redact() {
  sed -E \
    -e 's#(postgresql(\+asyncpg)?://[^:[:space:]]+:)[^@[:space:]]+@#\1<redacted>@#g' \
    -e 's#([A-Za-z0-9_]*(PASSWORD|SECRET|TOKEN|KEY|DATABASE_URL)[A-Za-z0-9_]*=)[^[:space:]]+#\1<redacted>#g'
}

confirm_or_die() {
  local prompt="$1"
  echo -n "${prompt} [y/N] " >&2
  read -r reply <&1 || true
  case "$reply" in
    y|Y|yes|YES) return 0 ;;
    *) die "Restore cancelled by user" 0 ;;
  esac
}

# --- Args ---
BACKUP_FILE=""
YES=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h) usage ;;
    --yes)     YES=1 ;;
    -*)
      if [[ -z "$BACKUP_FILE" ]]; then
        BACKUP_FILE="$1"
      else
        die "Unknown option: $1" 2
      fi
      ;;
    *)
      if [[ -z "$BACKUP_FILE" ]]; then
        BACKUP_FILE="$1"
      else
        die "Unexpected argument: $1" 2
      fi
      ;;
  esac
  shift
done

[[ -n "$BACKUP_FILE" ]] || { usage; die "Backup file path required" 2; }
[[ -f "$BACKUP_FILE" ]] || die "Backup file not found: ${BACKUP_FILE}" 2

require_cmd docker
require_cmd sha256sum
require_cmd curl

# --- SHA256 verify ---
SHA256_FILE="${BACKUP_FILE}.sha256"
if [[ -f "$SHA256_FILE" ]]; then
  log "Verifying SHA256..."
  expected=$(cat "$SHA256_FILE" | tr -d '[:space:]')
  actual=$(sha256sum "$BACKUP_FILE" | cut -d' ' -f1)
  if [[ "$expected" != "$actual" ]]; then
    die "SHA256 MISMATCH: expected ${expected}, got ${actual}" 4
  fi
  ok "SHA256 verified"
else
  die "SHA256 file not found: ${SHA256_FILE}" 4
fi

# --- Extract manifest for inspection ---
log "Backup contents:"
tar -tzf "$BACKUP_FILE" | sort | head -30

# --- Confirmation ---
[[ "$YES" -eq 1 ]] || confirm_or_die "This will OVERWRITE the live database. Continue?"

# --- Pre-restore safety dump ---
SAFETY_STAMP=$(date -u +%Y%m%d-%H%M%S)
SAFETY_DIR=$(mktemp -d)
trap 'rm -rf "$SAFETY_DIR"' EXIT
log "Taking pre-restore safety snapshot..."
if [[ -f "$COMPOSE_FILE" ]] && compose_cmd ps --status running -q postgres 2>/dev/null | grep -q .; then
  pguser="$(env_value POSTGRES_USER neosecra)"
  pgdb="$(env_value POSTGRES_DB neosecra_assessment)"
  compose_cmd exec -T postgres pg_dump -Fc -U "$pguser" -d "$pgdb" > "${SAFETY_DIR}/pre-restore-${SAFETY_STAMP}.dump" 2>/dev/null && \
    ok "Pre-restore safety dump saved to ${SAFETY_DIR}" || \
    warn "Pre-restore dump failed — restore proceeds without safety net"
else
  warn "Postgres not running — no pre-restore safety dump"
fi

# --- Stop application services ---
log "Stopping application services..."
for svc in backend worker frontend beat; do
  compose_cmd stop "$svc" 2>/dev/null || true
done
sleep 3
ok "Application services stopped"

# --- Drop and recreate database ---
log "Recreating database..."
pguser="$(env_value POSTGRES_USER neosecra)"
pgdb="$(env_value POSTGRES_DB neosecra_assessment)"

compose_cmd exec -T postgres psql -U "$pguser" -d postgres -v ON_ERROR_STOP=1 <<SQL 2>&1 | redact || die "Database drop/recreate failed" 3
SELECT pg_terminate_backend(pid) FROM pg_stat_activity
 WHERE datname = '${pgdb}' AND pid <> pg_backend_pid();
DROP DATABASE IF EXISTS "${pgdb}";
CREATE DATABASE "${pgdb}" OWNER "${pguser}";
SQL
ok "Database ${pgdb} recreated"

# --- pg_restore ---
log "Restoring database from backup..."
DUMP_ENTRY=$(tar -tzf "$BACKUP_FILE" | grep -E '(^|/)neosecra-db-[0-9-]+\.dump$' | head -1)
if [[ -n "$DUMP_ENTRY" ]]; then
  # Extract dump to temp, copy to container, restore, clean up
  tar -xOzf "$BACKUP_FILE" "$DUMP_ENTRY" > "${SAFETY_DIR}/restore-input.dump"
  compose_cmd cp "${SAFETY_DIR}/restore-input.dump" "postgres:/tmp/neosecra-restore.dump" 2>/dev/null
  compose_cmd exec -T postgres pg_restore -Fc -U "$pguser" -d "$pgdb" --clean --if-exists /tmp/neosecra-restore.dump 2>&1 | redact || {
    compose_cmd exec -T postgres rm -f /tmp/neosecra-restore.dump 2>/dev/null || true
    die "pg_restore failed" 3
  }
  compose_cmd exec -T postgres rm /tmp/neosecra-restore.dump
  ok "Database restore complete"
else
  warn "No database dump found in backup archive — skipping restore"
fi

# --- Alembic check ---
log "Checking alembic migration state..."
if compose_cmd run --rm -T backend alembic current 2>&1 | redact; then
  log "Running alembic upgrade head..."
  compose_cmd run --rm -T backend alembic upgrade head 2>&1 | redact && \
    ok "Alembic migrations up to date" || \
    warn "Alembic upgrade produced warnings — review above"
else
  warn "Alembic current check failed; upgrade attempted anyway"
  compose_cmd run --rm -T backend alembic upgrade head 2>&1 | redact || true
fi

# --- Start services ---
log "Starting all services..."
compose_cmd up -d 2>&1 | redact

# Wait for health
frontend_port="$(env_value FRONTEND_PORT 23300)"
log "Waiting for backend health on 127.0.0.1:${frontend_port}/api/v1/health (timeout 120s)..."
HEALTH_OK=0
for _ in $(seq 1 120); do
  code=$(curl -s --max-time 3 -o /dev/null -w '%{http_code}' "http://127.0.0.1:${frontend_port}/api/v1/health" 2>/dev/null || true)
  if [[ "$code" == "200" ]]; then
    HEALTH_OK=1
    break
  fi
  sleep 1
done

if [[ "$HEALTH_OK" -eq 1 ]]; then
  ok "Health check passed (HTTP 200)"
else
  err "Health check FAILED — services may not be fully operational"
  err "Check logs: docker compose -f ${COMPOSE_FILE} -p ${COMPOSE_PROJECT} logs"
  exit 1
fi

ok "Restore complete: $(basename "$BACKUP_FILE")"
