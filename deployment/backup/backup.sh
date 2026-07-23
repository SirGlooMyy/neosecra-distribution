#!/usr/bin/env bash
# neosecra backup — create a database backup
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
V1_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${V1_ROOT}/lib/common.sh"
source "${V1_ROOT}/lib/state.sh"

usage() { cat <<'EOF'
neosecra backup — create database and configuration backup
Usage: neosecra backup --target <dir> | --auto [--help]
EOF
}

TARGET=""; AUTO=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h)  usage; exit 0 ;;
    --target)   shift; TARGET="$1" ;;
    --auto)     AUTO=1 ;;
    *) usage; die "unexpected argument: $1" 2 ;;
  esac
  shift
done

VERSION="$(read_version)"
if [[ $AUTO -eq 1 ]]; then
  STAMP=$(date -u +%Y%m%dT%H%M%SZ)
  TARGET="${BACKUP_ROOT}/${STAMP}-${VERSION}"
fi
[[ -n "$TARGET" ]] || { usage; die "--target or --auto required" 2; }

mkdir -p "$TARGET"
TARGET="$(cd "$TARGET" && pwd)"
log "Backup -> ${TARGET} (version ${VERSION})"

DUMPED=0; DUMP_FILE="${TARGET}/neosecra-${VERSION}-db.sql"
if stack_is_running; then
  PGUSER=$(env_value POSTGRES_USER neosecra)
  PGDB=$(env_value POSTGRES_DB neosecra_assessment)
  if run_compose exec -T postgres pg_dump -U "$PGUSER" -d "$PGDB" > "$DUMP_FILE" 2>/dev/null; then
    ok "pg_dump: $(du -h "$DUMP_FILE" | cut -f1)"
    DUMPED=1
  else
    warn "pg_dump failed"
  fi
else
  warn "Stack not running — pg_dump skipped"
fi

# --- Config snapshot ---
cp "$COMPOSE_FILE" "${TARGET}/docker-compose.snapshot.yml" 2>/dev/null || true
cp "$MANIFEST_FILE" "${TARGET}/release-manifest.yaml" 2>/dev/null || true
echo "$VERSION" > "${TARGET}/source-version"
ACTIVE=$(read_installed_version 2>/dev/null || echo "?")
echo "$ACTIVE" > "${TARGET}/active-version"

# --- Manifest ---
{
  echo "# NeoSecra Assessment backup manifest"
  echo "product: ${PRODUCT}"
  echo "edition: ${EDITION}"
  echo "version: ${VERSION}"
  echo "active_version: ${ACTIVE}"
  echo "backup_time: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "files:"
  [[ $DUMPED -eq 1 ]] && echo "  - $(basename "$DUMP_FILE") ($(sha256sum "$DUMP_FILE" | cut -d' ' -f1))"
  echo "  - docker-compose.snapshot.yml ($(sha256sum "${TARGET}/docker-compose.snapshot.yml" 2>/dev/null | cut -d' ' -f1 || echo '?'))"
  echo "  - release-manifest.yaml ($(sha256sum "${TARGET}/release-manifest.yaml" 2>/dev/null | cut -d' ' -f1 || echo '?'))"
} > "${TARGET}/MANIFEST"
ok "Backup manifest: ${TARGET}/MANIFEST"

ok "Backup complete -> ${TARGET}"
