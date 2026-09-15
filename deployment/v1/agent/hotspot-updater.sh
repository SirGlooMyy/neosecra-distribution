#!/usr/bin/env bash
# Host-side updater for the NeoSecra Hotspot Compose distribution.
#
# The distribution update-agent verifies the channel/archive signature before
# invoking this script. This script owns the Hotspot-specific transaction:
# migration-gated staged Compose build/migration, health gate, atomic current
# symlink switch, and pointer-only rollback on failure.
set -Eeuo pipefail

AGENT_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SECURE_EXTRACT="${NEOSECRA_SECURE_EXTRACT:-${AGENT_SCRIPT_DIR}/../upgrade/secure_extract.py}"
ROLLBACK_VERIFIER="${NEOSECRA_ROLLBACK_VERIFIER:-${AGENT_SCRIPT_DIR}/../upgrade/verify_rollback_auth.py}"
ARTIFACT_VERIFIER="${NEOSECRA_ARTIFACT_VERIFIER:-${AGENT_SCRIPT_DIR}/artifact-verifier.sh}"
[[ -f "${ARTIFACT_VERIFIER}" && ! -L "${ARTIFACT_VERIFIER}" ]] || {
  echo "Artifact verifier is missing: ${ARTIFACT_VERIFIER}" >&2
  exit 4
}
source "${ARTIFACT_VERIFIER}"

TARGET=""
ARCHIVE=""
ARCHIVE_SHA256=""
ARCHIVE_SIGNATURE=""
SIGNATURE_PUBKEY=""
ROLLBACK_AUTH=""
ROLLBACK=0
RELEASE_METADATA=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --target) shift; TARGET="${1:-}" ;;
    --archive) shift; ARCHIVE="${1:-}" ;;
    --archive-sha256) shift; ARCHIVE_SHA256="${1:-}" ;;
    --archive-signature) shift; ARCHIVE_SIGNATURE="${1:-}" ;;
    --signature-pubkey) shift; SIGNATURE_PUBKEY="${1:-}" ;;
    --rollback-auth|--auth) shift; ROLLBACK_AUTH="${1:-}" ;;
    --backup) echo "Database backup/restore is unsupported in the normal Hotspot updater" >&2; exit 12 ;;
    --release-metadata) shift; RELEASE_METADATA="${1:-}" ;;
    --rollback) ROLLBACK=1 ;;
    --help|-h)
      cat <<'EOF'
Usage: hotspot-updater.sh --target <semver> --archive <tar.gz> \
       --archive-sha256 <sha256> --archive-signature <minisig> \
       --signature-pubkey <pubkey> [--rollback-auth <auth.json>]
       hotspot-updater.sh --rollback --target <semver> --auth <auth.json>
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
if [[ -n "${RELEASE_METADATA}" ]]; then
  [[ "${RELEASE_METADATA}" = /* && "${RELEASE_METADATA}" != *$'\n'* && "${RELEASE_METADATA}" != *$'\r'* && "${RELEASE_METADATA}" != *'/../'* && "${RELEASE_METADATA}" != */.. ]] || {
    echo "Unsafe release metadata path" >&2
    exit 2
  }
fi
CURRENT_LINK="${ROOT}/current"
RELEASES_DIR="${ROOT}/releases"
STATE_DIR="${ROOT}/state"
JOURNAL_DIR="${ROOT}/upgrade-journal"
TRANSACTION_FILE="${STATE_DIR}/hotspot-upgrade.transaction.json"
COMPOSE_PROJECT="${NEOSECRA_COMPOSE_PROJECT:-neosecra-hotspot}"
API_PORT="${HOTSPOT_API_PORT:-38001}"
# Normal updates never create a database/log/volume copy. Keep the legacy
# variable as an explicit rejection so an old deployment cannot silently
# opt back into the forbidden database-copy path.
if [[ "${NEOSECRA_UPDATE_DB_BACKUP:-off}" != "off" ]]; then
  echo "NEOSECRA_UPDATE_DB_BACKUP is unsupported; normal Hotspot updates are backup-free" >&2
  exit 12
fi
STAGING=""
STAGING_STARTED=0
PROGRESS_FILE="${JOURNAL_DIR}/upgrade-progress.json"
PROGRESS_SEQUENCE=0
PROGRESS_FROM_VERSION=""
PROGRESS_CURRENT_STAGE="PREFLIGHT"
MIGRATION_REQUIRED=0
MIGRATION_STRATEGY="off"
MIGRATION_BACKWARD_COMPATIBLE=1
MIGRATION_ROLLBACK_SAFE=1
MIGRATION_CHECKSUM=""
MIGRATION_SCHEMA_FROM=""
MIGRATION_SCHEMA_TO=""
MIGRATION_LOCK_SECONDS=0
MIGRATION_TEMP_SPACE=0
export MIGRATION_REQUIRED MIGRATION_STRATEGY MIGRATION_BACKWARD_COMPATIBLE
export MIGRATION_ROLLBACK_SAFE MIGRATION_CHECKSUM MIGRATION_SCHEMA_FROM
export MIGRATION_SCHEMA_TO MIGRATION_LOCK_SECONDS MIGRATION_TEMP_SPACE

mkdir -p "$RELEASES_DIR" "$STATE_DIR" "$JOURNAL_DIR"
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

write_progress() {
  local stage="$1" status="$2" percent="$3" detail="${4:-}" tmp
  PROGRESS_CURRENT_STAGE="${stage}"
  PROGRESS_SEQUENCE=$((PROGRESS_SEQUENCE + 1))
  tmp="$(mktemp "${PROGRESS_FILE}.tmp.XXXXXX")"
  python3 - "${tmp}" "${status}" "${PROGRESS_FROM_VERSION}" "${TARGET}" "${stage}" "${percent}" "${detail}" "${PROGRESS_SEQUENCE}" "${PROGRESS_FILE}" <<'PY'
import json
import os
import sys
from datetime import datetime, timezone

path, status, previous, target, stage, percent, detail, sequence, existing_path = sys.argv[1:]
try:
    existing = json.loads(open(existing_path, encoding="utf-8").read())
except (OSError, ValueError):
    existing = {}
if existing.get("target_version") != target:
    existing = {}
stages = existing.get("stages") if isinstance(existing.get("stages"), list) else []
entry = next((item for item in stages if isinstance(item, dict) and item.get("stage") == stage), None)
now = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
if entry is None:
    entry = {"stage": stage, "started_at": now}
    stages.append(entry)
entry.update({"status": status, "detail": detail or None, "updated_at": now})
if status in {"ok", "fail"}:
    entry["finished_at"] = now
progress = {
    "percent": max(0, min(100, int(percent))),
    "current_stage": stage,
    "detail": detail or None,
    "updated_at": now,
    "sequence": int(sequence),
}
record = {
    "timestamp": now,
    "product": "hotspot",
    "product_code": "hotspot",
    "edition": os.environ.get("NEOSECRA_EDITION_ID", "standard"),
    "previous_version": previous,
    "target_version": target,
    "status": "FAILED" if status == "fail" else stage,
    "progress": progress,
    "progress_percent": progress["percent"],
    "current_stage": stage,
    "current_stage_detail": detail or None,
    "stages": stages,
}
with open(path, "w", encoding="utf-8") as stream:
    json.dump(record, stream, sort_keys=True, separators=(",", ":"))
    stream.write("\n")
    stream.flush()
    os.fsync(stream.fileno())
os.chmod(path, 0o644)
PY
  atomic_replace "${tmp}" "${PROGRESS_FILE}"
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

version_lt() {
  python3 - "$1" "$2" <<'PY'
import sys
left = tuple(int(part) for part in sys.argv[1].split("."))
right = tuple(int(part) for part in sys.argv[2].split("."))
raise SystemExit(0 if left < right else 1)
PY
}

env_value() {
  local file="$1" key="$2" value
  [[ -f "$file" && ! -L "$file" ]] || return 1
  value="$(awk -F= -v k="$key" '$1 == k {sub(/^[^=]*=/, ""); sub(/\r$/, ""); print; exit}' "$file")"
  printf '%s' "${value}"
}

random_hex() {
  local bytes="$1"
  openssl rand -hex "$bytes" 2>/dev/null || python3 -c "import secrets; print(secrets.token_hex(${bytes}))"
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

ensure_env_value() {
  local file="$1" key="$2" generated="$3" existing
  existing="$(env_value "$file" "$key" || true)"
  if [[ -n "$existing" ]]; then
    printf '%s\n' "$existing"
  else
    set_env_value "$file" "$key" "$generated"
    printf '%s\n' "$generated"
  fi
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

load_release_metadata() {
  local path="${1:-}" staging="$2" old_tree="$3" values
  [[ -n "${path}" && -f "${path}" && ! -L "${path}" ]] || {
    echo "Signed release migration metadata is required" >&2
    return 12
  }
  values="$(python3 - "${path}" <<'PY'
import json
import re
import sys

path = sys.argv[1]
try:
    data = json.loads(open(path, encoding="utf-8").read())
except (OSError, ValueError, TypeError):
    raise SystemExit(1)
if not isinstance(data, dict):
    raise SystemExit(1)
required = {
    "migration_required", "migration_strategy",
    "backward_compatible_with_previous_app", "rollback_safe_without_db_restore",
    "migration_checksum", "schema_from", "schema_to",
    "estimated_lock_seconds", "estimated_temp_space_bytes",
}
if not required.issubset(data):
    raise SystemExit(2)
if not isinstance(data["migration_required"], bool) or not isinstance(data["backward_compatible_with_previous_app"], bool) or not isinstance(data["rollback_safe_without_db_restore"], bool):
    raise SystemExit(3)
strategy = str(data["migration_strategy"] or "")
if strategy not in {"off", "additive", "expand-contract", "offline"}:
    raise SystemExit(4)
checksum = data["migration_checksum"]
if checksum is not None and not re.fullmatch(r"[0-9a-fA-F]{64}", str(checksum)):
    raise SystemExit(5)
for key in ("estimated_lock_seconds", "estimated_temp_space_bytes"):
    value = data[key]
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise SystemExit(6)
if data["migration_required"]:
    if strategy not in {"additive", "expand-contract"} or not data["backward_compatible_with_previous_app"] or not data["rollback_safe_without_db_restore"]:
        raise SystemExit(7)
    if not checksum or not data.get("schema_from") or not data.get("schema_to"):
        raise SystemExit(8)
else:
    if strategy != "off" or checksum is not None or data.get("schema_from") is not None or data.get("schema_to") is not None:
        raise SystemExit(9)
    if not data["backward_compatible_with_previous_app"] or not data["rollback_safe_without_db_restore"]:
        raise SystemExit(10)
print("\t".join([
    "1" if data["migration_required"] else "0", strategy,
    "1" if data["backward_compatible_with_previous_app"] else "0",
    "1" if data["rollback_safe_without_db_restore"] else "0",
    str(data["migration_checksum"] or ""), str(data.get("schema_from") or ""),
    str(data.get("schema_to") or ""), str(data["estimated_lock_seconds"]),
    str(data["estimated_temp_space_bytes"]),
]))
PY
)" || {
    echo "Release migration compatibility metadata is invalid or unsafe" >&2
    return 12
  }
  IFS=$'\t' read -r MIGRATION_REQUIRED MIGRATION_STRATEGY MIGRATION_BACKWARD_COMPATIBLE MIGRATION_ROLLBACK_SAFE MIGRATION_CHECKSUM MIGRATION_SCHEMA_FROM MIGRATION_SCHEMA_TO MIGRATION_LOCK_SECONDS MIGRATION_TEMP_SPACE <<< "${values}"
  local actual_required="0" actual_checksum
  if migration_required "${old_tree}" "${staging}"; then actual_required="1"; fi
  [[ "${actual_required}" == "${MIGRATION_REQUIRED}" ]] || {
    echo "Migration metadata does not match the signed artifact" >&2
    return 12
  }
  if [[ "${MIGRATION_REQUIRED}" == "1" ]]; then
    actual_checksum="$(migration_signature "${staging}")"
    [[ "${actual_checksum}" == "${MIGRATION_CHECKSUM,,}" ]] || {
      echo "Migration checksum does not match the signed artifact" >&2
      return 12
    }
    local available_bytes
    available_bytes="$(df -Pk "${ROOT}" | awk 'NR==2 {print $4 * 1024; exit}')"
    [[ "${available_bytes}" =~ ^[0-9]+$ && "${available_bytes}" -ge "${MIGRATION_TEMP_SPACE}" ]] || {
      echo "Insufficient temporary disk space for migration" >&2
      return 12
    }
  fi
  cp -- "${path}" "${staging}/.neosecra-update-metadata.json"
  chmod 600 "${staging}/.neosecra-update-metadata.json"
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

api_probe_ports() {
  local configured="${API_PORT}" published
  if [[ "${configured}" =~ ^[0-9]+$ && "${configured}" -ge 1 && "${configured}" -le 65535 ]]; then
    printf '%s\n' "${configured}"
  fi
  # The host-side agent environment can retain a stale API port after an
  # install. Resolve the port actually published by the active Compose API
  # container, but only accept a numeric loopback probe target.
  if command -v docker >/dev/null 2>&1; then
    published="$(docker port "${COMPOSE_PROJECT}-api-1" 8000/tcp 2>/dev/null \
      | awk -F: '$NF ~ /^[0-9]+$/ && $NF >= 1 && $NF <= 65535 { print $NF; exit }' || true)"
    if [[ -n "${published}" && "${published}" != "${configured}" ]]; then
      printf '%s\n' "${published}"
    fi
  fi
}

wait_api() {
  local i port health_status
  # Image builds and first-start dependency checks can legitimately take a
  # few minutes on customer hardware. Keep the health gate fail-closed, but
  # allow enough time for the already-started stack to become healthy.
  for i in $(seq 1 150); do
    # Compose's healthcheck is the authoritative in-container probe. Use it
    # alongside the host port check because the host-side curl can race the
    # port publish/recreate window during an application-only update.
    if command -v docker >/dev/null 2>&1; then
      health_status="$(docker inspect --format '{{.State.Health.Status}}' "${COMPOSE_PROJECT}-api-1" 2>/dev/null || true)"
      if [[ "${health_status}" == "healthy" ]]; then
        return 0
      fi
    fi
    # Hotspot exposes its deep service probe at /health (the /api/v1 router
    # intentionally contains only versioned application endpoints).
    while IFS= read -r port; do
      if curl -fsS --max-time 25 "http://127.0.0.1:${port}/health" >/dev/null 2>&1; then
        return 0
      fi
    done < <(api_probe_ports)
    sleep 2
  done
  return 1
}

write_journal() {
  local status="$1" from="$2" backup="$3" error="${4:-}" migration="${5:-}" path tmp
  path="${JOURNAL_DIR}/upgrade-${from}-to-${TARGET}-$(date -u +%Y%m%dT%H%M%SZ).json"
  tmp="$(mktemp "${path}.tmp.XXXXXX")"
  python3 - "${tmp}" "${status}" "${from}" "${TARGET}" "${backup}" "${error}" "${migration}" "${PROGRESS_FILE}" <<'PY'
import json
import os
import sys
from datetime import datetime, timezone
path, status, previous, target, backup, error, migration, progress_path = sys.argv[1:]
try:
    progress_record = json.loads(open(progress_path, encoding="utf-8").read())
except (OSError, ValueError):
    progress_record = {}
record = {
    "timestamp": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
    "product": "hotspot", "product_code": "hotspot",
    "edition": os.environ.get("NEOSECRA_EDITION_ID", "standard"),
    "previous_version": previous, "target_version": target,
    "status": status, "backup_path": backup, "error": error,
    "migration": migration or None,
    "migration_required": os.environ.get("MIGRATION_REQUIRED", "0") == "1",
    "migration_strategy": os.environ.get("MIGRATION_STRATEGY", "off"),
    "schema_from": os.environ.get("MIGRATION_SCHEMA_FROM") or None,
    "schema_to": os.environ.get("MIGRATION_SCHEMA_TO") or None,
    "migration_checksum": os.environ.get("MIGRATION_CHECKSUM") or None,
    "backward_compatible_with_previous_app": os.environ.get("MIGRATION_BACKWARD_COMPATIBLE", "1") == "1",
    "rollback_safe_without_db_restore": os.environ.get("MIGRATION_ROLLBACK_SAFE", "1") == "1",
    "estimated_lock_seconds": int(os.environ.get("MIGRATION_LOCK_SECONDS", "0")),
    "estimated_temp_space_bytes": int(os.environ.get("MIGRATION_TEMP_SPACE", "0")),
    "progress": progress_record.get("progress") or None,
    "progress_percent": progress_record.get("progress_percent"),
    "current_stage": progress_record.get("current_stage"),
    "current_stage_detail": progress_record.get("current_stage_detail"),
    "stages": progress_record.get("stages") if isinstance(progress_record.get("stages"), list) else [],
}
with open(path, "w", encoding="utf-8") as stream:
    json.dump(record, stream, sort_keys=True, separators=(",", ":"))
    stream.write("\n")
    stream.flush(); os.fsync(stream.fileno())
os.chmod(path, 0o600)
PY
  atomic_replace "${tmp}" "${path}"
}

write_state() {
  local version="$1"
  atomic_write_text "${STATE_DIR}/installed-version" "${version}" 600 || return 1
  # Keep the legacy state name in sync for older health/agent readers.
  atomic_write_text "${STATE_DIR}/active-release" "${version}" 600 || return 1
}

write_transaction() {
  local phase="$1" old_tree="$2" backup="${3:-}" staging="${4:-}" migration="${5:-0}" tmp
  tmp="$(mktemp "${TRANSACTION_FILE}.tmp.XXXXXX")"
  python3 - "${tmp}" "${phase}" "${old_tree}" "${TARGET}" "${backup}" "${staging}" "${migration}" <<'PY'
import json
import os
import sys
from datetime import datetime, timezone
path, phase, old_tree, target, backup, staging, migration = sys.argv[1:]
record = {
    "timestamp": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
    "product": "hotspot", "phase": phase, "previous_version": old_tree.rsplit("/", 1)[-1],
    "target_version": target, "old_tree": old_tree, "backup": backup,
    "staging": staging, "migration": migration == "1",
    "migration_required": os.environ.get("MIGRATION_REQUIRED", "0") == "1",
    "migration_strategy": os.environ.get("MIGRATION_STRATEGY", "off"),
    "rollback_safe_without_db_restore": os.environ.get("MIGRATION_ROLLBACK_SAFE", "1") == "1",
}
with open(path, "w", encoding="utf-8") as stream:
    json.dump(record, stream, sort_keys=True, separators=(",", ":"))
    stream.write("\n")
    stream.flush(); os.fsync(stream.fileno())
os.chmod(path, 0o600)
PY
  atomic_replace "${tmp}" "${TRANSACTION_FILE}"
}

clear_transaction() {
  rm -f -- "${TRANSACTION_FILE}"
  fsync_dir "${STATE_DIR}" || true
}

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
  if [[ ! -f "${SIGNATURE_PUBKEY}" && ! -d "${SIGNATURE_PUBKEY}" || -L "${SIGNATURE_PUBKEY}" ]]; then
    echo "Trusted update public key/keyring is required" >&2
    return 1
  fi
  local actual
  actual="$(sha256sum "${ARCHIVE}" | awk '{print tolower($1)}')"
  [[ "${actual}" == "${ARCHIVE_SHA256,,}" ]] || { echo "Hotspot archive SHA-256 mismatch" >&2; return 1; }
  verify_minisign_file "${ARCHIVE}" "${ARCHIVE_SIGNATURE}" "${SIGNATURE_PUBKEY}" || {
    echo "Hotspot archive minisig verification failed" >&2
    return 1
  }
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
  # The application and health endpoint report the deployed release through
  # these non-secret settings; preserving either old value would make a
  # successful upgrade appear to be running the previous version.
  set_env_value "${staging}/backend/.env" PRODUCT_VERSION "${TARGET}"
  set_env_value "${staging}/backend/.env" VERSION "${TARGET}"
  # Compose releases after 0.3.27 require an explicit ClickHouse password.
  # Older installations may not have this key; generate it once in the
  # staged environment so upgrade validation remains compatible without
  # exposing a default credential or changing existing values.
  ensure_env_value "${staging}/backend/.env" CLICKHOUSE_PASSWORD "$(random_hex 32)" >/dev/null
  chmod 0600 "${staging}/backend/.env"
  if [[ -d "${old_tree}/deploy/ca" && ! -d "${staging}/deploy/ca" ]]; then
    mkdir -p "${staging}/deploy"
    cp -a "${old_tree}/deploy/ca" "${staging}/deploy/ca"
  fi
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
  NEOSECRA_SIGNATURE_PUBKEY="${SIGNATURE_PUBKEY:-${verifier_root}/ca}" \
    python3 "${ROLLBACK_VERIFIER}" "${ROLLBACK_AUTH}" "${target}"
}

verify_release_rollback_metadata() {
  local tree="$1" metadata="${tree}/.neosecra-update-metadata.json"
  [[ -f "${metadata}" && ! -L "${metadata}" ]] || {
    echo "Rollback metadata is missing; DB-restore-free rollback is not proven" >&2
    return 12
  }
  python3 - "${metadata}" <<'PY'
import json
import sys
data = json.loads(open(sys.argv[1], encoding="utf-8").read())
if data.get("rollback_safe_without_db_restore") is not True:
    raise SystemExit(1)
if data.get("backward_compatible_with_previous_app") is not True:
    raise SystemExit(1)
if data.get("migration_strategy") not in {"off", "additive", "expand-contract"}:
    raise SystemExit(1)
PY
}

rollback_to() {
  local target_tree="${RELEASES_DIR}/${TARGET}" old_tree old_env from
  verify_rollback_auth "${TARGET}"
  [[ -d "${target_tree}" && ! -L "${target_tree}" ]] || { echo "Rollback release missing: ${target_tree}" >&2; return 1; }
  verify_release_rollback_metadata "${target_tree}"
  old_tree="$(current_tree)"
  from="$(current_version)"
  old_env="$(compose_env "${old_tree}")"
  run_compose "${old_tree}" "${old_env}" down --remove-orphans
  [[ -f "$(compose_env "${target_tree}")" && ! -L "$(compose_env "${target_tree}")" ]] || { echo "Rollback target environment missing" >&2; return 1; }
  run_compose "${target_tree}" "$(compose_env "${target_tree}")" up -d --remove-orphans
  wait_api || { echo "Rollback health check failed" >&2; return 1; }
  atomic_switch_current "${target_tree}"
  write_state "${TARGET}"
  write_journal "ROLLED_BACK" "${from}" "" "POINTER_ONLY_ROLLBACK"
}

recover_previous() {
  local old_tree="$1" old_env="$2" from="$3"
  verify_rollback_auth "${from}" || return 1
  verify_release_rollback_metadata "${old_tree}" || return 1
  restore_previous_stack "${old_tree}" "${old_env}"
  atomic_switch_current "${old_tree}"
  write_state "${old_tree##*/}"
}

restore_previous_stack() {
  local old_tree="$1" old_env="$2"
  # Staging and production deliberately share the project name so the
  # release can reuse the existing named data volumes and host ports. A
  # `down` on the staging tree would therefore remove the active stack too.
  # Rebuild the previous source tree and recreate only its application
  # services instead; persistent dependencies and volumes stay untouched.
  run_compose "${old_tree}" "${old_env}" build api worker beat admin portal || return 1
  run_compose "${old_tree}" "${old_env}" up -d --no-deps api worker beat admin portal freeradius || return 1
  wait_api
}

fail_update() {
  local old_tree="$1" old_env="$2" from="$3" backup_dir="$4" reason="$5" status="FAILED_SAFE" migration_required="false"
  if [[ -f "${TRANSACTION_FILE}" && ! -L "${TRANSACTION_FILE}" ]]; then
    migration_required="$(python3 - "${TRANSACTION_FILE}" <<'PY'
import json
import sys
from pathlib import Path

try:
    value = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8")).get("migration", False)
except (OSError, ValueError):
    value = False
print("true" if value in (True, 1, "1", "true") else "false")
PY
    )"
  fi
  if [[ "${STAGING_STARTED}" == "1" ]]; then
    if ! restore_previous_stack "${old_tree}" "${old_env}"; then
      reason="${reason}; PREVIOUS_STACK_RESTORE_FAILED"
    fi
  fi
  if [[ -n "${ROLLBACK_AUTH}" ]]; then
    if recover_previous "${old_tree}" "${old_env}" "${from}"; then
      status="ROLLED_BACK"
    else
      reason="${reason}; ROLLBACK_FAILED"
    fi
  elif [[ "${migration_required}" != "true" ]]; then
    # Application-only updates do not need a database rollback authorization.
    # The previous source tree and containers were restored above; recording
    # this explicitly prevents a failed update from leaving staging images
    # active while still keeping DB rollback fail-closed for migrations.
    reason="${reason}; APP_STACK_RESTORED_NO_DB_ROLLBACK"
  else
    reason="${reason}; SIGNED_ROLLBACK_AUTH_REQUIRED"
  fi
  if [[ -n "${STAGING}" && -d "${STAGING}" ]]; then
    rm -rf -- "${STAGING}"
  fi
  clear_transaction
  write_progress "${PROGRESS_CURRENT_STAGE}" "fail" 10 "${reason}"
  write_journal "${status}" "${from}" "" "${reason}"
  return 1
}

recover_interrupted_transaction() {
  [[ -f "${TRANSACTION_FILE}" && ! -L "${TRANSACTION_FILE}" ]] || return 0
  local phase old_tree target backup staging migration current requested_target old_env
  read -r phase old_tree target backup staging migration < <(
    python3 - "${TRANSACTION_FILE}" <<'PY'
import json
import sys
from pathlib import Path
data = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
print("\t".join(str(data.get(key, "")) for key in ("phase", "old_tree", "target_version", "backup", "staging", "migration")))
PY
  )
  [[ "${target}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Interrupted transaction target is invalid" >&2; return 12; }
  [[ "${old_tree}" == "${RELEASES_DIR}"/* && -d "${old_tree}" && ! -L "${old_tree}" ]] || {
    echo "Interrupted transaction previous release is invalid" >&2
    return 12
  }
  current="$(current_tree || true)"
  requested_target="${TARGET}"
  TARGET="${target}"
  if [[ "${phase}" == "HEALTHY" || "${phase}" == "SWITCHED" ]] \
      && [[ "${current}" == "${RELEASES_DIR}/${target}" ]] \
      && wait_api; then
    write_state "${target}"
    clear_transaction
    write_journal "COMPLETED_RECOVERED" "${old_tree##*/}" "" ""
    TARGET="${requested_target}"
    return 0
  fi
  old_env="$(compose_env "${old_tree}")"
  restore_previous_stack "${old_tree}" "${old_env}" || {
    TARGET="${requested_target}"
    echo "Interrupted Hotspot transaction could not restore the previous stack" >&2
    return 12
  }
  atomic_switch_current "${old_tree}"
  write_state "${old_tree##*/}"
  [[ -z "${staging}" || ! -e "${staging}" ]] || rm -rf -- "${staging}"
  clear_transaction
  write_journal "FAILED_SAFE_RECOVERED" "${old_tree##*/}" "" "INTERRUPTED_TRANSACTION"
  TARGET="${requested_target}"
}

apply_update() {
  local old_tree from migration migration_status start_args
  old_tree="$(current_tree)"
  [[ -n "${old_tree}" && -f "$(compose_file "${old_tree}")" ]] || { echo "Hotspot current release is not installed" >&2; return 1; }
  from="$(current_version)"
  PROGRESS_FROM_VERSION="${from}"
  write_progress "PREFLIGHT" "running" 10 "İmzalı artifact ve mevcut release doğrulanıyor"
  [[ "${TARGET}" != "${from}" ]] || { echo "Hotspot is already on ${TARGET}" >&2; return 1; }
  if version_lt "${TARGET}" "${from}"; then
    echo "Hotspot downgrade is not permitted: ${from} -> ${TARGET}; use signed rollback" >&2
    return 1
  fi
  if ! verify_archive; then
    write_progress "PREFLIGHT" "fail" 10 "İmzalı artifact doğrulanamadı"
    write_journal "FAILED" "${from}" "" "ARCHIVE_VERIFICATION_FAILED"
    return 1
  fi
  STAGING="${RELEASES_DIR}/.staging-${TARGET}-$$"
  if [[ -e "${STAGING}" || -L "${STAGING}" ]]; then rm -rf -- "${STAGING}"; fi
  if ! extract_release "${ARCHIVE}" "${STAGING}"; then
    write_progress "PREFLIGHT" "fail" 10 "Release arşivi güvenli biçimde açılamadı"
    write_journal "FAILED" "${from}" "" "ARCHIVE_EXTRACTION_FAILED"
    return 1
  fi
  if ! preserve_install_config "${old_tree}" "${STAGING}"; then
    fail_update "${old_tree}" "$(compose_env "${old_tree}")" "${from}" "" "CONFIG_PRESERVE_FAILED"
    return 1
  fi
  write_progress "PREFLIGHT" "ok" 20 "Artifact ve kurulum ayarları doğrulandı"
  write_progress "STAGING" "running" 25 "Release staging alanı hazırlanıyor"
  atomic_write_text "${STAGING}/VERSION" "${TARGET}" 600
  if ! load_release_metadata "${RELEASE_METADATA}" "${STAGING}" "${old_tree}"; then
    fail_update "${old_tree}" "$(compose_env "${old_tree}")" "${from}" "" "MIGRATION_METADATA_INVALID"
    return 1
  fi
  migration="${MIGRATION_REQUIRED}"
  if [[ "${MIGRATION_REQUIRED}" == "1" ]]; then migration_status="REQUIRED"; else migration_status="SKIPPED_NO_MIGRATION"; fi
  write_progress "STAGING" "ok" 35 "Release staging ve metadata doğrulandı"
  write_progress "MIGRATION_CHECK" "running" 40 "Yedeksiz migration uyumluluğu doğrulanıyor"
  write_transaction "STAGED" "${old_tree}" "" "${STAGING}" "${migration}"
  if ! run_compose "${STAGING}" "$(compose_env "${STAGING}")" config >/dev/null; then
    fail_update "${old_tree}" "$(compose_env "${old_tree}")" "${from}" "" "COMPOSE_CONFIG_FAILED"
    return 1
  fi
  STAGING_STARTED=1
  # Customer appliances may be air-gapped or have restricted IPv6/registry
  # egress. The signed source archive is the release input; rebuilding must
  # use the appliance's already cached base images and fail closed if one is
  # genuinely unavailable, rather than attempting an implicit registry pull.
  if ! run_compose "${STAGING}" "$(compose_env "${STAGING}")" build --pull=false api worker beat migrate admin portal freeradius; then
    fail_update "${old_tree}" "$(compose_env "${old_tree}")" "${from}" "" "BUILD_FAILED"
    return 1
  fi
  if ! run_compose "${STAGING}" "$(compose_env "${STAGING}")" up -d postgres redis clickhouse minio createbuckets; then
    fail_update "${old_tree}" "$(compose_env "${STAGING}")" "${from}" "" "DEPENDENCY_START_FAILED"
    return 1
  fi
  # Release migration metadata describes the code delta, not whether the
  # target database already has a schema. Always converge to Alembic heads so
  # a clean/replaced PostgreSQL volume cannot start an apparently healthy API
  # with no tables. Alembic is idempotent when the schema is current.
  if ! run_compose "${STAGING}" "$(compose_env "${STAGING}")" run --rm migrate; then
    fail_update "${old_tree}" "$(compose_env "${STAGING}")" "${from}" "" "MIGRATION_FAILED"
    return 1
  fi
  start_args=(up -d --remove-orphans api worker beat admin portal freeradius)
  if ! run_compose "${STAGING}" "$(compose_env "${STAGING}")" "${start_args[@]}"; then
    fail_update "${old_tree}" "$(compose_env "${STAGING}")" "${from}" "" "APPLICATION_START_FAILED"
    return 1
  fi
  write_transaction "STARTED" "${old_tree}" "" "${STAGING}" "${migration}"
  write_progress "MIGRATION_CHECK" "ok" 50 "Migration uyumluluğu doğrulandı"
  write_progress "ACTIVATING" "running" 65 "Yeni uygulama stack'i başlatılıyor"
  write_progress "ACTIVATING" "ok" 75 "Yeni uygulama stack'i başlatıldı"
  write_progress "VERIFYING" "running" 85 "Yeni release health kontrolü bekleniyor"
  if ! wait_api; then
    fail_update "${old_tree}" "$(compose_env "${STAGING}")" "${from}" "" "HEALTH_CHECK_FAILED"
    return 1
  fi
  write_progress "VERIFYING" "ok" 95 "API ve servis health kontrolü başarılı"
  write_transaction "HEALTHY" "${old_tree}" "" "${STAGING}" "${migration}"
  [[ ! -e "${RELEASES_DIR}/${TARGET}" && ! -L "${RELEASES_DIR}/${TARGET}" ]] || {
    fail_update "${old_tree}" "$(compose_env "${STAGING}")" "${from}" "" "TARGET_RELEASE_ALREADY_EXISTS"
    return 1
  }
  mv -- "${STAGING}" "${RELEASES_DIR}/${TARGET}"
  STAGING=""
  atomic_switch_current "${RELEASES_DIR}/${TARGET}"
  write_state "${TARGET}"
  clear_transaction
  write_progress "VERIFYING" "ok" 100 "Güncelleme tamamlandı"
  write_journal "COMPLETED" "${from}" "" "" "${migration_status}"
}

recover_interrupted_transaction
if (( ROLLBACK )); then
  rollback_to
else
  [[ -n "${ARCHIVE}" ]] || { echo "Signed Hotspot archive is required" >&2; exit 4; }
  apply_update
fi
