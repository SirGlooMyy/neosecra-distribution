#!/usr/bin/env bash
# NeoSecra V1 — restore (SKELETON, non-applying).
#
# DOCUMENTS the restore path. Does NOT reload the database — restore is
# destructive (overwrites live data) and is a separate, not-yet-implemented
# workstream. --restore is intentionally refused.
#
# Safe and non-destructive: reads the backup MANIFEST only.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
V1_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=lib/common.sh
source "${V1_ROOT}/lib/common.sh"

usage() {
  cat <<EOF
NeoSecra V1 restore — procedure (SKELETON, non-applying).

Usage:
  restore.sh --target <backup-dir>            Inspect backup + print restore procedure.
  restore.sh --target <backup-dir> --confirm  ATTEMPT restore — currently REFUSED.
  restore.sh --help

Restore overwrites live database data. This skeleton refuses to perform it
automatically. Perform the steps below manually under DBA supervision, only
from a verified backup.
EOF
}

TARGET=""; CONFIRM=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h)  usage; exit 0 ;;
    --target)   shift; TARGET="${1:-}" ;;
    --confirm)  CONFIRM=1 ;;
    *) usage; die "unexpected argument: $1" 2 ;;
  esac
  shift
done

[[ -n "$TARGET" ]] || { usage; die "--target <backup-dir> is required" 2; }
[[ -d "$TARGET" ]] || die "backup directory not found: $TARGET" 2
require_compose_v2

VERSION="$(read_version)"
log "NeoSecra V1 restore inspection — backup dir ${TARGET} (installed version ${VERSION})"

MANIFEST="${TARGET}/MANIFEST"
if [[ -f "$MANIFEST" ]]; then
  ok "backup MANIFEST found:"
  sed 's/^/    /' "$MANIFEST" >&2
else
  warn "no MANIFEST in ${TARGET} — provenance unknown, proceed with extreme caution."
fi
[[ -f "${TARGET}"/*.sql ]] 2>/dev/null && ok "pg_dump file present in ${TARGET}" || warn "no pg_dump (*.sql) found in ${TARGET}"

if [[ $CONFIRM -eq 1 ]]; then
  err "restore --confirm is NOT IMPLEMENTED in this skeleton."
  err "Restoring overwrites live data: stop services -> drop/reload DB (pg_restore)"
  err "  -> optional alembic downgrade -> restart -> postflight, under DBA review."
  die "refusing to restore (skeleton; restore NOT runtime-verified)" 1
fi

cat <<EOF

=== NeoSecra V1 restore procedure (MANUAL — destructive, DBA supervision) ===

PRECONDITION: the stack is STOPPED and a verified backup exists in ${TARGET}.

1. Stop services (NO -v):
     docker compose --env-file ${ENV_FILE} -f ${COMPOSE_FILE} stop

2. Reload the database from the dump:
     docker compose --env-file ${ENV_FILE} -f ${COMPOSE_FILE} exec -T postgres \
       psql -U <POSTGRES_USER> -d <POSTGRES_DB> < ${TARGET}/neosecra-v1-*-db.sql
   (Prefer pg_restore for custom-format dumps. Reload into an isolated instance
    first to validate before touching production.)

3. If the backup revision differs from the running one, align with alembic.

4. Start + verify:
     docker compose --env-file ${ENV_FILE} -f ${COMPOSE_FILE} up -d
     bash ${V1_ROOT}/install/postflight.sh
==============================================================================
EOF

ok "restore procedure printed. No changes were made."
warn "restore application is NOT implemented in this skeleton (V1_RESTORE_NOT_IMPLEMENTED)."
