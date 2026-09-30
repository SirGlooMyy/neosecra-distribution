#!/usr/bin/env bash
# NeoSecra Assessment — standalone customer backup (encrypted)
# pg_dump custom format + .env + secrets + upgrade journal, packed as
#   neosecra-backup-<stamp>.tar.gz.age  (+ .sha256)
#
# Security model (P5):
#   * The archive is encrypted with `age` for a PUBLIC recipient; the backup
#     host never holds the private identity. Secrets/.env only exist inside
#     the encrypted archive.
#   * The DB dump is encrypted while streaming (pg_dump | age); a plaintext
#     dump is never written to disk. The staging dir (0700, same filesystem)
#     holds the encrypted dump plus small config copies and is removed on exit.
#   * Everything is written as *.partial and renamed only after success.
#   * umask 077; backup dir 0700; files 0600.
#
# Encryption env (fail-closed; one is required):
#   BACKUP_AGE_RECIPIENT        single age recipient string
#   BACKUP_AGE_RECIPIENTS_FILE  path to a recipients file
#   BACKUP_ALLOW_PLAINTEXT=1    explicit exception when no recipient is set:
#                               UNENCRYPTED backup, loud warning, name contains
#                               .PLAINTEXT
set -Eeuo pipefail
umask 077

# --- Configurables ---
NEOSECRA_HOME="${NEOSECRA_HOME:-/opt/neosecra/assessment}"
BACKUP_BASE="${BACKUP_BASE:-/opt/neosecra/backups}"
BACKUP_RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-14}"
COMPOSE_DIR="${NEOSECRA_HOME}/current/deployment"
COMPOSE_FILE="${COMPOSE_DIR}/docker-compose.v1.yml"
ENV_FILE="${COMPOSE_DIR}/.env.v1"
SECRETS_DIR="${NEOSECRA_SECRETS_DIR:-/opt/neosecra/secrets}"
JOURNAL_DIR="${NEOSECRA_HOME}/upgrade-journal"
COMPOSE_PROJECT="neosecra-assessment"
LOCK_FILE="${NEOSECRA_BACKUP_LOCK:-/tmp/neosecra-backup.lock}"
MIN_DISK_MB="${NEOSECRA_BACKUP_MIN_DISK_MB:-1024}"
BACKUP_AGE_RECIPIENT="${BACKUP_AGE_RECIPIENT:-}"
BACKUP_AGE_RECIPIENTS_FILE="${BACKUP_AGE_RECIPIENTS_FILE:-}"
BACKUP_ALLOW_PLAINTEXT="${BACKUP_ALLOW_PLAINTEXT:-0}"

TEMP_DIR=""
PARTIAL_FILE=""
SHA_PARTIAL=""

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

# --- Cleanup: staging dir, partial files, lock ---
cleanup() {
  [[ -n "${TEMP_DIR:-}" ]] && rm -rf -- "$TEMP_DIR" 2>/dev/null
  [[ -n "${PARTIAL_FILE:-}" ]] && rm -f -- "$PARTIAL_FILE" 2>/dev/null
  [[ -n "${SHA_PARTIAL:-}" ]] && rm -f -- "$SHA_PARTIAL" 2>/dev/null
  release_lock
  return 0
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

# --- Lock ---
LOCK_HELD=0
acquire_lock() {
  if ! mkdir "$LOCK_FILE" 2>/dev/null; then
    die "Another backup is already running (lock: ${LOCK_FILE})" 5
  fi
  LOCK_HELD=1
}
release_lock() { [[ "$LOCK_HELD" -eq 1 ]] && rmdir "$LOCK_FILE" 2>/dev/null; LOCK_HELD=0; return 0; }

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

file_mode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null || echo "?"; }

# stdin -> stdout; fails (status 1) when the stream is empty.
require_nonempty_stream() {
  local hex
  hex="$(dd bs=1 count=1 2>/dev/null | od -An -tx1 | tr -d ' \n')"
  [[ -n "$hex" ]] || return 1
  printf "\\x${hex}"
  cat
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

# --- Encryption mode (decided before anything is created) ---
AGE_ARGS=()
ENCRYPT=0
setup_encryption() {
  if [[ -n "$BACKUP_AGE_RECIPIENT" ]]; then
    AGE_ARGS+=(-r "$BACKUP_AGE_RECIPIENT")
  fi
  if [[ -n "$BACKUP_AGE_RECIPIENTS_FILE" ]]; then
    [[ -f "$BACKUP_AGE_RECIPIENTS_FILE" && -s "$BACKUP_AGE_RECIPIENTS_FILE" ]] \
      || die "BACKUP_AGE_RECIPIENTS_FILE is not a readable, non-empty file: ${BACKUP_AGE_RECIPIENTS_FILE}" 3
    AGE_ARGS+=(-R "$BACKUP_AGE_RECIPIENTS_FILE")
  fi
  if [[ "${#AGE_ARGS[@]}" -gt 0 ]]; then
    ENCRYPT=1
    command -v age >/dev/null 2>&1 \
      || die "age is not installed but a recipient is configured; refusing to write an unencrypted backup (install package 'age')" 3
  elif [[ "$BACKUP_ALLOW_PLAINTEXT" == "1" ]]; then
    ENCRYPT=0
    warn "BACKUP_ALLOW_PLAINTEXT=1 -> this backup is NOT ENCRYPTED. Anyone who can read the file obtains .env, secrets and the database. Configure BACKUP_AGE_RECIPIENT."
  else
    die "No age recipient configured (set BACKUP_AGE_RECIPIENT or BACKUP_AGE_RECIPIENTS_FILE); refusing to create a backup. Explicit exception: BACKUP_ALLOW_PLAINTEXT=1" 3
  fi
}

# Encrypt stdin -> stdout (identity when ENCRYPT=0)
encrypt_stream() {
  if [[ "$ENCRYPT" -eq 1 ]]; then age "${AGE_ARGS[@]}"; else cat; fi
}

harden_backup_base() {
  local mode
  if [[ -d "$BACKUP_BASE" ]]; then
    mode="$(file_mode "$BACKUP_BASE")"
    [[ "$mode" == "700" ]] || warn "Backup directory ${BACKUP_BASE} had mode ${mode}; tightening to 0700"
  else
    mkdir -p "$BACKUP_BASE"
  fi
  chmod 0700 "$BACKUP_BASE"
  local loose=0 f m
  while IFS= read -r -d '' f; do
    m="$(file_mode "$f")"
    if [[ "$m" != "600" ]]; then chmod 0600 "$f" && loose=$((loose + 1)); fi
  done < <(find "$BACKUP_BASE" -maxdepth 1 -type f -name 'neosecra-backup-*' -print0)
  [[ "$loose" -eq 0 ]] || warn "${loose} existing backup file(s) had loose permissions; tightened to 0600"
}

run_pg_dump() {
  local output="$1"
  local pguser pgdb
  pguser="$(env_value POSTGRES_USER neosecra)"
  pgdb="$(env_value POSTGRES_DB neosecra_assessment)"

  log "pg_dump (custom format, streamed$([[ $ENCRYPT -eq 1 ]] && echo ', age-encrypted')): ${pgdb} as ${pguser}..."
  if ! compose_cmd exec -T postgres pg_dump -Fc -U "$pguser" -d "$pgdb" 2>/dev/null \
      | require_nonempty_stream | encrypt_stream > "$output"; then
    err "pg_dump/encrypt pipeline failed or produced empty output — refusing to create an incomplete backup"
    rm -f -- "$output"
    return 1
  fi
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
  done < <(find "$BACKUP_BASE" -maxdepth 1 \( -name 'neosecra-backup-*.tar.gz.age' -o -name 'neosecra-backup-*.tar.gz' \) -print0 | sort -z)
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
  log "Retention: $((total - removed)) backup(s) retained"
  # abandoned partial files of crashed runs
  find "$BACKUP_BASE" -maxdepth 1 -name 'neosecra-backup-*.partial' -type f -mtime +0 -delete 2>/dev/null || true
}

# --- Main ---
STAMP=$(date -u +%Y%m%d-%H%M%S)
VERSION="unknown"
if [[ -f "${COMPOSE_DIR}/VERSION" ]]; then
  VERSION=$(tr -d '[:space:]' < "${COMPOSE_DIR}/VERSION")
fi

if [[ "${BACKUP_ALLOW_PLAINTEXT}" == "1" && -z "$BACKUP_AGE_RECIPIENT" && -z "$BACKUP_AGE_RECIPIENTS_FILE" ]]; then
  BACKUP_FILE="${BACKUP_BASE}/neosecra-backup-${STAMP}.PLAINTEXT.tar.gz"
else
  BACKUP_FILE="${BACKUP_BASE}/neosecra-backup-${STAMP}.tar.gz.age"
fi
SHA256_FILE="${BACKUP_FILE}.sha256"

require_cmd docker
require_cmd sha256sum
require_cmd tar
require_cmd gzip
setup_encryption
harden_backup_base
acquire_lock
check_disk_space

# Staging dir: same filesystem as the backups, 0700, removed by the EXIT trap.
TEMP_DIR="$(mktemp -d "${BACKUP_BASE}/.staging.XXXXXX")"
chmod 0700 "$TEMP_DIR"

# --- Database dump (encrypted while streaming; never plaintext on disk) ---
if [[ "$ENCRYPT" -eq 1 ]]; then
  DUMP_FILE="${TEMP_DIR}/neosecra-db-${STAMP}.dump.age"
else
  DUMP_FILE="${TEMP_DIR}/neosecra-db-${STAMP}.dump"
fi
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
  echo "encrypted: $([[ $ENCRYPT -eq 1 ]] && echo age || echo NO)"
  echo "files:"
  find "${TEMP_DIR}" -mindepth 1 -maxdepth 1 -printf '%f\0' 2>/dev/null | while IFS= read -r -d '' entry; do
    [[ -f "${TEMP_DIR}/${entry}" ]] || continue
    printf "  %s (%s)\n" "$entry" "$(sha256sum "${TEMP_DIR}/${entry}" | cut -d' ' -f1)"
  done
} > "${TEMP_DIR}/BACKUP-MANIFEST"
ok "BACKUP-MANIFEST written"

# --- Package: tar | gzip | age -> .partial -> rename ---
PARTIAL_FILE="${BACKUP_FILE}.partial"
: > "$PARTIAL_FILE"
chmod 0600 "$PARTIAL_FILE"
if ! tar -cf - -C "$TEMP_DIR" . | gzip -c | encrypt_stream > "$PARTIAL_FILE"; then
  die "Archive pipeline (tar/gzip/age) failed — partial backup removed" 12
fi
[[ -s "$PARTIAL_FILE" ]] || die "Archive is empty — partial backup removed" 12

# --- SHA256 of the (encrypted) artifact, standard "hash  name" format ---
SHA_PARTIAL="${SHA256_FILE}.partial"
printf '%s  %s\n' "$(sha256sum "$PARTIAL_FILE" | cut -d' ' -f1)" "$(basename "$BACKUP_FILE")" > "$SHA_PARTIAL"
chmod 0600 "$SHA_PARTIAL"
mv -f "$PARTIAL_FILE" "$BACKUP_FILE"
mv -f "$SHA_PARTIAL" "$SHA256_FILE"
PARTIAL_FILE=""; SHA_PARTIAL=""
chmod 0600 "$BACKUP_FILE" "$SHA256_FILE"
ok "Archive: ${BACKUP_FILE} ($(du -h "$BACKUP_FILE" | cut -f1))"
ok "SHA256: ${SHA256_FILE}"

# --- Retention ---
retention_cleanup "$BACKUP_RETENTION_DAYS" 1

ok "Backup complete: ${STAMP}"
