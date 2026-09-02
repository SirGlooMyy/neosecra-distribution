#!/usr/bin/env bash
# NeoSecra Assessment — standalone customer backup
# pg_dump custom format + .env + secrets + upgrade journal
set -Eeuo pipefail

# --- Configurables ---
NEOSECRA_HOME="${NEOSECRA_HOME:-/opt/neosecra/assessment}"
BACKUP_BASE="${BACKUP_BASE:-/opt/neosecra/backups}"
BACKUP_RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-14}"
COMPOSE_DIR="${NEOSECRA_HOME}/current/deployment"
COMPOSE_FILE="${COMPOSE_DIR}/docker-compose.v1.yml"
ENV_FILE="${COMPOSE_DIR}/.env.v1"
SECRETS_DIR="/opt/neosecra/secrets"
JOURNAL_DIR="${NEOSECRA_HOME}/upgrade-journal"
COMPOSE_PROJECT="neosecra-assessment"
LOCK_FILE="/tmp/neosecra-backup.lock"
MIN_DISK_MB=1024

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

# --- Lock ---
acquire_lock() {
  if ! mkdir "$LOCK_FILE" 2>/dev/null; then
    die "Another backup is already running (lock: ${LOCK_FILE})" 5
  fi
  trap cleanup EXIT
}
release_lock() { rmdir "$LOCK_FILE" 2>/dev/null || true; }
cleanup() { rm -rf "${TEMP_DIR:-}" 2>/dev/null || true; release_lock; }

# --- Prerequisites ---
check_disk_space() {
  local min_mb="${1:-$MIN_DISK_MB}" avail
  avail=$(df -m "$BACKUP_BASE" 2>/dev/null | awk 'NR==2{print $4}')
  if [[ -z "$avail" || "$avail" -lt "$min_mb" ]]; then
    die "Insufficient disk space in ${BACKUP_BASE}: ${avail:-?}MB available, need ${min_mb}MB" 6
  fi
  log "Disk: ${avail}MB free in ${BACKUP_BASE}"
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

postgres_is_running() {
  [[ -f "$COMPOSE_FILE" ]] || return 1
  compose_cmd ps --status running -q postgres 2>/dev/null | grep -q .
}

run_pg_dump() {
  local output="$1"
  local pguser pgdb
  pguser="$(env_value POSTGRES_USER neosecra)"
  pgdb="$(env_value POSTGRES_DB neosecra_assessment)"

  log "pg_dump (custom format): ${pgdb} as ${pguser}..."
  compose_cmd exec -T postgres pg_dump -Fc -U "$pguser" -d "$pgdb" > "$output" 2>/dev/null || {
    err "pg_dump failed — refusing to create an incomplete backup"
    return 1
  }
  if [[ ! -s "$output" ]]; then
    err "pg_dump produced empty file — refusing to create an incomplete backup"
    return 1
  fi
  ok "pg_dump: $(du -h "$output" | cut -f1)"
}

retention_cleanup() {
  local keep_days="$1" min_keep="${2:-1}"
  local backups=()
  while IFS= read -r -d '' f; do
    backups+=("$f")
  done < <(find "$BACKUP_BASE" -maxdepth 1 -name 'neosecra-backup-*.tar.gz' -print0 | sort -z)
  local total="${#backups[@]}"
  [[ "$total" -eq 0 ]] && return 0

  local now; now=$(date +%s)
  local cutoff=$((keep_days * 86400))
  local removed=0

  for ((i=0; i<total; i++)); do
    local remaining=$((total - removed))
    [[ "$remaining" -le "$min_keep" ]] && break
    local age
    age=$(stat -c%Y "${backups[$i]}" 2>/dev/null || echo 0)
    if [[ $((now - age)) -ge $cutoff ]]; then
      rm -f "${backups[$i]}" "${backups[$i]}.sha256" 2>/dev/null
      ok "Retention: removed $(basename "${backups[$i]}")"
      removed=$((removed + 1))
    fi
  done
  log "Retention: ${remaining} backup(s) retained"
}

# --- Main ---
STAMP=$(date -u +%Y%m%d-%H%M%S)
VERSION="unknown"
if [[ -f "${COMPOSE_DIR}/VERSION" ]]; then
  VERSION=$(tr -d '[:space:]' < "${COMPOSE_DIR}/VERSION")
fi

BACKUP_FILE="${BACKUP_BASE}/neosecra-backup-${STAMP}.tar.gz"
SHA256_FILE="${BACKUP_FILE}.sha256"

require_cmd docker
require_cmd sha256sum
mkdir -p "$BACKUP_BASE"
acquire_lock
check_disk_space

TEMP_DIR=$(mktemp -d)

# --- Database dump ---
DUMP_FILE="${TEMP_DIR}/neosecra-db-${STAMP}.dump"
if postgres_is_running; then
  run_pg_dump "$DUMP_FILE" || die "Database backup failed" 12
else
  die "Postgres not running — database dump is required" 12
fi

# --- Application env snapshot ---
if [[ -f "$ENV_FILE" ]]; then
  cp "$ENV_FILE" "${TEMP_DIR}/env.v1"
  ok "env.v1 copied"
else
  die ".env.v1 not found at ${ENV_FILE} — refusing incomplete backup" 12
fi

# --- Secrets ---
if [[ -d "$SECRETS_DIR" ]] && ls -A "$SECRETS_DIR" &>/dev/null; then
  cp -a "$SECRETS_DIR" "${TEMP_DIR}/secrets"
  ok "Secrets copied from ${SECRETS_DIR}"
else
  die "No secrets directory at ${SECRETS_DIR} — refusing incomplete backup" 12
fi

# --- Upgrade journal ---
if [[ -d "$JOURNAL_DIR" ]] && ls -A "$JOURNAL_DIR" &>/dev/null; then
  mkdir -p "${TEMP_DIR}/upgrade-journal"
  cp -a "$JOURNAL_DIR"/. "${TEMP_DIR}/upgrade-journal/"
  ok "Upgrade journal copied"
else
  die "No upgrade journal at ${JOURNAL_DIR} — refusing incomplete backup" 12
fi

# --- Version ---
echo "$VERSION" > "${TEMP_DIR}/VERSION.txt"

# --- Manifest ---
{
  echo "# NeoSecra Assessment backup"
  echo "stamp: ${STAMP}"
  echo "created_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "version: ${VERSION}"
  echo "files:"
  find "${TEMP_DIR}" -mindepth 1 -maxdepth 1 -printf '%f\0' 2>/dev/null | while IFS= read -r -d '' entry; do
    [[ -f "${TEMP_DIR}/${entry}" ]] || continue
    printf "  %s (%s)\n" "$entry" "$(sha256sum "${TEMP_DIR}/${entry}" | cut -d' ' -f1)"
  done
} > "${TEMP_DIR}/BACKUP-MANIFEST"
ok "BACKUP-MANIFEST written"

# --- Package ---
tar -czf "$BACKUP_FILE" -C "$TEMP_DIR" .
ok "Archive: ${BACKUP_FILE} ($(du -h "$BACKUP_FILE" | cut -f1))"

# --- SHA256 ---
sha256sum "$BACKUP_FILE" | awk '{print $1}' > "$SHA256_FILE"
ok "SHA256: ${SHA256_FILE}"

# --- Retention ---
retention_cleanup "$BACKUP_RETENTION_DAYS" 1

ok "Backup complete: ${STAMP}"
