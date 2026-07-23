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

GHCR_TOKEN="${NEOSECRA_GHCR_TOKEN:-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}"
RELEASE_TOKEN="${NEOSECRA_RELEASE_TOKEN:-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}"
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

# --- Release bundle'indan kur ---
TMP_DIR=$(mktemp -d)
cd "$TMP_DIR"
info "Release indiriliyor..."

# GitHub Release asset'ini indir (online bundle)
RELEASE_API="https://api.github.com/repos/SirGlooMyy/neosecra-assessment/releases/tags/security-health-v${VERSION}"
BUNDLE_NAME="neosecra-security-health-${VERSION}-online.tar.gz"

# Önce GHCR token ile dene, olmazsa token'sız public endpoint
if ! curl -sfL -H "Authorization: token $(cat /etc/neosecra/credentials/ghcr-read-token)" \
  "$RELEASE_API" 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin)
for a in d.get('assets',[]):
    if a['name']=='${BUNDLE_NAME}':
        print(a['browser_download_url'])
" 2>/dev/null | xargs -I{} curl -sfL -o bundle.tar.gz {} 2>/dev/null; then
  # Public fallback
  curl -sfL "https://github.com/SirGlooMyy/neosecra-assessment/releases/download/security-health-v${VERSION}/${BUNDLE_NAME}" -o bundle.tar.gz 2>/dev/null || \
    err "Release bundle indirilemedi"
fi

tar xzf bundle.tar.gz
cd neosecra-security-health-${VERSION}

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
