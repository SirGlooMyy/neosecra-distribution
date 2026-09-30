#!/usr/bin/env bash
# NeoSecra Assessment — standalone customer restore
# Verifies (sha256 + age decrypt), and ONLY with --confirm: stops services,
# pre-restore safety dump, pg_restore, alembic, start, smoke.
#
# DEFAULT = VERIFY ONLY. Nothing is written to the database/services unless
# --confirm is given. The backup is streamed (decrypted in memory / pipes);
# no plaintext dump or secret file is extracted to disk.
set -Eeuo pipefail
umask 077

# --- Configurables ---
NEOSECRA_HOME="${NEOSECRA_HOME:-/opt/neosecra/assessment}"
BACKUP_BASE="${BACKUP_BASE:-/opt/neosecra/backups}"
COMPOSE_DIR="${NEOSECRA_HOME}/current/deployment"
COMPOSE_FILE="${COMPOSE_DIR}/docker-compose.v1.yml"
ENV_FILE="${COMPOSE_DIR}/.env.v1"
COMPOSE_PROJECT="neosecra-assessment"

SAFETY_DIR=""
cleanup() {
  local rc=$?
  [[ -z "${SAFETY_DIR:-}" ]] || rm -rf -- "$SAFETY_DIR"
  exit "$rc"
}
trap cleanup EXIT

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
Usage: $(basename "$0") <backup-file> [--confirm] [--yes] [--legacy-plaintext]

Restore a NeoSecra Assessment backup (age-encrypted tar.gz.age with .sha256).
Default is VERIFY ONLY: sha256 + full decrypt check, no changes anywhere.

  --confirm            actually restore (asks y/N unless --yes)
  --yes                skip the interactive prompt (only meaningful with --confirm)
  --legacy-plaintext   backup is an old/unencrypted tar.gz (or *.PLAINTEXT.tar.gz)

Env: BACKUP_AGE_IDENTITY_FILE = age private identity file (mode 0600),
     required for encrypted backups. Keep it off the backup host.

Steps: sha256 verify -> decrypt verify -> [--confirm] stop services
       -> pre-restore dump -> pg_restore -> alembic check -> start -> /health
EOF
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
  local prompt="$1" reply=""
  echo -n "${prompt} [y/N] " >&2
  read -r reply || true
  case "$reply" in
    y|Y|yes|YES) return 0 ;;
    *) die "Restore cancelled by user" 1 ;;
  esac
}

identity_mode_ok() {
  local f="$1" mode probe pm
  mode="$(stat -c '%a' "$f" 2>/dev/null || stat -f '%Lp' "$f" 2>/dev/null || echo "")"
  [[ -n "$mode" ]] || return 1
  if [[ $(( 8#$mode & 8#077 )) -eq 0 ]]; then return 0; fi
  # Loose bits: reject, unless this filesystem cannot represent modes at all.
  probe="$(mktemp "$(dirname "$f")/.permprobe.XXXXXX" 2>/dev/null)" || return 1
  chmod 0600 "$probe" 2>/dev/null || true
  pm="$(stat -c '%a' "$probe" 2>/dev/null || echo "")"
  rm -f -- "$probe"
  if [[ "$pm" != "600" ]]; then
    warn "Filesystem does not enforce POSIX modes; identity file permissions cannot be verified"
    return 0
  fi
  return 1
}

# --- Args ---
BACKUP_FILE=""
YES=0
CONFIRM=0
LEGACY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h)          usage; exit 0 ;;
    --yes)              YES=1 ;;
    --confirm)          CONFIRM=1 ;;
    --legacy-plaintext) LEGACY=1 ;;
    -*)                 die "Unknown option: $1" 2 ;;
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

require_cmd sha256sum
require_cmd tar
require_cmd gzip

case "$BACKUP_FILE" in
  *.age) ENCRYPTED=1 ;;
  *)     ENCRYPTED=0 ;;
esac
if [[ "$ENCRYPTED" -eq 1 && "$LEGACY" -eq 1 ]]; then
  die "--legacy-plaintext given but the file is age-encrypted (.age)" 2
fi
if [[ "$ENCRYPTED" -eq 0 && "$LEGACY" -ne 1 ]]; then
  die "Backup is not age-encrypted (.age). Plaintext/old-format backups need the explicit --legacy-plaintext flag" 2
fi

# --- SHA256 verify (before any decryption) ---
SHA256_FILE="${BACKUP_FILE}.sha256"
if [[ -f "$SHA256_FILE" ]]; then
  log "Verifying SHA256..."
  expected=$(awk 'NR==1{print $1}' "$SHA256_FILE" | tr -d '[:space:]')
  actual=$(sha256sum "$BACKUP_FILE" | cut -d' ' -f1)
  if [[ -z "$expected" || "$expected" != "$actual" ]]; then
    die "SHA256 MISMATCH: expected ${expected:-<empty>}, got ${actual} — nothing was restored" 4
  fi
  ok "SHA256 verified"
else
  die "SHA256 file not found: ${SHA256_FILE}" 4
fi

# --- Decrypt prerequisites ---
if [[ "$ENCRYPTED" -eq 1 ]]; then
  require_cmd age
  [[ -n "${BACKUP_AGE_IDENTITY_FILE:-}" ]] || die "BACKUP_AGE_IDENTITY_FILE is not set" 3
  [[ -f "$BACKUP_AGE_IDENTITY_FILE" ]] || die "Identity file not found: ${BACKUP_AGE_IDENTITY_FILE}" 3
  identity_mode_ok "$BACKUP_AGE_IDENTITY_FILE" \
    || die "Identity file ${BACKUP_AGE_IDENTITY_FILE} must be mode 0600 (chmod 600); refusing" 3
fi

# Archive (tar.gz) stream -> stdout, decrypted when needed
archive_stream() {
  if [[ "$ENCRYPTED" -eq 1 ]]; then
    age -d -i "$BACKUP_AGE_IDENTITY_FILE" "$BACKUP_FILE"
  else
    cat "$BACKUP_FILE"
  fi
}

# --- Verification pass: list + locate dump + decrypt dump (all into pipes) ---
log "Verifying backup (decrypt + list, nothing written)..."
if ! LISTING="$( set -o pipefail; archive_stream | tar -tzf - )"; then
  die "Archive decrypt/read failed (wrong identity or corrupt backup) — nothing was restored" 4
fi
log "Backup contents:"
printf '%s\n' "$LISTING" | sort | sed -n '1,30p'

DUMP_ENTRY=$(printf '%s\n' "$LISTING" | grep -E '(^|/)neosecra-db-[0-9-]+\.dump(\.age)?$' | head -1 || true)
[[ -n "$DUMP_ENTRY" ]] || die "No database dump found in backup archive — nothing was restored" 4

dump_stream() {
  if [[ "$DUMP_ENTRY" == *.age ]]; then
    archive_stream | tar -xzOf - "$DUMP_ENTRY" | age -d -i "$BACKUP_AGE_IDENTITY_FILE"
  else
    archive_stream | tar -xzOf - "$DUMP_ENTRY"
  fi
}
if [[ "$DUMP_ENTRY" == *.age && -z "${BACKUP_AGE_IDENTITY_FILE:-}" ]]; then
  die "Inner dump is age-encrypted; BACKUP_AGE_IDENTITY_FILE is required" 3
fi
if ! DUMP_BYTES="$( set -o pipefail; dump_stream | wc -c )"; then
  die "Database dump decrypt/extract failed — nothing was restored" 4
fi
[[ "${DUMP_BYTES:-0}" -gt 0 ]] || die "Database dump is empty — nothing was restored" 4
ok "Backup verified (dump: ${DUMP_BYTES} bytes)"

if [[ "$CONFIRM" -ne 1 ]]; then
  ok "Verify-only mode: NO service or database was touched."
  log "To restore, re-run with --confirm (add --yes for non-interactive)."
  exit 0
fi

# --- From here on: writes. Everything needed is verified. ---
require_cmd docker
require_cmd curl

# --- Confirmation ---
[[ "$YES" -eq 1 ]] || confirm_or_die "This will OVERWRITE the live database. Continue?"

# --- Pre-restore safety dump ---
SAFETY_STAMP=$(date -u +%Y%m%d-%H%M%S)
mkdir -p "$BACKUP_BASE"
SAFETY_DIR=$(mktemp -d "${BACKUP_BASE}/.restore-safety.XXXXXX")
chmod 0700 "$SAFETY_DIR"
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

# --- pg_restore (streamed into the container; no plaintext file on disk) ---
log "Restoring database from backup..."
if ! dump_stream | compose_cmd exec -T postgres pg_restore -Fc -U "$pguser" -d "$pgdb" --clean --if-exists 2>&1 | redact; then
  die "pg_restore failed" 3
fi
ok "Database restore complete"

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
