#!/usr/bin/env bash
# NeoSecra Assessment — tek komut kurulum
# Kullanım: curl -sL https://raw.githubusercontent.com/SirGlooMyy/neosecra-distribution/main/bootstrap.sh | sudo bash
set -Eeuo pipefail

GHCR_TOKEN="${NEOSECRA_GHCR_TOKEN:-}"
VERSION="1.0.0"

RED='\033[31m'; GRN='\033[32m'; RST='\033[0m'
info() { echo -e "${GRN}[neosecra]${RST} $*"; }
err()  { echo -e "${RED}[neosecra]${RST} $*"; exit 1; }

[[ $EUID -eq 0 ]] || err "Root required: sudo bash bootstrap.sh"

info "NeoSecra Assessment v${VERSION} kurulum başlıyor..."

# --- Docker ---
if ! command -v docker &>/dev/null; then
  info "Docker kuruluyor..."
  curl -fsSL https://get.docker.com | sh
fi

# --- GHCR token ---
mkdir -p /etc/neosecra/credentials && chmod 0700 /etc/neosecra/credentials
echo -n "$GHCR_TOKEN" > /etc/neosecra/credentials/ghcr-read-token
chmod 0600 /etc/neosecra/credentials/ghcr-read-token
unset GHCR_TOKEN

# --- Deployment scripts ---
TMP_DIR=$(mktemp -d); cd "$TMP_DIR"
info "Kurulum paketi indiriliyor..."
curl -sL "https://github.com/SirGlooMyy/neosecra-distribution/archive/main.tar.gz" | tar xz
cd neosecra-distribution-main/deployment/v1

# --- .env oluştur ---
cp .env.v1.example .env.v1
PG_PASS=$(python3 -c "import secrets; print(secrets.token_hex(16))")
SECRET_KEY=$(python3 -c "import secrets; print(secrets.token_hex(32))")
OTP_SECRET=$(python3 -c "import secrets; print(secrets.token_hex(32))")
sed -i "s/POSTGRES_PASSWORD=.*/POSTGRES_PASSWORD=${PG_PASS}/" .env.v1
sed -i "s/SECRET_KEY=.*/SECRET_KEY=${SECRET_KEY}/" .env.v1
sed -i "s/OTP_SECRET=.*/OTP_SECRET=${OTP_SECRET}/" .env.v1

# --- CLI ---
ln -sf "$(pwd)/bin/neosecra" /usr/local/bin/neosecra

# --- Kur ---
neosecra install --confirm-backed-up

# --- Temizlik ---
cd / && rm -rf "$TMP_DIR"

info "============================================"
info "NeoSecra Assessment v${VERSION} KURULDU"
info "Web: http://<sunucu-ip>:25300"
info "Yönetim: neosecra <komut>"
info "============================================"
