#!/usr/bin/env bash
# Shared helpers for the NeoSecra Assessment deployment scripts.
# Sourced by install/upgrade/backup/smoke-tests scripts.
set -Euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
V1_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# --- Product identity ---
PRODUCT="neosecra-security-health"
EDITION="security-health"
PROJECT="neosecra-assessment"
PROJECT_NAME="${PROJECT}"

# --- Install target ---
INSTALL_ROOT="/opt/neosecra/assessment"
RELEASES_DIR="${INSTALL_ROOT}/releases"
SHARED_DIR="${INSTALL_ROOT}/shared"
STATE_DIR="${INSTALL_ROOT}/state"
BACKUP_ROOT="${INSTALL_ROOT}/backups"
JOURNAL_DIR="${INSTALL_ROOT}/upgrade-journal"
CREDENTIAL_DIR="${INSTALL_ROOT}/credentials"
LOG_DIR="${INSTALL_ROOT}/logs"
COMPOSE_PROJECT="${PROJECT_NAME}"

# --- Resolve key paths from V1_ROOT ---
COMPOSE_FILE="${V1_ROOT}/docker-compose.v1.yml"
ENV_FILE="${V1_ROOT}/.env.v1"
ENV_EXAMPLE="${V1_ROOT}/.env.v1.example"
VERSION_FILE="${V1_ROOT}/VERSION"
MANIFEST_FILE="${V1_ROOT}/release-manifest.yaml"

# --- GHCR images ---
GHCR_REGISTRY="ghcr.io"
GHCR_NAMESPACE="sirgloomyy/neosecra-assessment"

# --- Logging ---
if [[ -t 2 ]]; then
  _C_RED=$'\033[31m'; _C_YEL=$'\033[33m'; _C_GRN=$'\033[32m'; _C_DIM=$'\033[2m'; _C_RST=$'\033[0m'
else
  _C_RED=''; _C_YEL=''; _C_GRN=''; _C_DIM=''; _C_RST=''
fi

log()  { printf '%s[info]%s  %s\n'  "$_C_DIM" "$_C_RST" "$*" >&2; }
ok()   { printf '%s[ok]%s    %s\n'  "$_C_GRN" "$_C_RST" "$*" >&2; }
warn() { printf '%s[warn]%s  %s\n'  "$_C_YEL" "$_C_RST" "$*" >&2; }
err()  { printf '%s[error]%s %s\n'  "$_C_RED" "$_C_RST" "$*" >&2; }

die() { err "$1"; exit "${2:-1}"; }

# --- Version ---
read_version() {
  if [[ -f "$VERSION_FILE" ]]; then
    tr -d '[:space:]' < "$VERSION_FILE"
  else
    echo "unknown"
  fi
}

# --- Docker ---
require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1" 2
}

require_compose_v2() {
  require_cmd docker
  docker compose version >/dev/null 2>&1 || \
    die "docker compose v2 plugin not available" 2
}

compose() {
  docker compose \
    --project-name "$PROJECT_NAME" \
    --project-directory "$V1_ROOT" \
    --env-file "$ENV_FILE" \
    -f "$COMPOSE_FILE" \
    "$@"
}

run_compose() {
  compose "$@"
}

stack_is_running() {
  run_compose ps --status running -q 2>/dev/null | grep -q . || return 1
}

port_is_free() {
  local port="$1"
  if command -v ss >/dev/null 2>&1; then
    ! ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[.:]${port}\$" && return 0 || return 1
  elif command -v netstat >/dev/null 2>&1; then
    ! netstat -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[.:]${port}\$" && return 0 || return 1
  fi
  return 0
}

port_belongs_to_project() {
  local port="$1" project="${2:-$COMPOSE_PROJECT}"
  docker ps --format '{{.Names}} {{.Ports}}' 2>/dev/null | \
    awk -v p=":${port}->" -v proj="$project" '$0 ~ p && $1 ~ proj {found=1} END {exit !found}'
}

existing_volumes() {
  docker volume ls -q --filter "name=${COMPOSE_PROJECT}_" 2>/dev/null || true
}

# --- Env ---
env_value() {
  local key="$1" default="${2:-}"
  [[ -f "$ENV_FILE" ]] || { echo "$default"; return; }
  local val
  val=$(grep -E "^${key}=" "$ENV_FILE" 2>/dev/null | tail -n1 | cut -d= -f2- || true)
  echo "${val:-$default}"
}

random_hex() {
  local bytes="$1"
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex "$bytes"
  else
    python3 -c "import secrets; print(secrets.token_hex(${bytes}))"
  fi
}

upsert_env_value() {
  local key="$1" value="$2" tmp
  tmp="$(mktemp)"
  awk -v k="$key" -v v="$value" '
    BEGIN { done=0 }
    $0 ~ "^" k "=" { print k "=" v; done=1; next }
    { print }
    END { if (!done) print k "=" v }
  ' "$ENV_FILE" > "$tmp"
  mv "$tmp" "$ENV_FILE"
  chmod 0600 "$ENV_FILE"
}

ensure_env_value() {
  local key="$1" value="$2" current
  current="$(env_value "$key" "")"
  if [[ -z "$current" ]] || is_placeholder_value "$current"; then
    upsert_env_value "$key" "$value"
  fi
}

ensure_env_secret() {
  local key="$1" bytes="$2" current
  current="$(env_value "$key" "")"
  if [[ -z "$current" ]] || is_placeholder_value "$current"; then
    upsert_env_value "$key" "$(random_hex "$bytes")"
  fi
}

initialize_env_file() {
  local version frontend_port postgres_password backup_path
  version="$(read_version)"

  umask 077
  if [[ -f "$ENV_FILE" ]]; then
    backup_path="${ENV_FILE}.backup-$(date -u +%Y%m%dT%H%M%SZ)"
    cp -a "$ENV_FILE" "$backup_path"
    chmod 0600 "$backup_path" 2>/dev/null || true
    log ".env.v1 backup created: ${backup_path}"
  else
    mkdir -p "$(dirname "$ENV_FILE")"
    : > "$ENV_FILE"
    chmod 0600 "$ENV_FILE"
  fi

  ensure_env_value NEOSECRA_VERSION "$version"
  ensure_env_value POSTGRES_IMAGE "postgres:15.18-alpine3.24"
  ensure_env_value REDIS_IMAGE "redis:7.4.9-alpine3.21"
  ensure_env_value BACKEND_IMAGE "ghcr.io/sirgloomyy/neosecra-assessment/security-health-backend:${version}"
  ensure_env_value WORKER_IMAGE "ghcr.io/sirgloomyy/neosecra-assessment/security-health-backend:${version}"
  ensure_env_value FRONTEND_IMAGE "ghcr.io/sirgloomyy/neosecra-assessment/security-health-frontend:${version}"
  ensure_env_value OPENVAS_IMAGE "immauss/openvas:26.07.12.01"

  ensure_env_value POSTGRES_USER "neosecra"
  ensure_env_secret POSTGRES_PASSWORD 24
  ensure_env_value POSTGRES_DB "neosecra_assessment"
  ensure_env_value REDIS_URL "redis://redis:6379/0"
  ensure_env_secret SECRET_KEY 48
  ensure_env_secret OTP_SECRET 48
  ensure_env_value FIRST_ADMIN_EMAIL "admin@neosecra.local"
  ensure_env_secret FIRST_ADMIN_PASSWORD 24
  ensure_env_secret ADMIN_RECOVERY_KEY 32

  ensure_env_value POSTGRES_PORT "25433"
  ensure_env_value REDIS_PORT "23639"
  ensure_env_value BACKEND_PORT "23800"
  ensure_env_value FRONTEND_PORT "23300"
  ensure_env_value NEOSECRA_EDITION "security_health"
  ensure_env_value VITE_NEOSECRA_EDITION "security-health"
  ensure_env_value ENVIRONMENT "production"

  postgres_password="$(env_value POSTGRES_PASSWORD "")"
  ensure_env_value DATABASE_URL "postgresql+asyncpg://neosecra:${postgres_password}@postgres:5432/neosecra_assessment"
  frontend_port="$(env_value FRONTEND_PORT "23300")"
  ensure_env_value BACKEND_CORS_ORIGINS "http://localhost:${frontend_port},http://127.0.0.1:${frontend_port}"

  ensure_env_value ALGORITHM "HS256"
  ensure_env_value ACCESS_TOKEN_EXPIRE_MINUTES "15"
  ensure_env_value REFRESH_TOKEN_EXPIRE_DAYS "7"
  ensure_env_value UPLOAD_DIR "/app/uploads"
  ensure_env_value REPORT_DIR "/app/reports"
  ensure_env_value DATA_RETENTION_ENABLED "true"
  ensure_env_value DATA_RETENTION_DAYS "365"
  ensure_env_value DATA_RETENTION_FAILED_DAYS "90"

  ensure_env_value NOTIFICATION_ENABLED "false"
  ensure_env_value SMTP_PORT "587"
  ensure_env_value SMTP_USE_TLS "true"
  ensure_env_value SMTP_FROM_ADDRESS "noreply@neosecra.local"
  ensure_env_value SMTP_FROM_NAME "NeoSecra Security Platform"
  ensure_env_value PRODUCT_NAME "NeoSecra"
  ensure_env_value PRODUCT_FULL_NAME "NeoSecra Assessment"
  ensure_env_value DEEPSEEK_API_BASE_URL "https://api.deepseek.com/v1/chat/completions"
  ensure_env_value DEEPSEEK_MODEL "deepseek-chat"

  ensure_env_value OV_USER "admin"
  ensure_env_secret OV_PASSWORD 24
  ensure_env_value OPENVAS_SSH_PORT "23922"
  ensure_env_value OPENVAS_GSAD_PORT "23992"
  ensure_env_value OPENVAS_HOST "openvas"
  ensure_env_value OPENVAS_PORT "22"
  ensure_env_value OPENVAS_USER "gvm"
  ensure_env_secret OPENVAS_PASS 24
  ensure_env_value OPENVAS_GMP_USER "admin"
  ensure_env_secret OPENVAS_GMP_PASS 24
  ensure_env_value OPENVAS_CONFIG_ID "daba56c8-73ec-11df-a475-002264764cea"
  ensure_env_value OPENVAS_MOCK "false"
  ensure_env_value OPENVAS_KNOWN_HOSTS ""

  ok ".env.v1 initialized"
}

warn_if_placeholders() {
  [[ -f "$ENV_FILE" ]] || return 0
  local key value failed=0
  while IFS='=' read -r key value; do
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    if is_placeholder_value "$value"; then
      warn "${key} contains a placeholder value"
      failed=1
    fi
  done < "$ENV_FILE"
  return "$failed"
}

is_placeholder_value() {
  local value="${1:-}" lower
  lower="${value,,}"
  [[ -z "$value" ]] && return 1
  [[ "$lower" == *change_me* ]] && return 0
  [[ "$lower" == *replace_me* ]] && return 0
  [[ "$lower" == "password" ]] && return 0
  [[ "$lower" == "secret" ]] && return 0
  [[ "$lower" == "example" ]] && return 0
  [[ "$value" == \<*\> ]] && return 0
  return 1
}

require_env_value() {
  local key="$1" value
  value="$(env_value "$key" "")"
  [[ -n "$value" ]] || { err "${key} is EMPTY"; return 1; }
  if is_placeholder_value "$value"; then
    err "${key} is PLACEHOLDER"
    return 1
  fi
  return 0
}

validate_image_ref() {
  local key="$1" ref
  ref="$(env_value "$key" "")"
  [[ -n "$ref" ]] || { err "${key} is EMPTY"; return 1; }
  [[ "$ref" != *latest* ]] || { err "${key} must not use latest"; return 1; }
  [[ "$ref" != *'<<'* && "$ref" != *'>>'* ]] || { err "${key} contains an unstamped placeholder"; return 1; }
  if [[ "$ref" != *@sha256:* && "$ref" != *:* ]]; then
    err "${key} must include an exact tag or digest"
    return 1
  fi
  if [[ "$ref" == ghcr.io/* && "$ref" =~ [A-Z] ]]; then
    err "${key} contains uppercase characters in a GHCR image reference"
    return 1
  fi
  return 0
}

validate_env_file() {
  [[ -f "$ENV_FILE" ]] || { err ".env.v1 missing: ${ENV_FILE}"; return 1; }

  local failed=0
  for key in \
    POSTGRES_USER POSTGRES_PASSWORD POSTGRES_DB DATABASE_URL REDIS_URL \
    SECRET_KEY OTP_SECRET FIRST_ADMIN_EMAIL FIRST_ADMIN_PASSWORD ADMIN_RECOVERY_KEY \
    BACKEND_CORS_ORIGINS POSTGRES_PORT REDIS_PORT BACKEND_PORT FRONTEND_PORT \
    NEOSECRA_EDITION VITE_NEOSECRA_EDITION \
    POSTGRES_IMAGE REDIS_IMAGE BACKEND_IMAGE WORKER_IMAGE FRONTEND_IMAGE OPENVAS_IMAGE
  do
    require_env_value "$key" || failed=1
  done

  for key in POSTGRES_IMAGE REDIS_IMAGE BACKEND_IMAGE WORKER_IMAGE FRONTEND_IMAGE OPENVAS_IMAGE; do
    validate_image_ref "$key" || failed=1
  done

  [[ "$(env_value NEOSECRA_EDITION "")" == "security_health" ]] || { err "NEOSECRA_EDITION must be security_health"; failed=1; }
  [[ "$(env_value VITE_NEOSECRA_EDITION "")" == "security-health" ]] || { err "VITE_NEOSECRA_EDITION must be security-health"; failed=1; }

  return "$failed"
}

# --- Lock ---
LOCK_FILE="${STATE_DIR}/.install.lock"
acquire_lock() {
  mkdir -p "$STATE_DIR"
  if ! mkdir "$LOCK_FILE" 2>/dev/null; then
    die "Another install/upgrade is in progress (lock: ${LOCK_FILE})" 5
  fi
  trap 'release_lock' EXIT
}
release_lock() { rmdir "$LOCK_FILE" 2>/dev/null || true; }

# --- Path helpers ---
release_dir() { echo "${RELEASES_DIR}/${1}"; }
current_symlink() { echo "${INSTALL_ROOT}/current"; }
previous_symlink() { echo "${INSTALL_ROOT}/previous"; }
