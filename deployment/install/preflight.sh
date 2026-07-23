#!/usr/bin/env bash
# neosecra preflight — host readiness verification (read-only)
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
V1_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${V1_ROOT}/lib/common.sh"
source "${V1_ROOT}/lib/manifest.sh"
source "${V1_ROOT}/lib/docker.sh"

FAILS=0; WARN=0; STRICT=0; OFFLINE=0

usage() { cat <<'EOF'
neosecra preflight — host readiness verification
Usage: neosecra preflight [--strict] [--offline] [--help]
Read-only. Does not modify the system.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h)    usage; exit 0 ;;
    --strict)     STRICT=1 ;;
    --offline)    OFFLINE=1 ;;
    *) usage; die "unexpected argument: $1" 2 ;;
  esac
  shift
done

VERSION="$(read_version)"
chk()      { [[ $# -eq 0 ]] || ok "$1"; }
chk_fail() { err "$1"; FAILS=$((FAILS+1)); }
chk_warn() { warn "$1"; WARN=$((WARN+1)); [[ $STRICT -eq 0 ]]; }

log "NeoSecra Assessment preflight — ${VERSION}"

# --- Root check ---
[[ $EUID -eq 0 ]] || chk_warn "Not running as root (install will require sudo)"

# --- OS ---
OS="$(uname -s)"; ARCH="$(uname -m)"
[[ "$OS" == "Linux" ]] && chk "OS: ${OS} ${ARCH}" || chk_warn "OS: ${OS} (Linux recommended)"

# --- CPU/RAM/Disk ---
CORES=$(nproc 2>/dev/null || echo 0)
MEM=$(grep MemTotal /proc/meminfo 2>/dev/null | awk '{printf "%.0f", $2/1048576}' || echo 0)
DISK=$(df /var/lib/docker 2>/dev/null | awk 'NR==2{printf "%.0f", $4/1048576}' || echo 0)
[[ $CORES -ge 2 ]] && chk "CPU: ${CORES} cores" || chk_fail "CPU: ${CORES} (min 2)"
[[ $MEM -ge 4 ]] && chk "RAM: ${MEM} GB" || chk_fail "RAM: ${MEM} GB (min 4)"
[[ $DISK -ge 20 ]] && chk "Disk: ${DISK} GB free" || chk_warn "Disk: ${DISK} GB (min 20 recommended)"

# --- Docker ---
require_compose_v2
DOCKER_VER="$(docker --version 2>/dev/null || echo '?')"
COMPOSE_VER="$(docker compose version 2>/dev/null || echo '?')"
chk "Docker: ${DOCKER_VER}"
chk "Compose: ${COMPOSE_VER}"
docker info >/dev/null 2>&1 || chk_fail "Docker daemon unavailable or not accessible to the current user"

# --- Package files ---
for f in "$COMPOSE_FILE" "$VERSION_FILE" "$MANIFEST_FILE" "$ENV_EXAMPLE"; do
  [[ -f "$f" ]] && chk "Package file: ${f##*/}" || chk_fail "Missing: ${f##*/}"
done

# --- Version consistency ---
FILE_VER=$(read_version)
MAN_VER=$(manifest_field version)
[[ "$FILE_VER" == "$MAN_VER" ]] && chk "Version consistent: ${FILE_VER}" || chk_fail "Version mismatch: ${FILE_VER} vs ${MAN_VER}"

# --- Compose config ---
if [[ -f "$ENV_FILE" ]]; then
  compose_validate || chk_fail "Compose config invalid"
else
  chk_fail ".env.v1 missing — create from .env.v1.example"
fi

# --- Product identity ---
check_product_identity || chk_fail "Product identity check failed"

# --- .env ---
if [[ ! -f "$ENV_FILE" ]]; then
  chk_fail ".env.v1 missing — create from .env.v1.example"
else
  chk ".env.v1 present"
  validate_env_file || chk_fail ".env.v1 validation failed"
fi

# --- Ports ---
PORT_FAIL=0
for spec in "POSTGRES_PORT:25433" "REDIS_PORT:23639" "BACKEND_PORT:23800" "FRONTEND_PORT:23300"; do
  key="${spec%%:*}"; default="${spec##*:}"
  port="$(env_value "$key" "$default")"
  if port_is_free "$port"; then
    chk "Port ${port} (${key}) free"
  elif port_belongs_to_project "$port" "$COMPOSE_PROJECT"; then
    chk_warn "Port ${port} already bound by this stack"
  else
    chk_fail "Port ${port} (${key}) in use"
    PORT_FAIL=1
  fi
done

# --- Target directory ---
[[ -w "$(dirname "$INSTALL_ROOT")" ]] && chk "Target parent writable: $(dirname "$INSTALL_ROOT")" || chk_warn "Target parent may require root: $(dirname "$INSTALL_ROOT")"

# --- GHCR access ---
chk_warn "GHCR login is not attempted during preflight; install prompts interactively with --password-stdin"

# --- Distribution access ---
chk_warn "Distribution token checks are skipped during preflight to avoid exposing auth headers"

# --- DNS / Time ---
command -v timedatectl >/dev/null 2>&1 && timedatectl show --property=NTP --value 2>/dev/null | grep -q yes && \
  chk "NTP synchronized" || chk_warn "NTP not synchronized"

echo ""
if [[ $FAILS -eq 0 ]]; then
  ok "Preflight passed (${WARN} warnings)"
  exit 0
else
  err "Preflight FAILED — ${FAILS} error(s), ${WARN} warning(s)"
  exit 1
fi
