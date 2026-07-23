#!/usr/bin/env bash
# neosecra install — internal pilot installation
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
V1_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${V1_ROOT}/lib/common.sh"
source "${V1_ROOT}/lib/manifest.sh"
source "${V1_ROOT}/lib/docker.sh"
source "${V1_ROOT}/lib/state.sh"

INSTALL_VERSION="$(read_version)"
INSTALL_PHASE="init"

usage() {
  cat <<EOF
neosecra install — install NeoSecra Assessment

Usage:
  neosecra install --confirm-backed-up [options]

Options:
  --confirm-backed-up   Acknowledge backup requirement
  --dry-run             Preflight + validation only
  --help                Show this help
EOF
}

CONFIRM=0; DRY_RUN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h)            usage; exit 0 ;;
    --confirm-backed-up)  CONFIRM=1 ;;
    --dry-run)            DRY_RUN=1 ;;
    *) usage; die "unexpected argument: $1" 2 ;;
  esac
  shift
done

log "NeoSecra Assessment install — version ${INSTALL_VERSION}"

# --- Already installed check ---
if is_installed; then
  local_ver=$(read_installed_version)
  warn "Already installed (version ${local_ver}). Use upgrade for version changes."
  exit 0
fi

[[ $CONFIRM -eq 1 ]] || die "Install requires --confirm-backed-up" 1

# --- Lock ---
acquire_lock
write_install_state "$INSTALL_VERSION" "$INSTALL_PHASE" "started"
trap 'rc=$?; if [[ $rc -ne 0 ]]; then write_install_state "$INSTALL_VERSION" "$INSTALL_PHASE" "failed"; fi; release_lock' EXIT

# --- Environment initialization ---
INSTALL_PHASE="env-init"
initialize_env_file
validate_env_file || die ".env.v1 validation failed" 2

# --- Preflight ---
INSTALL_PHASE="preflight"
bash "${V1_ROOT}/install/preflight.sh" || die "Preflight failed" 10
ok "Preflight passed"

[[ $DRY_RUN -eq 1 ]] && { ok "Dry-run complete"; exit 0; }

# --- Create install directories ---
INSTALL_PHASE="prepare"
create_install_dirs

# --- Product identity ---
check_product_identity

# --- Compose validation ---
INSTALL_PHASE="compose-validate"
compose_validate || die "Compose config invalid" 2

# --- GHCR login + pull ---
INSTALL_PHASE="pull"
ghcr_login
for service in postgres redis backend worker frontend; do
  pull_service_image "$service"
done

# --- Start dependencies ---
INSTALL_PHASE="dependencies"
log "Starting PostgreSQL and Redis..."
run_compose up -d postgres redis
wait_service_healthy postgres 90
wait_service_healthy redis 90
reconcile_postgres_password

# --- Verify database readiness ---
DB_OK=0
PGUSER="$(env_value POSTGRES_USER neosecra)"
PGDB="$(env_value POSTGRES_DB neosecra_assessment)"
for _ in $(seq 1 30); do
  if run_compose exec -T postgres pg_isready -U "$PGUSER" -d "$PGDB" >/dev/null 2>&1; then
    DB_OK=1; ok "PostgreSQL ready"; break
  fi
  sleep 2
done
[[ $DB_OK -eq 1 ]] || die "PostgreSQL not ready within 60s" 1

# --- Migrate ---
INSTALL_PHASE="migrate"
log "Running database migrations..."
MIGRATE_OK=0
for _ in 1 2 3; do
  run_compose run --rm backend alembic upgrade head && { MIGRATE_OK=1; ok "Migrations applied"; break; }
  sleep 3
done
[[ $MIGRATE_OK -eq 1 ]] || die "Database migrations failed" 11

# --- Start application services ---
INSTALL_PHASE="application"
log "Starting backend, worker, and frontend..."
run_compose up -d backend worker frontend

# --- Health ---
INSTALL_PHASE="verify"
bash "${V1_ROOT}/install/postflight.sh" --timeout 90

# --- State ---
INSTALL_PHASE="state"
write_installed_version "$INSTALL_VERSION"
create_release_dir "$INSTALL_VERSION"
switch_current "$INSTALL_VERSION"
write_journal "install-${INSTALL_VERSION}-$(date -u +%Y%m%dT%H%M%SZ).json"
write_install_state "$INSTALL_VERSION" "complete" "ok"

echo ""
ok "NeoSecra Assessment v${INSTALL_VERSION} installed"
log "Access: http://<host>:$(env_value FRONTEND_PORT 23300)"
log "Manage: neosecra <command>"
