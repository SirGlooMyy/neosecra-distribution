#!/usr/bin/env bash
# neosecra rollback — signed rollback using the release's database policy
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
V1_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${V1_ROOT}/lib/common.sh"
source "${V1_ROOT}/lib/state.sh"

usage() { cat <<EOF
neosecra rollback — revert the application pointer to a verified release
Usage: neosecra rollback --to <version> --auth <auth.json> [--pointer-only | --from-backup <dir>] [--dry-run]
EOF
}

TARGET=""; AUTH=""; BACKUP_SRC=""; POINTER_ONLY=0; DRY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h)      usage; exit 0 ;;
    --to)           shift; TARGET="$1" ;;
    --auth)         shift; AUTH="$1" ;;
    --pointer-only) POINTER_ONLY=1 ;;
    --from-backup)  shift; BACKUP_SRC="${1:-}"; [[ -n "$BACKUP_SRC" ]] || die "--from-backup requires a directory" 2 ;;
    --dry-run)      DRY=1 ;;
    *) usage; die "unexpected argument: $1" 2 ;;
  esac
  shift
done

CURRENT=$(read_installed_version 0 2>/dev/null || true)
[[ -n "$CURRENT" && "$CURRENT" != "none" ]] || CURRENT=$(read_version)
[[ -n "$TARGET" ]] || { usage; die "--to <version> required" 1; }
[[ -n "$AUTH" ]] || { usage; die "--auth <file.json> required for secure rollback" 4; }
[[ "$TARGET" != "$CURRENT" ]] || die "Target equals current" 1

log "Verifying signed rollback authorization: ${AUTH}"
if ! python3 "${V1_ROOT}/upgrade/verify_rollback_auth.py" "$AUTH" "$TARGET"; then
  die "SECURITY VIOLATION: Rollback authorization failed" 4
fi

[[ -f "$MANIFEST_FILE" && ! -L "$MANIFEST_FILE" ]] || die "Release policy manifest is missing or unsafe" 12
ROLLBACK_POLICY="$(python3 - "$MANIFEST_FILE" <<'PY'
import sys, yaml
data = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
upgrade = data.get("upgrade") or {}
rollback = data.get("rollback") or {}
policy = rollback.get("database_strategy", "backup_restore")
if policy not in {"none", "backup_restore"}:
    raise SystemExit("Unsupported database rollback policy")
if upgrade.get("backup_required", True) is not (policy == "backup_restore"):
    raise SystemExit("Inconsistent backup/rollback policy")
print(policy)
PY
)" || die "Release rollback policy validation failed" 12
if [[ "$ROLLBACK_POLICY" == "none" ]]; then
  [[ "$POINTER_ONLY" == "1" && -z "$BACKUP_SRC" ]] || die "Pointer-only policy requires --pointer-only and forbids database restore" 12
else
  [[ "$POINTER_ONLY" == "0" ]] || die "Backup-restore policy forbids pointer-only rollback" 12
fi
log "Rollback (${ROLLBACK_POLICY}): ${CURRENT} -> ${TARGET}"

TARGET_V1_ROOT="$(release_dir "$TARGET")"
[[ -d "${TARGET_V1_ROOT}" && ! -L "${TARGET_V1_ROOT}" ]] || \
  die "Target release tree missing or incomplete: ${TARGET_V1_ROOT}" 1
[[ -f "${TARGET_V1_ROOT}/docker-compose.v1.yml" ]] || die "Target release compose file missing" 1

verify_pointer_only_metadata() {
  local tree="$1"
  local json_metadata="${tree}/.neosecra-update-metadata.json" yaml_metadata="${tree}/release-manifest.yaml" metadata
  if [[ -e "$json_metadata" || -L "$json_metadata" ]]; then
    metadata="$json_metadata"
  else
    metadata="$yaml_metadata"
  fi
  [[ -f "$metadata" && ! -L "$metadata" ]] || {
    err "Rollback metadata is missing; database-restore-free rollback is not proven"
    return 12
  }
  if ! python3 - "$metadata" <<'PY'
import json, sys
try:
    import yaml
except ImportError:
    raise SystemExit("PyYAML is required to validate release rollback metadata")
is_json = sys.argv[1].endswith(".json")
with open(sys.argv[1], encoding="utf-8") as stream:
    data = json.load(stream) if is_json else yaml.safe_load(stream)
upgrade = data if is_json else data.get("upgrade") or {}
rollback = data.get("rollback") or {}
if upgrade.get("backup_required") is not False:
    raise SystemExit("backup_required must be false")
if upgrade.get("backward_compatible_with_previous_app") is not True:
    raise SystemExit("backward compatibility is not proven")
if upgrade.get("rollback_safe_without_db_restore") is not True:
    raise SystemExit("pointer rollback safety is not proven")
if upgrade.get("migration_strategy") not in {"off", "additive", "expand-contract"}:
    raise SystemExit("migration strategy is not pointer-safe")
if not is_json and rollback.get("database_strategy") != "none":
    raise SystemExit("database rollback strategy is not pointer-only")
PY
  then
    return 12
  fi
  return 0
}

if [[ "$ROLLBACK_POLICY" == "none" ]]; then
  verify_pointer_only_metadata "${TARGET_V1_ROOT}" ||
    die "Target release is not eligible for database-restore-free rollback" 12
fi
[[ $DRY -eq 1 ]] && { ok "Rollback dry-run complete (${ROLLBACK_POLICY})"; exit 0; }
ensure_release_v1_link "${TARGET_V1_ROOT}"

if [[ "$ROLLBACK_POLICY" == "backup_restore" ]]; then
  # The pre-upgrade backup is named for the release being restored.
  if [[ -z "$BACKUP_SRC" ]]; then
    BACKUP_SRC=$(ls -dt "${BACKUP_ROOT}"/*-"${TARGET}" 2>/dev/null | head -1 || true)
  fi
  [[ -n "$BACKUP_SRC" ]] || die "No backup found for ${TARGET}" 1
  log "Using backup: ${BACKUP_SRC}"
  DB_DUMP="${BACKUP_SRC}/neosecra-${TARGET}-db.sql"
  if [[ ! -f "$DB_DUMP" ]]; then
    DB_DUMP="$(ls -t "${BACKUP_SRC}"/*-db.sql 2>/dev/null | head -1 || true)"
  fi
  [[ -n "$DB_DUMP" && -s "$DB_DUMP" ]] || die "No database dump found in ${BACKUP_SRC}; refusing rollback" 12

  SAFE_STAMP=$(date -u +%Y%m%dT%H%M%SZ)
  SAFE_DIR="${BACKUP_ROOT}/${SAFE_STAMP}-pre-rollback-${CURRENT}"
  mkdir -p "$SAFE_DIR"
  if stack_is_running; then
    PGUSER=$(env_value POSTGRES_USER neosecra)
    PGDB=$(env_value POSTGRES_DB neosecra_assessment)
    run_compose exec -T postgres pg_dump -U "$PGUSER" -d "$PGDB" > "${SAFE_DIR}/pre-rollback-db.sql" 2>/dev/null ||
      die "Safety database backup failed; refusing rollback" 12
    [[ -s "${SAFE_DIR}/pre-rollback-db.sql" ]] || die "Safety database backup is empty; refusing rollback" 12
  fi
fi

# --- Stop ---
run_compose stop

# --- Switch compose context to the TARGET release tree ---
V1_ROOT="${TARGET_V1_ROOT}"
COMPOSE_FILE="${V1_ROOT}/docker-compose.v1.yml"
ENV_FILE="${V1_ROOT}/.env.v1"
VERSION_FILE="${V1_ROOT}/VERSION"
MANIFEST_FILE="${V1_ROOT}/release-manifest.yaml"
[[ -f "$ENV_FILE" ]] || die "Target release .env.v1 missing: ${ENV_FILE}" 1

apply_release_image_refs "$TARGET"
ok "Image pins reverted to ${TARGET} in ${ENV_FILE}"

if [[ "$ROLLBACK_POLICY" == "backup_restore" ]]; then
  run_compose up -d postgres; sleep 5
  PGUSER=$(env_value POSTGRES_USER neosecra)
  PGDB=$(env_value POSTGRES_DB neosecra_assessment)
  # Plain SQL dumps need all non-system schemas reset before strict replay.
  run_compose exec -T postgres psql -v ON_ERROR_STOP=1 -U "$PGUSER" -d "$PGDB" <<'SQL' \
    || die "Database schema reset failed; aborting rollback before restore" 1
DO $reset$
DECLARE
  s text;
BEGIN
  FOR s IN
    SELECT nspname FROM pg_namespace
    WHERE nspname !~ '^pg_' AND nspname <> 'information_schema'
  LOOP
    EXECUTE format('DROP SCHEMA IF EXISTS %I CASCADE', s);
  END LOOP;
END
$reset$;
CREATE SCHEMA IF NOT EXISTS public;
SQL
  run_compose exec -T postgres psql -v ON_ERROR_STOP=1 -U "$PGUSER" -d "$PGDB" \
    < "$DB_DUMP" || die "Database restore failed from ${DB_DUMP}" 1
  ok "Database restored: ${DB_DUMP}"
fi

# --- Start (from the TARGET tree, with the reverted pins) ---
run_compose up -d --force-recreate

# --- Verify ---
bash "${V1_ROOT}/install/postflight.sh" --timeout 90

# --- State ---
write_installed_version "$TARGET"
switch_current "$TARGET"
write_journal "rollback-${CURRENT}-to-${TARGET}-$(date -u +%Y%m%dT%H%M%SZ).json"

ok "Rollback complete: ${CURRENT} -> ${TARGET}"
