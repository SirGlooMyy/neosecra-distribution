#!/usr/bin/env bash
# NeoSecra Assessment — tek komut kurulum
set -Eeuo pipefail

GHCR_TOKEN="${GHCR_TOKEN:-${NEOSECRA_GHCR_TOKEN:-}}"
VERSION="1.0.0"

RED='\033[31m'; GRN='\033[32m'; RST='\033[0m'
info() { echo -e "${GRN}[neosecra]${RST} $*"; }
err()  { echo -e "${RED}[neosecra]${RST} $*"; exit 1; }
[[ $EUID -eq 0 ]] || err "Root required"

info "NeoSecra Assessment v${VERSION} kurulum başlıyor..."

# --- Docker ---
if ! command -v docker &>/dev/null; then
  info "Docker kuruluyor..."
  curl -fsSL https://get.docker.com | sh
fi

# --- Token ---
if [[ -n "$GHCR_TOKEN" ]]; then
  mkdir -p /etc/neosecra/credentials && chmod 0700 /etc/neosecra/credentials
  echo -n "$GHCR_TOKEN" > /etc/neosecra/credentials/ghcr-read-token
  chmod 0600 /etc/neosecra/credentials/ghcr-read-token
fi

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
curl -sL "https://github.com/SirGlooMyy/neosecra-distribution/archive/main.tar.gz" | tar xz
cd neosecra-distribution-main

# Kalıcı dizine kopyala
mkdir -p "$RELEASE_DIR"
cp -r deployment/v1/* "$RELEASE_DIR/"
ln -sfn "$RELEASE_DIR" "${BASE}/current"
rm -rf "$TMP_DIR"

cd "$RELEASE_DIR"

# --- .env oluştur ---
if [[ ! -f .env.v1 ]]; then
  cp .env.v1.example .env.v1
  PG_PASS=$(python3 -c "import secrets; print(secrets.token_hex(16))")
  SECRET_KEY=$(python3 -c "import secrets; print(secrets.token_hex(32))")
  OTP_SECRET=$(python3 -c "import secrets; print(secrets.token_hex(32))")
  sed -i "s/POSTGRES_PASSWORD=.*/POSTGRES_PASSWORD=${PG_PASS}/" .env.v1
  sed -i "s/SECRET_KEY=.*/SECRET_KEY=${SECRET_KEY}/" .env.v1
  sed -i "s/OTP_SECRET=.*/OTP_SECRET=${OTP_SECRET}/" .env.v1
fi

# --- CLI ---
mkdir -p /usr/local/bin
ln -sf "${RELEASE_DIR}/bin/neosecra" /usr/local/bin/neosecra

# --- Kurulum ---
export HOME=/root
bash "${RELEASE_DIR}/install/install.sh" --confirm-backed-up

info "============================================"
info "NeoSecra Assessment v${VERSION} KURULDU"
info "Web: http://<sunucu-ip>:25300"
info "Yönetim: neosecra <komut>"
info "============================================"
