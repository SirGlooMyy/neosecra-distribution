#!/usr/bin/env bash
# neosecra upgrade — apply a target version upgrade
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
V1_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${V1_ROOT}/lib/common.sh"
source "${V1_ROOT}/lib/manifest.sh"
source "${V1_ROOT}/lib/docker.sh"
source "${V1_ROOT}/lib/state.sh"

usage() { cat <<EOF
neosecra upgrade — upgrade to a target version
Usage: neosecra upgrade [version] [--bundle <path>] [--rollback-on-failure] [--dry-run] [--help]

Without a version, the assessment stable channel is used.
EOF
}

TARGET=""; BUNDLE=""; ROLLBACK=0; DRY=0; TARGET_FROM_ARG=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h)          usage; exit 0 ;;
    --bundle)           shift; BUNDLE="$1" ;;
    --rollback-on-failure) ROLLBACK=1 ;;
    --dry-run)          DRY=1 ;;
    -*)                 usage; die "unknown option: $1" 2 ;;
    *)                  TARGET="$1"; TARGET_FROM_ARG=1 ;;
  esac
  shift
done

CHANNEL_URL="${NEOSECRA_CHANNEL_URL:-https://raw.githubusercontent.com/SirGlooMyy/neosecra-distribution/fix/assessment-live-installer/channels/assessment-stable.json}"
BOOTSTRAP_URL="${NEOSECRA_BOOTSTRAP_URL:-https://raw.githubusercontent.com/SirGlooMyy/neosecra-distribution/fix/assessment-live-installer/bootstrap.sh}"
ARCHIVE_URL="${NEOSECRA_DISTRIBUTION_ARCHIVE_URL:-https://github.com/SirGlooMyy/neosecra-distribution/archive/refs/heads/fix/assessment-live-installer.tar.gz}"
resolve_channel_target() {
  local json target
  json="$(curl -fsSL "$CHANNEL_URL" 2>/dev/null || true)"
  target="$(printf '%s\n' "$json" | sed -nE 's/.*"current_version"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' | head -n1)"
  printf '%s' "$target"
}

if [[ -z "$TARGET" ]]; then
  TARGET="$(resolve_channel_target)"
  [[ -n "$TARGET" ]] || TARGET="$(read_version)"
fi

prepare_target_release() {
  local target="$1" dest backup_path tmp_manifest
  dest="$(release_dir "$target")"

  if [[ "$(readlink -f "$dest" 2>/dev/null || true)" != "$(readlink -f "$V1_ROOT" 2>/dev/null || true)" ]]; then
    if [[ -e "$dest" ]]; then
      backup_path="${BACKUP_ROOT}/preupgrade-release-${target}-$(date -u +%Y%m%dT%H%M%SZ)"
      mkdir -p "$backup_path"
      cp -a "$dest" "${backup_path}/release-${target}"
      warn "Existing target release backed up: ${backup_path}/release-${target}"
    fi
    mkdir -p "$dest"
    cp -a "$V1_ROOT/." "$dest/"
  fi

  printf '%s\n' "$target" > "${dest}/VERSION"
  if [[ -f "${dest}/release-manifest.yaml" ]]; then
    tmp_manifest="$(mktemp)"
    awk -v target="$target" '
      /^version:/ { print "version: " target; next }
      { print }
    ' "${dest}/release-manifest.yaml" > "$tmp_manifest"
    mv "$tmp_manifest" "${dest}/release-manifest.yaml"
  fi
}

CURRENT=$(read_installed_version 2>/dev/null || true)
[[ -n "$CURRENT" && "$CURRENT" != "none" ]] || CURRENT=$(read_version)
if [[ $TARGET_FROM_ARG -eq 0 && "$TARGET" != "$(read_version)" && "${NEOSECRA_UPGRADE_BOOTSTRAP:-1}" == "1" ]]; then
  log "Channel target ${TARGET} requires newer installer metadata; refreshing from GitHub..."
  curl -fsSL "$BOOTSTRAP_URL" | NEOSECRA_DISTRIBUTION_ARCHIVE_URL="$ARCHIVE_URL" bash
  exit $?
fi

log "Upgrade: ${CURRENT} -> ${TARGET}"
if [[ "$TARGET" == "$CURRENT" ]]; then
  ok "Already on latest version: ${TARGET}"
  exit 0
fi

acquire_lock

# --- Environment initialization ---
initialize_env_file
apply_release_image_refs "$TARGET"
validate_env_file || die ".env.v1 validation failed" 2

# --- Preflight ---
bash "${V1_ROOT}/install/preflight.sh" || die "Preflight failed" 10
ok "Preflight passed"

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
  warn "Temporary bundle extraction left for audit: ${TMP_DIR}"
else
  ghcr_login
  for service in backend worker frontend; do
    pull_service_image "$service"
  done
fi

# --- Dependencies ---
log "Ensuring PostgreSQL and Redis are running..."
run_compose up -d postgres redis
wait_service_healthy postgres 90
wait_service_healthy redis 90
reconcile_postgres_password

# --- Migrate ---
log "Running migrations..."
MIGRATE_OK=0
for _ in 1 2 3; do
  run_compose run --rm backend alembic upgrade head && { MIGRATE_OK=1; break; }
  sleep 3
done
if [[ $MIGRATE_OK -eq 0 ]]; then
  err "Migration failed"
  [[ $ROLLBACK -eq 1 ]] && bash "${V1_ROOT}/upgrade/rollback.sh" --to "$CURRENT" --from-backup "$BACKUP_TARGET"
  die "Upgrade failed at migration" 1
fi
ok "Migrations applied"
ensure_assessment_schema_compatibility || die "Assessment schema compatibility repair failed" 11
sync_initial_admin_credentials || die "Initial admin credential synchronization failed" 11

# --- Restart ---
if ! run_compose up -d --force-recreate backend worker frontend; then
  print_service_diagnostics backend worker frontend
  die "Application services failed to start after upgrade" 13
fi
wait_service_healthy backend 120
wait_service_running worker 60
wait_service_running frontend 60
wait_frontend_http 120 || { print_service_diagnostics frontend; die "Frontend HTTP not reachable within 120s" 13; }
wait_frontend_api_proxy 120 || { print_service_diagnostics frontend backend; die "Frontend API proxy not reachable within 120s" 13; }
verify_initial_admin_login_via_frontend || { print_service_diagnostics frontend backend; die "Initial admin login verification failed" 13; }

# --- Verify ---
if bash "${V1_ROOT}/install/postflight.sh" --timeout 120; then
  ok "Health verification passed"
else
  err "Health verification failed"
  [[ $ROLLBACK -eq 1 ]] && bash "${V1_ROOT}/upgrade/rollback.sh" --to "$CURRENT" --from-backup "$BACKUP_TARGET"
  die "Upgrade failed at health check" 1
fi

# --- State ---
prepare_target_release "$TARGET"
write_installed_version "$TARGET"
switch_current "$TARGET"
write_journal "upgrade-${CURRENT}-to-${TARGET}-$(date -u +%Y%m%dT%H%M%SZ).json"

ok "Upgrade complete: ${CURRENT} -> ${TARGET}"
