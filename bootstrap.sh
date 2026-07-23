#!/usr/bin/env bash
# NeoSecra Assessment — tek komut kurulum
set -Eeuo pipefail

VERSION="1.0.0"

RED='\033[31m'; GRN='\033[32m'; RST='\033[0m'
info() { echo -e "${GRN}[neosecra]${RST} $*"; }
err()  { echo -e "${RED}[neosecra]${RST} $*"; exit 1; }
[[ $EUID -eq 0 ]] || err "Root required"

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

# --- Script'leri kalıcı dizine kopyala ---
BASE="/opt/neosecra/assessment"
RELEASE_DIR="${BASE}/releases/${VERSION}"

# Önce mevcut kurulum kontrolü
if [[ -f "${BASE}/state/installed-version" ]]; then
  INSTALLED=$(cat "${BASE}/state/installed-version")
  info "Zaten kurulu: v${INSTALLED}. Upgrade için: neosecra upgrade <version>"
  exit 0
fi

TMP_DIR=$(mktemp -d)
cd "$TMP_DIR"
info "Kurulum paketi indiriliyor..."
curl -sL -o dist.tar.gz "https://github.com/SirGlooMyy/neosecra-distribution/archive/main.tar.gz"
tar xzf dist.tar.gz
cd neosecra-distribution-main

# Kalıcı dizine kopyala
if [[ -d "$RELEASE_DIR" ]]; then
  BACKUP_DIR="${BASE}/backups/preinstall-${VERSION}-$(date -u +%Y%m%dT%H%M%SZ)"
  mkdir -p "$BACKUP_DIR"
  cp -a "$RELEASE_DIR" "${BACKUP_DIR}/release-${VERSION}"
  info "Existing release backed up: ${BACKUP_DIR}/release-${VERSION}"
fi
mkdir -p "$RELEASE_DIR"
rsync -a deployment/ "$RELEASE_DIR/" 2>/dev/null || cp -r deployment/* "$RELEASE_DIR/" 2>/dev/null || err "Script dosyaları kopyalanamadı"
ln -sfn "$RELEASE_DIR" "${BASE}/current"
info "Temporary distribution archive left for audit: ${TMP_DIR}"

cd "$RELEASE_DIR"

# --- .env oluştur ---
if [[ ! -f .env.v1 ]]; then
  umask 077
  PG_PASS=$(random_hex 24)
  SECRET_KEY_VALUE=$(random_hex 48)
  OTP_SECRET_VALUE=$(random_hex 48)
  FIRST_ADMIN_PASSWORD_VALUE=$(random_hex 24)
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
    "FRONTEND_IMAGE=ghcr.io/sirgloomyy/neosecra-assessment/security-health-frontend:${VERSION}" \
    "OPENVAS_IMAGE=immauss/openvas:26.07.12.01" \
    "POSTGRES_USER=neosecra" \
    "POSTGRES_PASSWORD=${PG_PASS}" \
    "POSTGRES_DB=neosecra_assessment" \
    "DATABASE_URL=${DB_URL}" \
    "REDIS_URL=redis://redis:6379/0" \
    "SECRET_KEY=${SECRET_KEY_VALUE}" \
    "OTP_SECRET=${OTP_SECRET_VALUE}" \
    "FIRST_ADMIN_EMAIL=admin@neosecra.local" \
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
ln -sf "${RELEASE_DIR}/bin/neosecra" /usr/local/bin/neosecra

# --- Kurulum ---
export HOME=/root
bash "${RELEASE_DIR}/install/install.sh" --confirm-backed-up

info "============================================"
info "NeoSecra Assessment v${VERSION} KURULDU"
info "Web: http://<sunucu-ip>:23300"
info "Yönetim: neosecra <komut>"
info "============================================"
