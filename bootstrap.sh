#!/usr/bin/env bash
# NeoSecra Assessment — tek komut kurulum
# Kullanım:
#   curl -sL https://raw.githubusercontent.com/SirGlooMyy/neosecra-distribution/main/bootstrap.sh | sudo bash
#
# Gerekli environment değişkenleri (admin tarafından iletilir):
#   NEOSECRA_GHCR_TOKEN veya GHCR_READ_TOKEN
#   NEOSECRA_RELEASE_TOKEN veya RELEASE_READ_TOKEN
#   NEOSECRA_VERSION (default: 1.0.0)
set -Eeuo pipefail

GHCR_TOKEN="${NEOSECRA_GHCR_TOKEN:-${GHCR_READ_TOKEN:-}}"
RELEASE_TOKEN="${NEOSECRA_RELEASE_TOKEN:-${RELEASE_READ_TOKEN:-}}"
VERSION="${NEOSECRA_VERSION:-1.0.0}"

RED='\033[31m'; GRN='\033[32m'; YEL='\033[33m'; RST='\033[0m'
info() { echo -e "${GRN}[neosecra]${RST} $*"; }
warn() { echo -e "${YEL}[neosecra]${RST} $*"; }
err()  { echo -e "${RED}[neosecra]${RST} $*"; exit 1; }

[[ $EUID -eq 0 ]] || err "Root required: sudo bash bootstrap.sh"
[[ -n "$GHCR_TOKEN" ]] || err "NEOSECRA_GHCR_TOKEN (GHCR_READ_TOKEN) required"
[[ -n "$RELEASE_TOKEN" ]] || err "NEOSECRA_RELEASE_TOKEN (RELEASE_READ_TOKEN) required"

info "NeoSecra Assessment v${VERSION} kurulum başlıyor..."

# --- Docker ---
if ! command -v docker &>/dev/null; then
  info "Docker kuruluyor..."
  curl -fsSL https://get.docker.com | sh
fi
command -v docker >/dev/null 2>&1 || err "Docker kurulamadı"

# --- Token'lar ---
mkdir -p /etc/neosecra/credentials
chmod 0700 /etc/neosecra/credentials
echo -n "$GHCR_TOKEN" > /etc/neosecra/credentials/ghcr-read-token
chmod 0600 /etc/neosecra/credentials/ghcr-read-token
echo -n "$RELEASE_TOKEN" > /etc/neosecra/credentials/release-read-token
chmod 0600 /etc/neosecra/credentials/release-read-token
unset GHCR_TOKEN RELEASE_TOKEN
info "Token'lar yerleştirildi"

# --- Repo'yu indir (yalnız deployment) ---
TMP_DIR=$(mktemp -d)
cd "$TMP_DIR"
info "Release indiriliyor..."
git clone --depth 1 --branch release/v1-security-health \
  https://github.com/SirGlooMyy/neosecra-assessment.git . 2>/dev/null || \
  git clone --depth 1 --branch release/v1-security-health \
    https://x-access-token:$(cat /etc/neosecra/credentials/release-read-token)@github.com/SirGlooMyy/neosecra-assessment.git . 2>/dev/null || \
  err "Repo indirilemedi"

cd deployment/v1

# --- .env oluştur ---
cp .env.v1.example .env.v1
PG_PASS=$(python3 -c "import secrets; print(secrets.token_hex(16))")
SECRET_KEY=$(python3 -c "import secrets; print(secrets.token_hex(32))")
OTP_SECRET=$(python3 -c "import secrets; print(secrets.token_hex(32))")
sed -i "s/POSTGRES_PASSWORD=.*/POSTGRES_PASSWORD=${PG_PASS}/" .env.v1
sed -i "s/SECRET_KEY=.*/SECRET_KEY=${SECRET_KEY}/" .env.v1
sed -i "s/OTP_SECRET=.*/OTP_SECRET=${OTP_SECRET}/" .env.v1
info "Güvenlik şifreleri oluşturuldu"

# --- CLI ---
ln -sf "$(pwd)/bin/neosecra" /usr/local/bin/neosecra

# --- Kurulum ---
neosecra install --confirm-backed-up

# --- Temizlik ---
cd / && rm -rf "$TMP_DIR"

info "============================================"
info "NeoSecra Assessment v${VERSION} KURULDU"
info "Web: http://<sunucu-ip>:25300"
info "Yönetim: neosecra <komut>"
info "============================================"
