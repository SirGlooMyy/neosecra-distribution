#!/usr/bin/env bash
# Shared helpers for the NeoSecra Assessment deployment scripts.
# Sourced by install/upgrade/backup/smoke-tests scripts.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
V1_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# --- Product identity ---
PRODUCT="neosecra-security-health"
EDITION="security-health"
PROJECT="neosecra-assessment"

# --- Install target ---
INSTALL_ROOT="/opt/neosecra/assessment"
RELEASES_DIR="${INSTALL_ROOT}/releases"
SHARED_DIR="${INSTALL_ROOT}/shared"
STATE_DIR="${INSTALL_ROOT}/state"
BACKUP_ROOT="${INSTALL_ROOT}/backups"
JOURNAL_DIR="${INSTALL_ROOT}/upgrade-journal"
CREDENTIAL_DIR="${INSTALL_ROOT}/credentials"
LOG_DIR="${INSTALL_ROOT}/logs"
COMPOSE_PROJECT="${PROJECT}"

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

run_compose() {
  docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" -p "$COMPOSE_PROJECT" "$@"
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

warn_if_placeholders() {
  [[ -f "$ENV_FILE" ]] || return 0
  local count
  count=$(grep -c 'CHANGE_ME' "$ENV_FILE" 2>/dev/null || true)
  [[ "${count:-0}" -gt 0 ]] && warn ".env.v1 still has ${count} CHANGE_ME placeholder(s)"
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
release_lock() { rm -rf "$LOCK_FILE" 2>/dev/null || true; }

# --- Path helpers ---
release_dir() { echo "${RELEASES_DIR}/${1}"; }
current_symlink() { echo "${INSTALL_ROOT}/current"; }
previous_symlink() { echo "${INSTALL_ROOT}/previous"; }

# --- Credential helpers ---
# Auto-detect token files: check /etc/neosecra first, then ~/.neosecra
_cred_path() {
  local name="$1"
  if [[ -f "/etc/neosecra/credentials/${name}" ]]; then
    echo "/etc/neosecra/credentials/${name}"
  elif [[ -f "${HOME}/.neosecra/credentials/${name}" ]]; then
    echo "${HOME}/.neosecra/credentials/${name}"
  elif [[ -f "${CREDENTIAL_DIR}/${name}" ]]; then
    echo "${CREDENTIAL_DIR}/${name}"
  else
    echo "${CREDENTIAL_DIR}/${name}"
  fi
}
ghcr_token_file() { _cred_path "ghcr-read-token"; }
release_token_file() { _cred_path "release-read-token"; }
