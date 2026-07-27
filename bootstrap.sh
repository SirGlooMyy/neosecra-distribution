#!/usr/bin/env bash
# NeoSecra Assessment — tek komut kurulum
set -Eeuo pipefail

VERSION=""
FRONTEND_IMAGE_VERSION=""

# ---------------------------------------------------------------------------
# T4 TLS: TLS mode selection
#   NEOSECRA_TLS_MODE=public   (default) — Let's Encrypt, system trust store
#   NEOSECRA_TLS_MODE=internal — Custom CA (embedded below, air-gap / lab)
# ---------------------------------------------------------------------------
NEOSECRA_TLS_MODE="${NEOSECRA_TLS_MODE:-public}"

# ---------------------------------------------------------------------------
# T4 TLS: Embedded CA certificate for update.neosecra.com
# Used only in internal mode (custom CA). In public mode the system trust
# store already validates Let's Encrypt certificates, so no CA install needed.
# ---------------------------------------------------------------------------
NEOSECRA_CA_B64='LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0tCk1JSUIvakNDQVlTZ0F3SUJBZ0lVS3R3SSt1NitkZTN1T1Y3MGpka3dtRWN2N2RNd0NnWUlLb1pJemowRUF3TXcKTGpFWk1CY0dBMVVFQXd3UVRtVnZVMlZqY21FZ1VtOXZkQ0JEUVRFUk1BOEdBMVVFQ2d3SVRtVnZVMlZqY21FdwpIaGNOTWpZd056STNNRGt5TkRFMFdoY05Nell3TnpJME1Ea3lOREUwV2pBdU1Sa3dGd1lEVlFRRERCQk9aVzlUClpXTnlZU0JTYjI5MElFTkJNUkV3RHdZRFZRUUtEQWhPWlc5VFpXTnlZVEIyTUJBR0J5cUdTTTQ5QWdFR0JTdUIKQkFBaUEySUFCT0NUekl2UzY0aW9XaVdmUGVEdXcvRkRqR2VHLzFVWUhaSkM2WGd4WkdVVVgwOFA0M3pheGk4YgpkSlcrNTV0OFp5cVBXSndGUHZUZHFxa3AxQmV1dyt3QW5HSFNzcmljV052OEkzeFh3NHVWeDRydmJzL3JENTFhCjhyNGczZFRRTUtOak1HRXdIUVlEVlIwT0JCWUVGRlkza25JZ0dyZ015eFU3eHk2aUJQM0dVRlpGTUI4R0ExVWQKSXdRWU1CYUFGRlkza25JZ0dyZ015eFU3eHk2aUJQM0dVRlpGTUE4R0ExVWRFd0VCL3dRRk1BTUJBZjh3RGdZRApWUjBQQVFIL0JBUURBZ0VHTUFvR0NDcUdTTTQ5QkFNREEyZ0FNR1VDTUZvbzZKSzg4b3VaM1ZVNWo1RDhwMndCCjlyL08wN25QNGdQd01YdHU1b3cybWpwVmtObWU0SURqOHphMWROSXJxZ0l4QUp5UzgzZDNoV2ZCd3FRa2NHZVoKMTU1NW9pYkg4WHl2S3I4YmtacWIveHV6TzlXY01xOUVIcTEwb2RnM3RrR3JDUT09Ci0tLS0tRU5EIENFUlRJRklDQVRFLS0tLS0K'

install_update_server_ca() {
  local ca_path="/usr/local/share/ca-certificates/update-neosecra-com.crt"
  if [[ -f "$ca_path" ]] && openssl x509 -in "$ca_path" -noout 2>/dev/null; then
    return 0  # Already installed
  fi
  local tmp_ca
  tmp_ca="$(mktemp)"
  printf '%s\n' "$NEOSECRA_CA_B64" | openssl base64 -d -out "$tmp_ca" 2>/dev/null || {
    rm -f "$tmp_ca"
    return 1
  }
  # Install into system trust store
  if [[ -d /usr/local/share/ca-certificates ]]; then
    cp "$tmp_ca" "$ca_path"
    update-ca-certificates 2>/dev/null || true
  elif [[ -d /usr/share/ca-certificates ]]; then
    cp "$tmp_ca" /usr/share/ca-certificates/update-neosecra-com.crt
    update-ca-certificates 2>/dev/null || true
  elif command -v trust &>/dev/null; then
    cp "$tmp_ca" "${ca_path}"
    trust anchor "$tmp_ca" 2>/dev/null || true
  fi
  rm -f "$tmp_ca"
  export CURL_CA_BUNDLE="${ca_path}"
  return 0
}

# Install CA trust early (before any curl calls) — only in internal mode
if [[ "${NEOSECRA_TLS_MODE}" == "internal" ]]; then
  install_update_server_ca || true
fi

# ---------------------------------------------------------------------------
# Channel / version resolution
# ---------------------------------------------------------------------------
CHANNEL_URL="${NEOSECRA_CHANNEL_URL:-https://update.neosecra.com/channels/assessment-stable.json}"
CHANNEL_JSON="$(curl -fsSL "$CHANNEL_URL" 2>/dev/null || echo "")"

resolve_version_from_channel() {
  local json="$1"
  if [[ -z "$json" ]]; then return 1; fi
  if command -v python3 &>/dev/null; then
    python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('current_version',''))" <<< "$json" 2>/dev/null
  elif command -v jq &>/dev/null; then
    jq -r '.current_version // empty' <<< "$json" 2>/dev/null
  else
    printf '%s\n' "$json" | sed -nE 's/.*"current_version"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' | head -n1
  fi
}

VERSION="$(resolve_version_from_channel "$CHANNEL_JSON")"
VERSION="${NEOSECRA_VERSION:-${VERSION:-1.0.9}}"
FRONTEND_IMAGE_VERSION="$VERSION"

# ---------------------------------------------------------------------------
# T5 FIX: Backward-compatible archive URL parser (nested + flat schema)
# ---------------------------------------------------------------------------
resolve_archive_url_from_channel() {
  local json="$1" version="$2"
  if [[ -z "$json" ]]; then return 1; fi
  if command -v python3 &>/dev/null; then
    python3 -c "
import json,sys
d=json.loads(sys.stdin.read())
for r in d.get('releases',[]):
    if r.get('version')==sys.argv[1]:
        a = r.get('archive',{})
        if isinstance(a, dict):
            print(a.get('url','') or '')
        else:
            print(a or r.get('url','') or '')
        break
" "$version" <<< "$json" 2>/dev/null
  elif command -v jq &>/dev/null; then
    jq -r --arg v "$version" '.releases[] | select(.version==$v) | ((.archive | if type=="object" then .url else . end) // .url // empty)' <<< "$json" 2>/dev/null
  else
    local url version_block
    version_block=$(printf '%s\n' "$json" | grep -A10 "\"version\":[[:space:]]*\"$version\"" 2>/dev/null)
    if [[ -n "$version_block" ]]; then
      url=$(printf '%s\n' "$version_block" | grep -A6 '"archive":[[:space:]]*{' | grep '"url"' | sed -nE 's/.*"url"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' | head -n1)
    fi
    if [[ -z "$url" ]]; then
      url=$(printf '%s\n' "$json" | grep -A5 "\"version\":[[:space:]]*\"$version\"" | sed -nE 's/.*"(archive|url)"[[:space:]]*:[[:space:]]*"([^"]+)".*/\2/p' | head -n1)
    fi
    printf '%s' "$url"
  fi
}

DISTRIBUTION_ARCHIVE_URL="${NEOSECRA_DISTRIBUTION_ARCHIVE_URL:-}"
if [[ -z "$DISTRIBUTION_ARCHIVE_URL" ]]; then
  DISTRIBUTION_ARCHIVE_URL="$(resolve_archive_url_from_channel "$CHANNEL_JSON" "$VERSION")"
fi
if [[ -z "$DISTRIBUTION_ARCHIVE_URL" ]]; then
  DISTRIBUTION_ARCHIVE_URL="https://update.neosecra.com/releases/${VERSION}/distribution.tar.gz"
fi
RED='\033[31m'; GRN='\033[32m'; RST='\033[0m'
info() { echo -e "${GRN}[neosecra]${RST} $*"; }
err()  { echo -e "${RED}[neosecra]${RST} $*"; exit 1; }
[[ $EUID -eq 0 ]] || err "Root required"

# ---------------------------------------------------------------------------
# GHCR authentication for customer Docker image pulls
#   NEOSECRA_GHCR_USER      — GitHub robot account username
#   NEOSECRA_GHCR_TOKEN     — GitHub PAT with packages:read scope
# Required for public (customer) installs; used to pull images from ghcr.io
# ---------------------------------------------------------------------------
NEOSECRA_GHCR_USER="${NEOSECRA_GHCR_USER:-}"
NEOSECRA_GHCR_TOKEN="${NEOSECRA_GHCR_TOKEN:-}"

ghcr_login_customer() {
  local user="$1" token="$2"
  local secrets_dir="/opt/neosecra/secrets"
  local docker_cfg="${secrets_dir}/.docker"

  mkdir -p "$secrets_dir"
  chmod 0700 "$secrets_dir"
  mkdir -p "$docker_cfg"
  chmod 0700 "$docker_cfg"

  export DOCKER_CONFIG="$docker_cfg"

  if ! printf '%s' "$token" | docker login ghcr.io \
    --username "$user" \
    --password-stdin 2>/dev/null; then
    err "ghcr.io login failed — token geçersiz veya süresi dolmuş olabilir"
  fi

  # Persist credential reference for subsequent compose pull / docker calls
  cat > "${secrets_dir}/ghcr-auth" <<-EOF
DOCKER_CONFIG=${docker_cfg}
NEOSECRA_GHCR_USER=${user}
EOF
  chmod 0600 "${secrets_dir}/ghcr-auth"
  info "GHCR authentication configured for ${user}"
}

# --- GHCR auth logic ---
if [[ -n "$NEOSECRA_GHCR_USER" && -n "$NEOSECRA_GHCR_TOKEN" ]]; then
  ghcr_login_customer "$NEOSECRA_GHCR_USER" "$NEOSECRA_GHCR_TOKEN"
  unset NEOSECRA_GHCR_TOKEN
elif [[ -z "$NEOSECRA_GHCR_USER" && -z "$NEOSECRA_GHCR_TOKEN" ]]; then
  # Neither set — check if docker already has valid ghcr credentials
  if ! DOCKER_CONFIG="${DOCKER_CONFIG:-$HOME/.docker}" \
    docker manifest inspect "ghcr.io/sirgloomyy/neosecra-assessment/security-health-backend:${VERSION}" >/dev/null 2>&1; then
    err "GHCR robot token gerekli — NeoSecra'dan alınan CUSTOMER-INSTALL paketine bakın"
  fi
  info "GHCR: existing Docker credentials detected"
elif [[ -z "$NEOSECRA_GHCR_USER" ]]; then
  err "NEOSECRA_GHCR_USER gerekli (NEOSECRA_GHCR_TOKEN set edilmişken)"
elif [[ -z "$NEOSECRA_GHCR_TOKEN" ]]; then
  err "NEOSECRA_GHCR_TOKEN gerekli (NEOSECRA_GHCR_USER set edilmişken)"
fi



info "NeoSecra Assessment v${VERSION} kurulum başlıyor..."

# --- Docker ---
if ! command -v docker &>/dev/null; then
  err "Docker is required; install/upgrade Docker before running this bootstrap"
fi
if ! docker compose version &>/dev/null; then
  err "Docker Compose v2 plugin is required"
fi

random_hex() {
  local bytes="$1"
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex "$bytes"
  else
    python3 -c "import secrets; print(secrets.token_hex(${bytes}))"
  fi
}

random_admin_password() {
  local candidate lower
  for _ in $(seq 1 30); do
    candidate="Ns1!$(random_hex 24)"
    lower="${candidate,,}"
    case "$lower" in
      *password*|*123456*|*changeme*|*admin123*|*qwerty*|*letmein*) continue ;;
    esac
    printf '%s' "$candidate"
    return 0
  done
  printf 'Ns1!%s' "$(random_hex 32)"
}

# --- Script'leri kalıcı dizine kopyala ---
BASE="/opt/neosecra/assessment"
RELEASE_DIR="${BASE}/releases/${VERSION}"
CURRENT_RELEASE_DIR=""
if [[ -L "${BASE}/current" ]]; then
  CURRENT_RELEASE_DIR="$(readlink -f "${BASE}/current" 2>/dev/null || true)"
fi

INSTALLED_VERSION=""
if [[ -f "${BASE}/state/installed-version" ]]; then
  INSTALLED_VERSION="$(cat "${BASE}/state/installed-version" 2>/dev/null || true)"
fi

TMP_DIR=$(mktemp -d)
cd "$TMP_DIR"
info "Kurulum paketi indiriliyor: ${DISTRIBUTION_ARCHIVE_URL}"
curl -fsSL -o dist.tar.gz "$DISTRIBUTION_ARCHIVE_URL"
tar xzf dist.tar.gz
DIST_DIR="$(find . -mindepth 1 -maxdepth 1 -type d -name 'neosecra-distribution-*' | head -n1)"
[[ -n "$DIST_DIR" && -d "$DIST_DIR" ]] || err "Kurulum paketi açılırken dağıtım dizini bulunamadı"
cd "$DIST_DIR"

# Kalıcı dizine kopyala
if [[ -d "$RELEASE_DIR" ]]; then
  BACKUP_DIR="${BASE}/backups/preinstall-${VERSION}-$(date -u +%Y%m%dT%H%M%SZ)"
  mkdir -p "$BACKUP_DIR"
  cp -a "$RELEASE_DIR" "${BACKUP_DIR}/release-${VERSION}"
  info "Existing release backed up: ${BACKUP_DIR}/release-${VERSION}"
fi
mkdir -p "$RELEASE_DIR"
rsync -a deployment/ "$RELEASE_DIR/" 2>/dev/null || cp -r deployment/* "$RELEASE_DIR/" 2>/dev/null || err "Script dosyaları kopyalanamadı"
info "Temporary distribution archive left for audit: ${TMP_DIR}"

cd "$RELEASE_DIR"

if [[ -n "$INSTALLED_VERSION" && -n "$CURRENT_RELEASE_DIR" && "$CURRENT_RELEASE_DIR" != "$RELEASE_DIR" && -f "${CURRENT_RELEASE_DIR}/.env.v1" ]]; then
  if [[ -f .env.v1 ]]; then
    cp -a .env.v1 ".env.v1.stale-target-backup-$(date -u +%Y%m%dT%H%M%SZ)"
  fi
  cp -a "${CURRENT_RELEASE_DIR}/.env.v1" .env.v1
  chmod 0600 .env.v1 2>/dev/null || true
  info "Existing current release environment copied into target release"
fi

# --- .env oluştur ---
if [[ ! -f .env.v1 ]]; then
  umask 077
  PG_PASS=$(random_hex 24)
  SECRET_KEY_VALUE=$(random_hex 48)
  OTP_SECRET_VALUE=$(random_hex 48)
  FIRST_ADMIN_PASSWORD_VALUE=$(random_admin_password)
  ADMIN_RECOVERY_KEY_VALUE=$(random_hex 32)
  OPENVAS_PASSWORD_VALUE=$(random_hex 24)
  OPENVAS_GVM_PASSWORD_VALUE=$(random_hex 24)
  OPENVAS_GMP_PASSWORD_VALUE=$(random_hex 24)
  DB_URL="postgresql+asyncpg://neosecra:${PG_PASS}@postgres:5432/neosecra_assessment"

  printf '%s\n' \
    "NEOSECRA_VERSION=${VERSION}" \
    "POSTGRES_IMAGE=postgres:15.18-alpine3.24" \
    "REDIS_IMAGE=redis:7.4.9-alpine3.21" \
    "BACKEND_IMAGE=ghcr.io/sirgloomyy/neosecra-assessment/security-health-backend:${VERSION}" \
    "WORKER_IMAGE=ghcr.io/sirgloomyy/neosecra-assessment/security-health-backend:${VERSION}" \
    "FRONTEND_IMAGE=ghcr.io/sirgloomyy/neosecra-assessment/security-health-frontend:${FRONTEND_IMAGE_VERSION}" \
    "OPENVAS_IMAGE=immauss/openvas:26.07.12.01" \
    "POSTGRES_USER=neosecra" \
    "POSTGRES_PASSWORD=${PG_PASS}" \
    "POSTGRES_DB=neosecra_assessment" \
    "DATABASE_URL=${DB_URL}" \
    "REDIS_URL=redis://redis:6379/0" \
    "SECRET_KEY=${SECRET_KEY_VALUE}" \
    "OTP_SECRET=${OTP_SECRET_VALUE}" \
    "FIRST_ADMIN_EMAIL=admin@neosecra.io" \
    "FIRST_ADMIN_PASSWORD=${FIRST_ADMIN_PASSWORD_VALUE}" \
    "ADMIN_RECOVERY_KEY=${ADMIN_RECOVERY_KEY_VALUE}" \
    "POSTGRES_PORT=25433" \
    "REDIS_PORT=23639" \
    "BACKEND_PORT=23800" \
    "FRONTEND_PORT=23300" \
    "NEOSECRA_EDITION=security_health" \
    "VITE_NEOSECRA_EDITION=security-health" \
    "ENVIRONMENT=production" \
    "BACKEND_CORS_ORIGINS=http://localhost:23300,http://127.0.0.1:23300" \
    "ALGORITHM=HS256" \
    "ACCESS_TOKEN_EXPIRE_MINUTES=15" \
    "REFRESH_TOKEN_EXPIRE_DAYS=7" \
    "UPLOAD_DIR=/app/uploads" \
    "REPORT_DIR=/app/reports" \
    "DATA_RETENTION_ENABLED=true" \
    "DATA_RETENTION_DAYS=365" \
    "DATA_RETENTION_FAILED_DAYS=90" \
    "NOTIFICATION_ENABLED=false" \
    "SMTP_HOST=" \
    "SMTP_PORT=587" \
    "SMTP_USE_TLS=true" \
    "SMTP_USERNAME=" \
    "SMTP_PASSWORD=" \
    "SMTP_FROM_ADDRESS=noreply@neosecra.local" \
    "SMTP_FROM_NAME=NeoSecra Security Platform" \
    "NOTIFICATION_EMAIL_RECIPIENTS=" \
    "PRODUCT_NAME=NeoSecra" \
    "PRODUCT_FULL_NAME=NeoSecra Assessment" \
    "PRODUCT_VENDOR_NAME=" \
    "PRODUCT_WEBSITE=" \
    "PRODUCT_SUPPORT_EMAIL=" \
    "DEEPSEEK_API_KEY=" \
    "DEEPSEEK_API_BASE_URL=https://api.deepseek.com/v1/chat/completions" \
    "DEEPSEEK_MODEL=deepseek-chat" \
    "OV_USER=admin" \
    "OV_PASSWORD=${OPENVAS_PASSWORD_VALUE}" \
    "OPENVAS_SSH_PORT=23922" \
    "OPENVAS_GSAD_PORT=23992" \
    "OPENVAS_HOST=openvas" \
    "OPENVAS_PORT=22" \
    "OPENVAS_USER=gvm" \
    "OPENVAS_PASS=${OPENVAS_GVM_PASSWORD_VALUE}" \
    "OPENVAS_GMP_USER=admin" \
    "OPENVAS_GMP_PASS=${OPENVAS_GMP_PASSWORD_VALUE}" \
    "OPENVAS_CONFIG_ID=daba56c8-73ec-11df-a475-002264764cea" \
    "OPENVAS_MOCK=false" \
    "OPENVAS_KNOWN_HOSTS=" \
    > .env.v1
  chmod 0600 .env.v1

  # Verify the file
  grep -q "DATABASE_URL=.*${PG_PASS}" .env.v1 || {
    echo "FATAL: .env.v1 password mismatch"
    exit 1
  }
fi

# --- CLI ---
mkdir -p /usr/local/bin
chmod 0755 "${RELEASE_DIR}/bin/neosecra"
ln -sf "${RELEASE_DIR}/bin/neosecra" /usr/local/bin/neosecra
chmod 0755 /usr/local/bin/neosecra 2>/dev/null || true

if [[ -n "$INSTALLED_VERSION" ]]; then
  if [[ "$INSTALLED_VERSION" != "$VERSION" ]]; then
    info "Güncelleme uygulanıyor: v${INSTALLED_VERSION} -> v${VERSION}"
    export HOME=/root
    bash "${RELEASE_DIR}/upgrade/upgrade.sh" "$VERSION"
    info "NeoSecra Assessment v${VERSION} güncellemesi tamamlandı"
    exit 0
  fi

  info "Zaten kurulu: v${INSTALLED_VERSION}. Release ve CLI onarımı uygulanıyor..."
  export HOME=/root
  (
    cd "$RELEASE_DIR"
    source "${RELEASE_DIR}/lib/common.sh"
    source "${RELEASE_DIR}/lib/manifest.sh"
    source "${RELEASE_DIR}/lib/docker.sh"
    source "${RELEASE_DIR}/lib/state.sh"

    initialize_env_file
    validate_env_file || die ".env.v1 validation failed" 2
    check_product_identity
    compose_validate

    if [[ "${NEOSECRA_ROTATE_INITIAL_ADMIN:-0}" == "1" ]]; then
      rotate_initial_admin_password
      validate_env_file || die ".env.v1 validation failed after admin rotation" 2
    fi

    if stack_is_running; then
      run_compose up -d postgres redis
      wait_service_healthy postgres 90
      wait_service_healthy redis 90
      reconcile_postgres_password
      ensure_assessment_schema_compatibility || die "Assessment schema compatibility repair failed" 11
      sync_initial_admin_credentials || die "Initial admin credential synchronization failed" 11
      if ! run_compose up -d --force-recreate backend worker frontend; then
        print_service_diagnostics backend worker frontend
        die "Application services failed to restart after repair" 13
      fi
      wait_service_healthy backend 120
      wait_service_running worker 60
      wait_service_running frontend 60
      wait_frontend_http 120 || { print_service_diagnostics frontend; die "Frontend HTTP not reachable within 120s" 13; }
      wait_frontend_api_proxy 120 || { print_service_diagnostics frontend backend; die "Frontend API proxy not reachable within 120s" 13; }
      verify_initial_admin_login_via_frontend || { print_service_diagnostics frontend backend; die "Initial admin login verification failed" 13; }
      bash "${RELEASE_DIR}/install/postflight.sh" --timeout 120
    else
      warn "Stack is not running; database credential sync skipped"
    fi
  )
  ln -sfn "$RELEASE_DIR" "${BASE}/current"
  info "NeoSecra Assessment v${INSTALLED_VERSION} release/CLI onarımı tamamlandı"
  exit 0
fi

# --- Kurulum ---
export HOME=/root
bash "${RELEASE_DIR}/install/install.sh" --confirm-backed-up

info "============================================"
info "NeoSecra Assessment v${VERSION} KURULDU"
info "Web: http://<sunucu-ip>:23300"
info "Yönetim: neosecra <komut>"
info "============================================"
