#!/usr/bin/env bash
# neosecra rollback — revert to a previous version
set -uo pipefail

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

CURRENT=$(read_version)
[[ -n "$TARGET" ]] || { usage; die "--to <version> required" 1; }
[[ "$TARGET" != "$CURRENT" ]] || die "Target equals current" 1

log "Rollback: ${CURRENT} -> ${TARGET}"

[[ $DRY -eq 1 ]] && { ok "Rollback dry-run complete"; exit 0; }

# --- Find backup ---
if [[ -z "$BACKUP_SRC" ]]; then
  BACKUP_SRC=$(ls -dt "${BACKUP_ROOT}"/*-"${CURRENT}" 2>/dev/null | head -1 || echo "")
  [[ -n "$BACKUP_SRC" ]] || die "No backup found for ${CURRENT}" 1
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

# --- DB restore ---
DB_DUMP="${BACKUP_SRC}/neosecra-${CURRENT}-db.sql" 2>/dev/null || DB_DUMP="${BACKUP_SRC}/*db.sql"
if [[ -f "$DB_DUMP" ]]; then
  run_compose up -d postgres; sleep 5
  PGUSER=$(env_value POSTGRES_USER neosecra)
  PGDB=$(env_value POSTGRES_DB neosecra_assessment)
  run_compose exec -T postgres psql -U "$PGUSER" -d "$PGDB" < "$DB_DUMP" 2>/dev/null || true
  ok "Database restored from backup"
fi

# --- Start ---
run_compose up -d

# --- Verify ---
bash "${V1_ROOT}/install/postflight.sh" --timeout 90

# --- State ---
write_installed_version "$TARGET"
switch_current "$TARGET"
write_journal "rollback-${CURRENT}-to-${TARGET}-$(date -u +%Y%m%dT%H%M%SZ).json"

ok "Rollback complete: ${CURRENT} -> ${TARGET}"
