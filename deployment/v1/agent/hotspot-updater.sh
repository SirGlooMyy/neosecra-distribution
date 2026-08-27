#!/usr/bin/env bash
# Host-side updater for the NeoSecra Hotspot Compose distribution.
#
# The distribution update-agent verifies the channel/archive signature before
# invoking this script. This script owns the Hotspot-specific transaction:
# database backup, staged Compose build/migration, health gate, atomic current
# symlink switch, and rollback on failure.
set -Eeuo pipefail

TARGET=""
ARCHIVE=""
ROLLBACK=0
BACKUP_SOURCE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --target) shift; TARGET="${1:-}" ;;
    --archive) shift; ARCHIVE="${1:-}" ;;
    --backup) shift; BACKUP_SOURCE="${1:-}" ;;
    --rollback) ROLLBACK=1 ;;
    --help|-h)
      cat <<'EOF'
Usage: hotspot-updater.sh --target <semver> [--archive <tar.gz>]
       hotspot-updater.sh --rollback --target <semver> [--backup <dir>]
EOF
      exit 0
      ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

[[ "$TARGET" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Invalid target version" >&2; exit 2; }

ROOT="${NEOSECRA_INSTALL_ROOT:-/opt/neosecra/hotspot}"
CURRENT_LINK="${ROOT}/current"
RELEASES_DIR="${ROOT}/releases"
STATE_DIR="${ROOT}/state"
BACKUPS_DIR="${ROOT}/backups"
JOURNAL_DIR="${ROOT}/upgrade-journal"
COMPOSE_PROJECT="${NEOSECRA_COMPOSE_PROJECT:-neosecra-hotspot}"
API_PORT="${HOTSPOT_API_PORT:-38001}"

mkdir -p "$RELEASES_DIR" "$STATE_DIR" "$BACKUPS_DIR" "$JOURNAL_DIR"
LOCK_DIR="${STATE_DIR}/.hotspot-upgrade.lock"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  echo "Another Hotspot update is already running" >&2
  exit 5
fi
cleanup() { rmdir "$LOCK_DIR" 2>/dev/null || true; }
trap cleanup EXIT

current_tree() {
  readlink -f "$CURRENT_LINK" 2>/dev/null || true
}

current_version() {
  local value=""
  [[ -f "${STATE_DIR}/installed-version" ]] && value="$(tr -d '[:space:]' < "${STATE_DIR}/installed-version")"
  [[ -n "$value" ]] || { [[ -f "${CURRENT_LINK}/VERSION" ]] && value="$(tr -d '[:space:]' < "${CURRENT_LINK}/VERSION")"; }
  printf '%s' "${value:-unknown}"
}

env_value() {
  local file="$1" key="$2" value
  [[ -f "$file" ]] || return 0
  value="$(awk -F= -v k="$key" '$1 == k {sub(/^[^=]*=/, ""); print; exit}' "$file" 2>/dev/null || true)"
  printf '%s' "${value%$'\r'}"
}

compose_file() { printf '%s/docker-compose.yml' "$1"; }
compose_env() { printf '%s/backend/.env' "$1"; }
run_compose() {
  local tree="$1" env_file="$2"
  shift 2
  [[ -f "$(compose_file "$tree")" ]] || { echo "Compose file missing: $(compose_file "$tree")" >&2; return 1; }
  [[ -f "$env_file" ]] || { echo "Hotspot environment missing: $env_file" >&2; return 1; }
  docker compose --project-name "$COMPOSE_PROJECT" --project-directory "$tree" \
    --env-file "$env_file" -f "$(compose_file "$tree")" "$@"
}

wait_api() {
  local i
  for i in $(seq 1 60); do
    # Hotspot exposes its deep service probe at /health (the /api/v1 router
    # intentionally contains only versioned application endpoints).
    if curl -fsS --max-time 25 "http://127.0.0.1:${API_PORT}/health" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  return 1
}

write_journal() {
  local status="$1" from="$2" backup="$3" error="${4:-}"
  cat > "${JOURNAL_DIR}/upgrade-${from}-to-${TARGET}-$(date -u +%Y%m%dT%H%M%SZ).json" <<EOF
{
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "product": "hotspot",
  "product_code": "hotspot",
  "edition": "${NEOSECRA_EDITION_ID:-standard}",
  "previous_version": "${from}",
  "target_version": "${TARGET}",
  "status": "${status}",
  "backup_path": "${backup}",
  "error": "${error}"
}
EOF
}

backup_database() {
  local tree="$1" env_file="$2" from="$3" stamp backup_dir pg_user pg_db dump
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  backup_dir="${BACKUPS_DIR}/${stamp}-${from}"
  mkdir -p "$backup_dir"
  pg_user="$(env_value "$env_file" POSTGRES_USER)"; pg_user="${pg_user:-hotspot}"
  pg_db="$(env_value "$env_file" POSTGRES_DB)"; pg_db="${pg_db:-hotspot}"
  dump="${backup_dir}/hotspot-${from}-db.sql"
  run_compose "$tree" "$env_file" exec -T postgres pg_dump --no-owner --clean --if-exists -U "$pg_user" -d "$pg_db" > "$dump"
  [[ -s "$dump" ]] || { echo "Database backup is empty" >&2; return 1; }
  sha256sum "$dump" > "${dump}.sha256"
  printf '%s' "$backup_dir"
}

extract_release() {
  local archive="$1" staging="$2" tmp payload
  [[ -s "$archive" ]] || { echo "Signed Hotspot archive is required" >&2; return 1; }
  tmp="$(mktemp -d "${STATE_DIR}/.extract.XXXXXX")"
  tar -xzf "$archive" -C "$tmp"
  payload="$(find "$tmp" -type f -name docker-compose.yml -print -quit | xargs -r dirname)"
  [[ -n "$payload" && -f "${payload}/backend/.env.example" ]] || {
    echo "Archive does not contain a Hotspot Compose release" >&2
    rm -rf "$tmp"
    return 1
  }
  mkdir -p "$staging"
  cp -a "${payload}/." "$staging/"
  rm -rf "$tmp"
}

preserve_install_config() {
  local old_tree="$1" staging="$2" old_env="${old_tree}/backend/.env"
  mkdir -p "${staging}/backend"
  if [[ -f "$old_env" ]]; then
    cp -a "$old_env" "${staging}/backend/.env"
    chmod 0600 "${staging}/backend/.env" 2>/dev/null || true
  elif [[ ! -f "${staging}/backend/.env" ]]; then
    echo "Existing Hotspot backend/.env not found" >&2
    return 1
  fi
  if [[ -d "${old_tree}/deploy/ca" && ! -d "${staging}/deploy/ca" ]]; then
    mkdir -p "${staging}/deploy"
    cp -a "${old_tree}/deploy/ca" "${staging}/deploy/ca"
  fi
}

restore_database() {
  local tree="$1" env_file="$2" backup_dir="$3" pg_user pg_db dump
  [[ -d "$backup_dir" ]] || return 0
  dump="$(find "$backup_dir" -maxdepth 1 -type f -name '*-db.sql' -print -quit)"
  [[ -s "$dump" ]] || return 0
  pg_user="$(env_value "$env_file" POSTGRES_USER)"; pg_user="${pg_user:-hotspot}"
  pg_db="$(env_value "$env_file" POSTGRES_DB)"; pg_db="${pg_db:-hotspot}"
  run_compose "$tree" "$env_file" up -d postgres
  run_compose "$tree" "$env_file" exec -T postgres psql -v ON_ERROR_STOP=1 -U "$pg_user" -d "$pg_db" < "$dump"
}

rollback_to() {
  local target_tree="${RELEASES_DIR}/${TARGET}" old_tree old_env backup_dir from
  [[ -d "$target_tree" ]] || { echo "Rollback release missing: $target_tree" >&2; return 1; }
  old_tree="$(current_tree)"
  from="$(current_version)"
  old_env="$(compose_env "$old_tree")"
  [[ -n "$BACKUP_SOURCE" ]] || BACKUP_SOURCE="$(find "$BACKUPS_DIR" -mindepth 1 -maxdepth 1 -type d -name "*-${TARGET}" -print | sort | tail -n1)"
  backup_dir="$BACKUP_SOURCE"
  run_compose "$old_tree" "$old_env" down --remove-orphans || true
  if [[ -n "$backup_dir" ]]; then restore_database "$old_tree" "$old_env" "$backup_dir" || true; fi
  run_compose "$target_tree" "$(compose_env "$target_tree")" up -d --remove-orphans
  wait_api || { echo "Rollback health check failed" >&2; return 1; }
  ln -sfn "$target_tree" "$CURRENT_LINK"
  printf '%s\n' "$TARGET" > "${STATE_DIR}/installed-version"
  write_journal "ROLLED_BACK" "$from" "$backup_dir"
}

apply_update() {
  local old_tree from backup_dir staging
  old_tree="$(current_tree)"
  [[ -n "$old_tree" && -f "$(compose_file "$old_tree")" ]] || { echo "Hotspot current release is not installed" >&2; return 1; }
  from="$(current_version)"
  [[ "$TARGET" != "$from" ]] || { echo "Hotspot is already on ${TARGET}" >&2; return 1; }
  backup_dir="$(backup_database "$old_tree" "$(compose_env "$old_tree")" "$from")"
  staging="${RELEASES_DIR}/.staging-${TARGET}-$$"
  rm -rf "$staging"
  extract_release "$ARCHIVE" "$staging"
  preserve_install_config "$old_tree" "$staging"
  printf '%s\n' "$TARGET" > "${staging}/VERSION"
  run_compose "$staging" "$(compose_env "$staging")" config >/dev/null
  run_compose "$staging" "$(compose_env "$staging")" build api worker beat migrate admin portal
  run_compose "$staging" "$(compose_env "$staging")" up -d postgres redis clickhouse minio createbuckets
  run_compose "$staging" "$(compose_env "$staging")" run --rm migrate
  run_compose "$staging" "$(compose_env "$staging")" up -d --remove-orphans api worker beat admin portal
  if ! wait_api; then
    echo "Hotspot health check failed; restoring previous release" >&2
    run_compose "$staging" "$(compose_env "$staging")" down --remove-orphans || true
    # The staging project uses the same service names and therefore replaces
    # the old containers. Bring the previous PostgreSQL back before restoring
    # its dump, then start the old application tree and re-check its health.
    run_compose "$old_tree" "$(compose_env "$old_tree")" up -d postgres redis clickhouse minio createbuckets || true
    restore_database "$old_tree" "$(compose_env "$old_tree")" "$backup_dir" || true
    run_compose "$old_tree" "$(compose_env "$old_tree")" up -d --remove-orphans api worker beat admin portal || true
    wait_api || true
    rm -rf "$staging"
    write_journal "FAILED" "$from" "$backup_dir" "HEALTH_CHECK_FAILED"
    return 1
  fi
  mv "$staging" "${RELEASES_DIR}/${TARGET}"
  ln -sfn "${RELEASES_DIR}/${TARGET}" "$CURRENT_LINK"
  printf '%s\n' "$TARGET" > "${STATE_DIR}/installed-version"
  write_journal "COMPLETED" "$from" "$backup_dir"
}

if (( ROLLBACK )); then
  rollback_to
else
  apply_update
fi
