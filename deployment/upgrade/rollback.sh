#!/usr/bin/env bash
# neosecra rollback — revert to a previous version
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
V1_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${V1_ROOT}/lib/common.sh"
source "${V1_ROOT}/lib/state.sh"

usage() { cat <<EOF
neosecra rollback — revert to a previous version
Usage: neosecra rollback --to <version> [--from-backup <dir>] [--dry-run] [--help]
EOF
}

TARGET=""; BACKUP_SRC=""; DRY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h)      usage; exit 0 ;;
    --to)           shift; TARGET="$1" ;;
    --from-backup)  shift; BACKUP_SRC="$1" ;;
    --dry-run)      DRY=1 ;;
    *) usage; die "unexpected argument: $1" 2 ;;
  esac
  shift
done

CURRENT=$(read_installed_version 2>/dev/null || true)
[[ -n "$CURRENT" && "$CURRENT" != "none" ]] || CURRENT=$(read_version)
[[ -n "$TARGET" ]] || { usage; die "--to <version> required" 1; }
[[ "$TARGET" != "$CURRENT" ]] || die "Target equals current" 1

log "Rollback: ${CURRENT} -> ${TARGET}"

[[ $DRY -eq 1 ]] && { ok "Rollback dry-run complete"; exit 0; }

# --- Target release tree ---
# Containers must be recreated from the TARGET release tree (its compose file
# and .env.v1), not from the tree we are rolling back FROM — the current
# tree's env was mutated by the upgrade (image pins now point at the NEW
# version) and its compose file may not match the target's services.
TARGET_V1_ROOT="$(release_dir "$TARGET")"
[[ -f "${TARGET_V1_ROOT}/docker-compose.v1.yml" ]] || \
  die "Target release tree missing or incomplete: ${TARGET_V1_ROOT}" 1
ensure_release_v1_link "${TARGET_V1_ROOT}"

# --- Find backup ---
# upgrade.sh names the pre-upgrade backup "<ts>-<from-version>" and the dump
# "neosecra-<from-version>-db.sql", where <from-version> is the version we are
# rolling back TO (it was current when the backup was taken).
if [[ -z "$BACKUP_SRC" ]]; then
  BACKUP_SRC=$(ls -dt "${BACKUP_ROOT}"/*-"${TARGET}" 2>/dev/null | head -1 || echo "")
  [[ -n "$BACKUP_SRC" ]] || die "No backup found for ${TARGET}" 1
fi
log "Using backup: ${BACKUP_SRC}"

# --- Safety backup ---
SAFE_STAMP=$(date -u +%Y%m%dT%H%M%SZ)
SAFE_DIR="${BACKUP_ROOT}/${SAFE_STAMP}-pre-rollback-${CURRENT}"
mkdir -p "$SAFE_DIR"
if stack_is_running; then
  PGUSER=$(env_value POSTGRES_USER neosecra)
  PGDB=$(env_value POSTGRES_DB neosecra_assessment)
  run_compose exec -T postgres pg_dump -U "$PGUSER" -d "$PGDB" > "${SAFE_DIR}/pre-rollback-db.sql" 2>/dev/null || true
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

# --- Revert image pins to the rollback target ---
# apply_release_image_refs upserts unconditionally, so this forces
# NEOSECRA_VERSION/BACKEND_IMAGE/WORKER_IMAGE/FRONTEND_IMAGE in the target
# tree's .env.v1 back to the target version's refs (manifest first, registry
# convention as fallback).
apply_release_image_refs "$TARGET"
ok "Image pins reverted to ${TARGET} in ${ENV_FILE}"

# --- DB restore ---
DB_DUMP="${BACKUP_SRC}/neosecra-${TARGET}-db.sql"
if [[ ! -f "$DB_DUMP" ]]; then
  # Tolerate older backup dirs whose dump name deviates; take the newest one.
  DB_DUMP="$(ls -t "${BACKUP_SRC}"/*-db.sql 2>/dev/null | head -1 || true)"
fi
if [[ -n "$DB_DUMP" && -f "$DB_DUMP" ]]; then
  run_compose up -d postgres; sleep 5
  PGUSER=$(env_value POSTGRES_USER neosecra)
  PGDB=$(env_value POSTGRES_DB neosecra_assessment)
  # The dump is plain SQL taken WITHOUT pg_dump --clean; replaying it over the
  # live schema collides on existing objects. Drop/recreate the public schema
  # first (the plain-SQL equivalent of --clean), then restore strictly —
  # a failed restore aborts the rollback instead of being silently skipped.
  run_compose exec -T postgres psql -v ON_ERROR_STOP=1 -U "$PGUSER" -d "$PGDB" \
    -c 'DROP SCHEMA public CASCADE; CREATE SCHEMA public;' \
    || die "Database schema reset failed; aborting rollback before restore" 1
  run_compose exec -T postgres psql -v ON_ERROR_STOP=1 -U "$PGUSER" -d "$PGDB" \
    < "$DB_DUMP" || die "Database restore failed from ${DB_DUMP}" 1
  ok "Database restored: ${DB_DUMP}"
else
  warn "No database dump found in ${BACKUP_SRC} — database left untouched"
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
