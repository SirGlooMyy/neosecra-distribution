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

# --- Preflight ---
set +e; bash "${V1_ROOT}/install/preflight.sh"; PREFLIGHT_RC=$?; set -e
[[ $PREFLIGHT_RC -eq 0 ]] && ok "Preflight passed" || warn "Preflight had warnings (continuing)"

[[ $DRY_RUN -eq 1 ]] && { ok "Dry-run complete"; exit 0; }

# --- Check .env ---
[[ -f "$ENV_FILE" ]] || die ".env.v1 missing — create from .env.v1.example" 2

# --- Create install directories ---
create_install_dirs

# --- Product identity ---
check_product_identity

# --- GHCR login + pull ---
VERSION="$INSTALL_VERSION"
ghcr_pull "security-health-backend" "$VERSION"
ghcr_pull "security-health-frontend" "$VERSION"

# --- Start stack ---
log "Starting stack (docker compose up -d)..."
run_compose up -d

# --- Wait for database ---
log "Waiting for PostgreSQL..."
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
log "Running database migrations..."
for _ in 1 2 3; do
  run_compose exec -T backend alembic upgrade head 2>&1 && { ok "Migrations applied"; break; } || sleep 3
done

# --- Health ---
bash "${V1_ROOT}/install/postflight.sh" --timeout 90

# --- State ---
write_installed_version "$INSTALL_VERSION"
create_release_dir "$INSTALL_VERSION"
switch_current "$INSTALL_VERSION"
write_journal "install-${INSTALL_VERSION}-$(date -u +%Y%m%dT%H%M%SZ).json"

echo ""
ok "NeoSecra Assessment v${INSTALL_VERSION} installed"
log "Access: http://<host>:$(env_value FRONTEND_PORT 25300)"
log "Manage: neosecra <command>"
