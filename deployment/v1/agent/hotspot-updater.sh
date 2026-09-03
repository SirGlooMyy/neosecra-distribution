#!/usr/bin/env bash
# Host-side updater for the NeoSecra Hotspot Compose distribution.
#
# The distribution update-agent verifies the channel/archive signature before
# invoking this script. This script owns the Hotspot-specific transaction:
# migration-gated database checkpoint, staged Compose build/migration, health
# gate, atomic current symlink switch, and rollback on failure.
set -Eeuo pipefail

AGENT_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SECURE_EXTRACT="${NEOSECRA_SECURE_EXTRACT:-${AGENT_SCRIPT_DIR}/../upgrade/secure_extract.py}"
ROLLBACK_VERIFIER="${NEOSECRA_ROLLBACK_VERIFIER:-${AGENT_SCRIPT_DIR}/../upgrade/verify_rollback_auth.py}"

TARGET=""
ARCHIVE=""
ARCHIVE_SHA256=""
ARCHIVE_SIGNATURE=""
SIGNATURE_PUBKEY=""
ROLLBACK_AUTH=""
ROLLBACK=0
BACKUP_SOURCE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --target) shift; TARGET="${1:-}" ;;
    --archive) shift; ARCHIVE="${1:-}" ;;
    --archive-sha256) shift; ARCHIVE_SHA256="${1:-}" ;;
    --archive-signature) shift; ARCHIVE_SIGNATURE="${1:-}" ;;
    --signature-pubkey) shift; SIGNATURE_PUBKEY="${1:-}" ;;
    --rollback-auth|--auth) shift; ROLLBACK_AUTH="${1:-}" ;;
    --backup) shift; BACKUP_SOURCE="${1:-}" ;;
    --rollback) ROLLBACK=1 ;;
    --help|-h)
      cat <<'EOF'
Usage: hotspot-updater.sh --target <semver> --archive <tar.gz> \
       --archive-sha256 <sha256> --archive-signature <minisig> \
       --signature-pubkey <pubkey> [--rollback-auth <auth.json>]
       hotspot-updater.sh --rollback --target <semver> --auth <auth.json> [--backup <dir>]
EOF
      exit 0
      ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

[[ "$TARGET" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Invalid target version" >&2; exit 2; }

ROOT="${NEOSECRA_INSTALL_ROOT:-/opt/neosecra/hotspot}"
[[ "${ROOT}" = /* && "${ROOT}" != / && "${ROOT}" != *$'\n'* && "${ROOT}" != *$'\r'* ]] || { echo "Unsafe Hotspot root" >&2; exit 2; }
CURRENT_LINK="${ROOT}/current"
RELEASES_DIR="${ROOT}/releases"
STATE_DIR="${ROOT}/state"
BACKUPS_DIR="${ROOT}/backups"
JOURNAL_DIR="${ROOT}/upgrade-journal"
COMPOSE_PROJECT="${NEOSECRA_COMPOSE_PROJECT:-neosecra-hotspot}"
API_PORT="${HOTSPOT_API_PORT:-38001}"
STAGING=""

mkdir -p "$RELEASES_DIR" "$STATE_DIR" "$BACKUPS_DIR" "$JOURNAL_DIR"
LOCK_DIR="${STATE_DIR}/.hotspot-upgrade.lock"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  echo "Another Hotspot update is already running" >&2
  exit 5
fi
cleanup() {
  if [[ -d "${LOCK_DIR}" ]] && ! rmdir "${LOCK_DIR}" 2>/dev/null; then
    printf '%s\n' "Warning: failed to remove Hotspot update lock ${LOCK_DIR}" >&2
  fi
}
trap cleanup EXIT

fsync_dir() {
  python3 - "$(dirname "$1")" <<'PY'
import os
import sys
fd = os.open(sys.argv[1], os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
try:
    os.fsync(fd)
finally:
    os.close(fd)
PY
}

atomic_replace() {
  local source="$1" destination="$2"
  python3 - "$source" "$destination" <<'PY'
import os
import sys
source, destination = sys.argv[1:]
with open(source, "rb") as stream:
    os.fsync(stream.fileno())
os.replace(source, destination)
fd = os.open(os.path.dirname(destination), os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
try:
    os.fsync(fd)
finally:
    os.close(fd)
PY
}

atomic_write_text() {
  local destination="$1" content="$2" mode="${3:-600}" tmp
  tmp="$(mktemp "${destination}.tmp.XXXXXX")"
  if ! printf '%s\n' "${content}" > "${tmp}"; then
    rm -f -- "${tmp}"
    return 1
  fi
  chmod "${mode}" "${tmp}"
  if ! atomic_replace "${tmp}" "${destination}"; then
    rm -f -- "${tmp}"
    return 1
  fi
}

current_tree() {
  [[ -L "${CURRENT_LINK}" ]] || return 1
  local resolved
  resolved="$(readlink -f "${CURRENT_LINK}")"
  case "${resolved}" in
    "${RELEASES_DIR}"/*) ;;
    *) return 1 ;;
  esac
  [[ -d "${resolved}" && ! -L "${resolved}" ]] || return 1
  printf '%s\n' "${resolved}"
}

current_version() {
  local value=""
  if [[ -f "${STATE_DIR}/installed-version" && ! -L "${STATE_DIR}/installed-version" ]]; then
    value="$(tr -d '[:space:]' < "${STATE_DIR}/installed-version")"
  elif [[ -f "${CURRENT_LINK}/VERSION" && ! -L "${CURRENT_LINK}/VERSION" ]]; then
    value="$(tr -d '[:space:]' < "${CURRENT_LINK}/VERSION")"
  fi
  [[ "${value}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Invalid installed Hotspot version" >&2; return 1; }
  printf '%s\n' "${value}"
}

env_value() {
  local file="$1" key="$2" value
  [[ -f "$file" && ! -L "$file" ]] || return 1
  value="$(awk -F= -v k="$key" '$1 == k {sub(/^[^=]*=/, ""); sub(/\r$/, ""); print; exit}' "$file")"
  printf '%s' "${value}"
}

database_password_from_env() {
  local env_file="$1"
  [[ -f "${env_file}" && ! -L "${env_file}" ]] || return 1
  python3 - "${env_file}" <<'PY'
import re
import sys
from pathlib import Path
from urllib.parse import unquote, urlsplit

path = Path(sys.argv[1])
for line in path.read_text(encoding="utf-8").splitlines():
    raw = line.strip()
    if not raw or raw.startswith("#"):
        continue
    key, separator, value = line.partition("=")
    if separator != "=" or key.strip() != "DATABASE_URL":
        continue
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "'\"":
        value = value[1:-1]
    value = re.sub(r"^postgres(?:ql)?\+[^:/@]+://", "postgresql://", value, count=1)
    try:
        password = urlsplit(value).password
    except ValueError:
        password = None
    if password:
        sys.stdout.write(unquote(password))
        raise SystemExit(0)
raise SystemExit(1)
PY
}

set_env_value() {
  local file="$1" key="$2" value="$3"
  [[ -f "${file}" && ! -L "${file}" ]] || return 1
  python3 - "${file}" "${key}" "${value}" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
key = sys.argv[2]
value = sys.argv[3]
lines = path.read_text(encoding="utf-8").splitlines()
replacement = f"{key}={value}"
updated = False
for index, line in enumerate(lines):
    stripped = line.lstrip()
    if stripped.startswith("#"):
        continue
    candidate, separator, _ = line.partition("=")
    if separator == "=" and candidate.strip() == key:
        lines[index] = replacement
        updated = True
        break
if not updated:
    lines.append(replacement)
path.write_text("\n".join(lines) + "\n", encoding="utf-8")
PY
}

migration_signature() {
  local tree="$1"
  python3 - "${tree}/backend/alembic/versions" <<'PY'
import hashlib
import sys
from pathlib import Path

root = Path(sys.argv[1])
digest = hashlib.sha256()
if root.is_dir():
    for path in sorted(root.glob("*.py")):
        if not path.is_file() or path.is_symlink():
            continue
        digest.update(path.name.encode("utf-8"))
        digest.update(b"\0")
        digest.update(path.read_bytes())
        digest.update(b"\0")
print(digest.hexdigest())
PY
}

migration_required() {
  [[ "$(migration_signature "$1")" != "$(migration_signature "$2")" ]]
}

compose_file() { printf '%s/docker-compose.yml' "$1"; }
compose_env() { printf '%s/backend/.env' "$1"; }
run_compose() {
  local tree="$1" env_file="$2" pg_password
  shift 2
  [[ -f "$(compose_file "$tree")" ]] || { echo "Compose file missing: $(compose_file "$tree")" >&2; return 1; }
  [[ -f "$env_file" ]] || { echo "Hotspot environment missing: $env_file" >&2; return 1; }
  pg_password="$(env_value "$env_file" POSTGRES_PASSWORD || true)"
  pg_password="${pg_password:-${POSTGRES_PASSWORD:-}}"
  if [[ -z "${pg_password}" ]]; then
    pg_password="$(database_password_from_env "$env_file" || true)"
  fi
  [[ -n "${pg_password}" ]] || {
    echo "POSTGRES_PASSWORD is missing and DATABASE_URL has no usable password" >&2
    return 1
  }
  POSTGRES_PASSWORD="${pg_password}" docker compose --project-name "$COMPOSE_PROJECT" --project-directory "$tree" \
    --env-file "$env_file" -f "$(compose_file "$tree")" "$@"
}

wait_api() {
  local i
  for i in $(seq 1 60); do
    # Hotspot exposes its deep service probe at /health (the /api/v1 router
    # intentionally contains only versioned application endpoints).
    if curl -fsS --max-time 25 "http://127.0.0.1:${API_PORT}/health" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  return 1
}

write_journal() {
  local status="$1" from="$2" backup="$3" error="${4:-}" migration="${5:-}" path tmp
  path="${JOURNAL_DIR}/upgrade-${from}-to-${TARGET}-$(date -u +%Y%m%dT%H%M%SZ).json"
  tmp="$(mktemp "${path}.tmp.XXXXXX")"
  python3 - "${tmp}" "${status}" "${from}" "${TARGET}" "${backup}" "${error}" "${migration}" <<'PY'
import json
import os
import sys
from datetime import datetime, timezone
path, status, previous, target, backup, error, migration = sys.argv[1:]
record = {
    "timestamp": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
    "product": "hotspot", "product_code": "hotspot",
    "edition": os.environ.get("NEOSECRA_EDITION_ID", "standard"),
    "previous_version": previous, "target_version": target,
    "status": status, "backup_path": backup, "error": error,
    "migration": migration or None,
}
with open(path, "w", encoding="utf-8") as stream:
    json.dump(record, stream, sort_keys=True, separators=(",", ":"))
    stream.write("\n")
    stream.flush(); os.fsync(stream.fileno())
os.chmod(path, 0o600)
PY
  atomic_replace "${tmp}" "${path}"
}

write_state() { atomic_write_text "${STATE_DIR}/installed-version" "$1" 600; }

atomic_switch_current() {
  local target_tree="$1" tmp="${CURRENT_LINK}.new.$$"
  [[ -d "${target_tree}" && ! -L "${target_tree}" ]] || return 1
  rm -f -- "${tmp}"
  ln -s "${target_tree}" "${tmp}"
  mv -Tf -- "${tmp}" "${CURRENT_LINK}"
  fsync_dir "${CURRENT_LINK}"
}

verify_archive() {
  [[ -f "${ARCHIVE}" && ! -L "${ARCHIVE}" && -s "${ARCHIVE}" ]] || { echo "Signed Hotspot archive is required" >&2; return 1; }
  [[ "${ARCHIVE_SHA256}" =~ ^[0-9a-fA-F]{64}$ ]] || { echo "Signed Hotspot archive hash is required" >&2; return 1; }
  [[ -f "${ARCHIVE_SIGNATURE}" && ! -L "${ARCHIVE_SIGNATURE}" && -s "${ARCHIVE_SIGNATURE}" ]] || { echo "Signed Hotspot archive signature is required" >&2; return 1; }
  [[ -f "${SIGNATURE_PUBKEY}" && ! -L "${SIGNATURE_PUBKEY}" && -s "${SIGNATURE_PUBKEY}" ]] || { echo "Trusted update public key is required" >&2; return 1; }
  local actual
  actual="$(sha256sum "${ARCHIVE}" | awk '{print tolower($1)}')"
  [[ "${actual}" == "${ARCHIVE_SHA256,,}" ]] || { echo "Hotspot archive SHA-256 mismatch" >&2; return 1; }
  command -v minisign >/dev/null 2>&1 || { echo "minisign is required for Hotspot archive verification" >&2; return 1; }
  minisign -V -p "${SIGNATURE_PUBKEY}" -m "${ARCHIVE}" -x "${ARCHIVE_SIGNATURE}" -q >/dev/null 2>&1 || { echo "Hotspot archive minisig verification failed" >&2; return 1; }
}

validate_backup_source() {
  local backup="$1" root_real resolved
  [[ -n "${backup}" && -d "${backup}" && ! -L "${backup}" ]] || return 1
  root_real="$(readlink -f "${BACKUPS_DIR}")"; resolved="$(readlink -f "${backup}")"
  [[ "${resolved}" == "${root_real}"/* ]] || return 1
  printf '%s\n' "${resolved}"
}

backup_database() {
  local tree="$1" env_file="$2" from="$3" migration="${4:-1}" stamp backup_dir pg_user pg_db dump
  [[ -f "${env_file}" && ! -L "${env_file}" ]] || { echo "Hotspot environment missing for backup" >&2; return 1; }
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  backup_dir="${BACKUPS_DIR}/${stamp}-${from}"
  mkdir -m 700 "$backup_dir"
  cp -- "${env_file}" "${backup_dir}/env"
  chmod 600 "${backup_dir}/env"
  pg_user="$(env_value "$env_file" POSTGRES_USER)"; pg_user="${pg_user:-hotspot}"
  pg_db="$(env_value "$env_file" POSTGRES_DB)"; pg_db="${pg_db:-hotspot}"
  dump="${backup_dir}/hotspot-${from}-db.sql"
  if [[ "${migration}" == "1" ]]; then
    if ! run_compose "$tree" "$env_file" exec -T postgres pg_dump --no-owner --clean --if-exists -U "$pg_user" -d "$pg_db" > "$dump"; then
      rm -rf -- "$backup_dir"
      return 1
    fi
    [[ -s "$dump" ]] || { rm -rf -- "$backup_dir"; echo "Database backup is empty" >&2; return 1; }
  else
    # Frontend/backend-only updates with an unchanged migration set do not
    # take a database dump. Keep a metadata marker and env checkpoint.
    printf '%s\n' "SKIPPED_NO_MIGRATION" > "$dump"
  fi
  atomic_write_text "${dump}.sha256" "$(sha256sum "${dump}")" 600
  atomic_write_text "${backup_dir}/env.sha256" "$(sha256sum "${backup_dir}/env")" 600
  printf '%s\n' "$backup_dir"
}

verify_backup() {
  local backup="$1" dump expected actual
  backup="$(validate_backup_source "${backup}")" || { echo "Backup path is outside the Hotspot backup root" >&2; return 1; }
  dump="$(find "${backup}" -maxdepth 1 -type f -name '*-db.sql' -print -quit)"
  [[ -n "${dump}" && -s "${dump}" && -f "${dump}.sha256" && ! -L "${dump}.sha256" ]] || { echo "Verified database backup is missing" >&2; return 1; }
  expected="$(awk 'NF {print tolower($1); exit}' "${dump}.sha256")"
  actual="$(sha256sum "${dump}" | awk '{print tolower($1)}')"
  [[ "${expected}" =~ ^[0-9a-f]{64}$ && "${expected}" == "${actual}" ]] || { echo "Database backup hash mismatch" >&2; return 1; }
  printf '%s\n' "${dump}"
}

extract_release() {
  local archive="$1" staging="$2" tmp payload
  [[ -s "$archive" ]] || { echo "Signed Hotspot archive is required" >&2; return 1; }
  [[ -f "${SECURE_EXTRACT}" && ! -L "${SECURE_EXTRACT}" ]] || { echo "Bounded Hotspot extractor is missing" >&2; return 1; }
  tmp="$(mktemp -d "${STATE_DIR}/.extract.XXXXXX")"
  if ! python3 "${SECURE_EXTRACT}" hotspot "${archive}" "${tmp}" "${TARGET}"; then
    rm -rf -- "${tmp}"
    return 1
  fi
  payload="$(find "${tmp}" -mindepth 1 -maxdepth 1 -type d -print -quit)"
  [[ -n "${payload}" && ! -L "${payload}" && -f "${payload}/docker-compose.yml" && -f "${payload}/backend/.env.example" ]] || {
    echo "Archive does not contain a Hotspot Compose release" >&2
    rm -rf -- "${tmp}"
    return 1
  }
  mkdir -p "$staging"
  cp -a -- "${payload}/." "$staging/"
  rm -rf -- "$tmp"
}

preserve_install_config() {
  local old_tree="$1" staging="$2" old_env="${old_tree}/backend/.env"
  mkdir -p "${staging}/backend"
  if [[ -f "$old_env" && ! -L "$old_env" ]]; then
    cp -- "$old_env" "${staging}/backend/.env"
    chmod 0600 "${staging}/backend/.env"
  elif [[ ! -f "${staging}/backend/.env" ]]; then
    echo "Existing Hotspot backend/.env not found" >&2
    return 1
  fi
  # The application reports the deployed release through this non-secret
  # setting; preserving the old value would make a successful upgrade appear
  # to be running the previous version.
  set_env_value "${staging}/backend/.env" PRODUCT_VERSION "${TARGET}"
  chmod 0600 "${staging}/backend/.env"
  if [[ -d "${old_tree}/deploy/ca" && ! -d "${staging}/deploy/ca" ]]; then
    mkdir -p "${staging}/deploy"
    cp -a "${old_tree}/deploy/ca" "${staging}/deploy/ca"
  fi
}

restore_database() {
  local tree="$1" env_file="$2" backup_dir="$3" pg_user pg_db dump
  dump="$(verify_backup "$backup_dir")" || return 1
  if grep -Fxq "SKIPPED_NO_MIGRATION" "$dump"; then
    echo "Database restore is unavailable: backup was skipped because no migration was required" >&2
    return 12
  fi
  pg_user="$(env_value "$env_file" POSTGRES_USER)"; pg_user="${pg_user:-hotspot}"
  pg_db="$(env_value "$env_file" POSTGRES_DB)"; pg_db="${pg_db:-hotspot}"
  run_compose "$tree" "$env_file" up -d postgres
  run_compose "$tree" "$env_file" exec -T postgres psql -v ON_ERROR_STOP=1 -U "$pg_user" -d "$pg_db" < "$dump"
}

verify_rollback_auth() {
  local target="$1" verifier_root
  [[ -n "${ROLLBACK_AUTH}" && "${ROLLBACK_AUTH}" = /* && "${ROLLBACK_AUTH}" != *..* && -f "${ROLLBACK_AUTH}" && ! -L "${ROLLBACK_AUTH}" ]] || {
    echo "Signed rollback authorization is required" >&2
    return 1
  }
  [[ -f "${ROLLBACK_VERIFIER}" && ! -L "${ROLLBACK_VERIFIER}" ]] || { echo "Rollback verifier is missing" >&2; return 1; }
  verifier_root="$(cd "$(dirname "${ROLLBACK_VERIFIER}")/.." && pwd)"
  EXPECTED_ROLLBACK_PRODUCT="hotspot" \
  EXPECTED_ROLLBACK_CHANNEL="${NEOSECRA_EXPECTED_CHANNEL:-hotspot-stable}" \
  EXPECTED_ROLLBACK_EDITION="${NEOSECRA_EDITION_ID:-standard}" \
  V1_ROOT="${verifier_root}" \
  NEOSECRA_SIGNATURE_PUBKEY="${SIGNATURE_PUBKEY:-${verifier_root}/ca/update-neosecra-com.pub}" \
    python3 "${ROLLBACK_VERIFIER}" "${ROLLBACK_AUTH}" "${target}"
}

rollback_to() {
  local target_tree="${RELEASES_DIR}/${TARGET}" old_tree old_env backup_dir from
  verify_rollback_auth "${TARGET}"
  [[ -d "${target_tree}" && ! -L "${target_tree}" ]] || { echo "Rollback release missing: ${target_tree}" >&2; return 1; }
  old_tree="$(current_tree)"
  from="$(current_version)"
  old_env="$(compose_env "${old_tree}")"
  if [[ -z "${BACKUP_SOURCE}" ]]; then
    BACKUP_SOURCE="$(find "${BACKUPS_DIR}" -mindepth 1 -maxdepth 1 -type d -name "*-${TARGET}" -print | sort | tail -n1)"
  fi
  backup_dir="$(validate_backup_source "${BACKUP_SOURCE}")" || { echo "No verified rollback backup found" >&2; return 12; }
  verify_backup "${backup_dir}" >/dev/null

  # A safety dump is taken before stopping the current stack. Persistent
  # volumes remain in place; only Compose services are recreated.
  if run_compose "${old_tree}" "${old_env}" ps --status running -q | grep -q .; then
    backup_database "${old_tree}" "${old_env}" "${from}" >/dev/null || {
      echo "Safety database backup failed; refusing rollback" >&2
      return 12
    }
  fi

  run_compose "${old_tree}" "${old_env}" down --remove-orphans
  [[ -f "$(compose_env "${target_tree}")" && ! -L "$(compose_env "${target_tree}")" ]] || { echo "Rollback target environment missing" >&2; return 1; }
  restore_database "${target_tree}" "$(compose_env "${target_tree}")" "${backup_dir}"
  run_compose "${target_tree}" "$(compose_env "${target_tree}")" up -d --remove-orphans
  wait_api || { echo "Rollback health check failed" >&2; return 1; }
  atomic_switch_current "${target_tree}"
  write_state "${TARGET}"
  write_journal "ROLLED_BACK" "${from}" "${backup_dir}"
}

recover_previous() {
  local old_tree="$1" old_env="$2" backup_dir="$3" from="$4"
  verify_rollback_auth "${from}" || return 1
  run_compose "${old_tree}" "${old_env}" up -d postgres
  restore_database "${old_tree}" "${old_env}" "${backup_dir}"
  run_compose "${old_tree}" "${old_env}" up -d --remove-orphans
  wait_api
}

fail_update() {
  local old_tree="$1" old_env="$2" from="$3" backup_dir="$4" reason="$5" status="FAILED_SAFE"
  if [[ -n "${STAGING}" && -f "$(compose_file "${STAGING}")" && -f "$(compose_env "${STAGING}")" ]]; then
    if ! run_compose "${STAGING}" "$(compose_env "${STAGING}")" down --remove-orphans; then
      reason="${reason}; STAGING_STOP_FAILED"
    fi
  fi
  if [[ -n "${ROLLBACK_AUTH}" ]]; then
    if recover_previous "${old_tree}" "${old_env}" "${backup_dir}" "${from}"; then
      status="ROLLED_BACK"
    else
      reason="${reason}; ROLLBACK_FAILED"
    fi
  else
    reason="${reason}; SIGNED_ROLLBACK_AUTH_REQUIRED"
  fi
  if [[ -n "${STAGING}" && -d "${STAGING}" ]]; then
    rm -rf -- "${STAGING}"
  fi
  write_journal "${status}" "${from}" "${backup_dir}" "${reason}"
  return 1
}

apply_update() {
  local old_tree from backup_dir migration migration_status start_args
  old_tree="$(current_tree)"
  [[ -n "${old_tree}" && -f "$(compose_file "${old_tree}")" ]] || { echo "Hotspot current release is not installed" >&2; return 1; }
  from="$(current_version)"
  [[ "${TARGET}" != "${from}" ]] || { echo "Hotspot is already on ${TARGET}" >&2; return 1; }
  verify_archive
  STAGING="${RELEASES_DIR}/.staging-${TARGET}-$$"
  if [[ -e "${STAGING}" || -L "${STAGING}" ]]; then rm -rf -- "${STAGING}"; fi
  if ! extract_release "${ARCHIVE}" "${STAGING}"; then
    write_journal "FAILED" "${from}" "" "ARCHIVE_EXTRACTION_FAILED"
    return 1
  fi
  if ! preserve_install_config "${old_tree}" "${STAGING}"; then
    fail_update "${old_tree}" "$(compose_env "${old_tree}")" "${from}" "" "CONFIG_PRESERVE_FAILED"
    return 1
  fi
  atomic_write_text "${STAGING}/VERSION" "${TARGET}" 600
  if migration_required "${old_tree}" "${STAGING}"; then
    migration=1
    migration_status="REQUIRED"
  else
    migration=0
    migration_status="SKIPPED_NO_MIGRATION"
  fi
  if ! backup_dir="$(backup_database "${old_tree}" "$(compose_env "${old_tree}")" "${from}" "${migration}")"; then
    fail_update "${old_tree}" "$(compose_env "${old_tree}")" "${from}" "" "BACKUP_FAILED"
    return 1
  fi
  if ! run_compose "${STAGING}" "$(compose_env "${STAGING}")" config >/dev/null; then
    fail_update "${old_tree}" "$(compose_env "${old_tree}")" "${from}" "${backup_dir}" "COMPOSE_CONFIG_FAILED"
    return 1
  fi
  if ! run_compose "${STAGING}" "$(compose_env "${STAGING}")" build api worker beat migrate admin portal; then
    fail_update "${old_tree}" "$(compose_env "${old_tree}")" "${from}" "${backup_dir}" "BUILD_FAILED"
    return 1
  fi
  if ! run_compose "${STAGING}" "$(compose_env "${STAGING}")" up -d postgres redis clickhouse minio createbuckets; then
    fail_update "${old_tree}" "$(compose_env "${STAGING}")" "${from}" "${backup_dir}" "DEPENDENCY_START_FAILED"
    return 1
  fi
  if [[ "${migration}" == "1" ]] && ! run_compose "${STAGING}" "$(compose_env "${STAGING}")" run --rm migrate; then
    fail_update "${old_tree}" "$(compose_env "${STAGING}")" "${from}" "${backup_dir}" "MIGRATION_FAILED"
    return 1
  fi
  if [[ "${migration}" == "1" ]]; then
    start_args=(up -d --remove-orphans api worker beat admin portal)
  else
    # Avoid Compose implicitly starting the migrate dependency when there are
    # no migration changes in this release.
    start_args=(up -d --no-deps api worker beat admin portal)
  fi
  if ! run_compose "${STAGING}" "$(compose_env "${STAGING}")" "${start_args[@]}"; then
    fail_update "${old_tree}" "$(compose_env "${STAGING}")" "${from}" "${backup_dir}" "APPLICATION_START_FAILED"
    return 1
  fi
  if ! wait_api; then
    fail_update "${old_tree}" "$(compose_env "${STAGING}")" "${from}" "${backup_dir}" "HEALTH_CHECK_FAILED"
    return 1
  fi
  [[ ! -e "${RELEASES_DIR}/${TARGET}" && ! -L "${RELEASES_DIR}/${TARGET}" ]] || {
    fail_update "${old_tree}" "$(compose_env "${STAGING}")" "${from}" "${backup_dir}" "TARGET_RELEASE_ALREADY_EXISTS"
    return 1
  }
  mv -- "${STAGING}" "${RELEASES_DIR}/${TARGET}"
  STAGING=""
  atomic_switch_current "${RELEASES_DIR}/${TARGET}"
  write_state "${TARGET}"
  write_journal "COMPLETED" "${from}" "${backup_dir}" "" "${migration_status}"
}

if (( ROLLBACK )); then
  rollback_to
else
  [[ -n "${ARCHIVE}" ]] || { echo "Signed Hotspot archive is required" >&2; exit 4; }
  apply_update
fi
