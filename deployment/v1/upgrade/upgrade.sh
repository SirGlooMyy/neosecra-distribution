#!/usr/bin/env bash
# neosecra upgrade — apply a target version upgrade
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
V1_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${V1_ROOT}/lib/common.sh"
source "${V1_ROOT}/lib/manifest.sh"
source "${V1_ROOT}/lib/docker.sh"
source "${V1_ROOT}/lib/state.sh"

usage() { cat <<EOF
neosecra upgrade — upgrade to a target version
Usage: neosecra upgrade <version> [--bundle <path>] [--rollback-on-failure] [--dry-run] [--help]
EOF
}

TARGET=""; BUNDLE=""; ROLLBACK=0; DRY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h)          usage; exit 0 ;;
    --bundle)           shift; BUNDLE="$1" ;;
    --rollback-on-failure) ROLLBACK=1 ;;
    --dry-run)          DRY=1 ;;
    -*)                 usage; die "unknown option: $1" 2 ;;
    *)                  TARGET="$1" ;;
  esac
  shift
done

[[ -n "$TARGET" ]] || { usage; die "target version required" 1; }

CURRENT=$(read_version)
log "Upgrade: ${CURRENT} -> ${TARGET}"
[[ "$TARGET" != "$CURRENT" ]] || die "Cannot upgrade to same version" 1

acquire_lock

# --- Preflight ---
set +e; bash "${V1_ROOT}/install/preflight.sh"; PREFLIGHT_RC=$?; set -e
[[ $PREFLIGHT_RC -eq 0 ]] && ok "Preflight passed" || warn "Preflight had warnings (continuing)"

[[ $DRY -eq 1 ]] && { ok "Dry-run complete"; exit 0; }

# --- Backup ---
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
BACKUP_TARGET="${BACKUP_ROOT}/${STAMP}-${CURRENT}"
mkdir -p "$BACKUP_TARGET"
bash "${V1_ROOT}/backup/backup.sh" --target "$BACKUP_TARGET"
ok "Pre-upgrade backup: ${BACKUP_TARGET}"

# --- Pull images ---
if [[ -n "$BUNDLE" ]]; then
  TMP_DIR=$(mktemp -d)
  tar xzf "$BUNDLE" -C "$TMP_DIR"
  for img in "$TMP_DIR"/images/*.tar; do
    [[ -f "$img" ]] && docker load -i "$img"
  done
  rm -rf "$TMP_DIR"
else
  ghcr_pull "security-health-backend" "$TARGET"
  ghcr_pull "security-health-frontend" "$TARGET"
fi

# --- Migrate ---
log "Running migrations..."
MIGRATE_OK=0
for _ in 1 2 3; do
  run_compose exec -T backend alembic upgrade head 2>&1 && { MIGRATE_OK=1; break; }
  sleep 3
done
if [[ $MIGRATE_OK -eq 0 ]]; then
  err "Migration failed"
  [[ $ROLLBACK -eq 1 ]] && bash "${V1_ROOT}/upgrade/rollback.sh" --to "$CURRENT" --from-backup "$BACKUP_TARGET"
  die "Upgrade failed at migration" 1
fi
ok "Migrations applied"

# --- Restart ---
run_compose up -d --force-recreate

# --- Verify ---
if bash "${V1_ROOT}/install/postflight.sh" --timeout 120; then
  ok "Health verification passed"
else
  err "Health verification failed"
  [[ $ROLLBACK -eq 1 ]] && bash "${V1_ROOT}/upgrade/rollback.sh" --to "$CURRENT" --from-backup "$BACKUP_TARGET"
  die "Upgrade failed at health check" 1
fi

# --- State ---
write_installed_version "$TARGET"
create_release_dir "$TARGET"
switch_current "$TARGET"
write_journal "upgrade-${CURRENT}-to-${TARGET}-$(date -u +%Y%m%dT%H%M%SZ).json"

ok "Upgrade complete: ${CURRENT} -> ${TARGET}"
