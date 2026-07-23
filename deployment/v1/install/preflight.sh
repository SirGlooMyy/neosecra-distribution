#!/usr/bin/env bash
# neosecra preflight — host readiness verification (read-only)
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
V1_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${V1_ROOT}/lib/common.sh"
source "${V1_ROOT}/lib/manifest.sh"

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
chk()   { [[ $# -eq 0 ]] || ok "$1"; }
fail()  { err "$1"; FAILS=$((FAILS+1)); }
warn()  { warn "$1"; WARN=$((WARN+1)); [[ $STRICT -eq 0 ]]; }

log "NeoSecra Assessment preflight — ${VERSION}"

# --- Root check ---
[[ $EUID -eq 0 ]] || warn "Not running as root (install will require sudo)"

# --- OS ---
OS="$(uname -s)"; ARCH="$(uname -m)"
[[ "$OS" == "Linux" ]] && chk "OS: ${OS} ${ARCH}" || warn "OS: ${OS} (Linux recommended)"

# --- CPU/RAM/Disk ---
CORES=$(nproc 2>/dev/null || echo 0)
MEM=$(grep MemTotal /proc/meminfo 2>/dev/null | awk '{printf "%.0f", $2/1048576}' || echo 0)
DISK=$(df /var/lib/docker 2>/dev/null | awk 'NR==2{printf "%.0f", $4/1048576}' || echo 0)
[[ $CORES -ge 2 ]] && chk "CPU: ${CORES} cores" || fail "CPU: ${CORES} (min 2)"
[[ $MEM -ge 4 ]] && chk "RAM: ${MEM} GB" || fail "RAM: ${MEM} GB (min 4)"
[[ $DISK -ge 20 ]] && chk "Disk: ${DISK} GB free" || warn "Disk: ${DISK} GB (min 20 recommended)"

# --- Docker ---
require_compose_v2
DOCKER_VER="$(docker --version 2>/dev/null || echo '?')"
COMPOSE_VER="$(docker compose version 2>/dev/null || echo '?')"
chk "Docker: ${DOCKER_VER}"
chk "Compose: ${COMPOSE_VER}"
docker info >/dev/null 2>&1 || fail "Docker daemon not running"

# --- Package files ---
for f in "$COMPOSE_FILE" "$VERSION_FILE" "$MANIFEST_FILE" "$ENV_EXAMPLE"; do
  [[ -f "$f" ]] && chk "Package file: ${f##*/}" || fail "Missing: ${f##*/}"
done

# --- Version consistency ---
FILE_VER=$(read_version)
MAN_VER=$(manifest_field version)
[[ "$FILE_VER" == "$MAN_VER" ]] && chk "Version consistent: ${FILE_VER}" || fail "Version mismatch: ${FILE_VER} vs ${MAN_VER}"

# --- Compose config ---
if [[ -f "$ENV_FILE" ]]; then
  compose_validate 2>/dev/null && chk "Compose config valid" || fail "Compose config invalid"
else
  warn ".env.v1 not found — compose validation skipped"
fi

# --- Product identity ---
check_product_identity 2>/dev/null || fail "Product identity check failed"

# --- .env ---
if [[ ! -f "$ENV_FILE" ]]; then
  fail ".env.v1 missing — create from .env.v1.example"
else
  chk ".env.v1 present"
  warn_if_placeholders
  for var in POSTGRES_PASSWORD SECRET_KEY OTP_SECRET; do
    val=$(env_value "$var" ""); [[ -n "$val" ]] || warn "${var} not set"
  done
fi

# --- Ports ---
PORT_FAIL=0
for spec in "POSTGRES_PORT:25433" "REDIS_PORT:25639" "BACKEND_PORT:25800" "FRONTEND_PORT:25300"; do
  key="${spec%%:*}"; default="${spec##*:}"
  port="$(env_value "$key" "$default")"
  if port_is_free "$port"; then
    chk "Port ${port} (${key}) free"
  elif port_belongs_to_project "$port" "$COMPOSE_PROJECT"; then
    warn "Port ${port} already bound by this stack"
  else
    fail "Port ${port} (${key}) in use"
    PORT_FAIL=1
  fi
done

# --- Target directory ---
mkdir -p "$INSTALL_ROOT" 2>/dev/null && chk "Target dir writable: ${INSTALL_ROOT}" && rmdir "$INSTALL_ROOT" 2>/dev/null || true

# --- Credentials ---
CRED_FILE="$(ghcr_token_file)"
if [[ -f "$CRED_FILE" ]]; then
  PERMS=$(stat -c '%a' "$CRED_FILE" 2>/dev/null || echo "?")
  [[ "$PERMS" == "600" ]] && chk "GHCR credential: 0600" || warn "GHCR credential perms: ${PERMS} (expected 600)"
else
  warn "GHCR credential not found: ${CRED_FILE}"
fi

# --- GHCR access ---
if [[ $OFFLINE -eq 0 ]] && [[ -f "$CRED_FILE" ]]; then
  set +x
  if cat "$CRED_FILE" | docker login "$GHCR_REGISTRY" --username token --password-stdin 2>/dev/null; then
    chk "GHCR login OK"
    docker logout "$GHCR_REGISTRY" 2>/dev/null || true
  else
    warn "GHCR login failed — check credential"
  fi
fi

# --- Distribution access ---
REL_FILE="$(release_token_file)"
if [[ $OFFLINE -eq 0 ]] && [[ -f "$REL_FILE" ]]; then
  TOKEN=$(cat "$REL_FILE")
  if curl -s -H "Authorization: token $TOKEN" "https://api.github.com/repos/SirGlooMyy/neosecra-distribution" >/dev/null 2>&1; then
    chk "Distribution repo accessible"
  else
    warn "Distribution repo not accessible"
  fi
  unset TOKEN
fi

# --- DNS / Time ---
command -v timedatectl >/dev/null 2>&1 && timedatectl show --property=NTP --value 2>/dev/null | grep -q yes && \
  chk "NTP synchronized" || warn "NTP not synchronized"

echo ""
if [[ $FAILS -eq 0 ]]; then
  ok "Preflight passed (${WARN} warnings)"
  exit 0
else
  err "Preflight FAILED — ${FAILS} error(s), ${WARN} warning(s)"
  exit 1
fi
