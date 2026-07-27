#!/usr/bin/env bash
# NeoSecra Customer Package Builder
# Packages customer delivery artifacts into a single tarball with SHA256 manifest.
set -Eeuo pipefail

# ---------------------------------------------------------------------------
# Constants & defaults
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DEFAULT_OUTPUT="${REPO_ROOT}/dist"
STAMP="$(date -u +%Y%m%d)"

# Color helpers (stderr only)
if [[ -t 2 ]]; then
  _CR=$'\033[31m'; _CY=$'\033[33m'; _CG=$'\033[32m'; _CD=$'\033[2m'; _CN=$'\033[0m'
else
  _CR=''; _CY=''; _CG=''; _CD=''; _CN=''
fi
log()  { printf '%s[info]%s  %s\n'  "$_CD" "$_CN" "$*" >&2; }
ok()   { printf '%s[ok]%s    %s\n'  "$_CG" "$_CN" "$*" >&2; }
warn() { printf '%s[warn]%s  %s\n'  "$_CY" "$_CN" "$*" >&2; }
err()  { printf '%s[error]%s %s\n'  "$_CR" "$_CN" "$*" >&2; }
die()  { err "$1"; exit "${2:-1}"; }

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
  cat >&2 <<EOF
Usage: $(basename "$0") --customer <name> --envelope <path> --token-file <path> [--output <dir>]

Required:
  --customer <name>     Müşteri kısa adı (ör: acme-ltd, beta-corp)
  --envelope <path>     Lisans envelope JSON dosyası
  --token-file <path>   GHCR read-only robot token dosyası

Optional:
  --output <dir>        Çıktı dizini (varsayılan: ${DEFAULT_OUTPUT})

Output:
  <output>/neosecra-customer-<customer>-<YYYYMMDD>.tar.gz      Paket
  <output>/neosecra-customer-<customer>-<YYYYMMDD>.sha256       SHA256 manifest

Example:
  bash $(basename "$0") \\
    --customer "acme-ltd" \\
    --envelope /path/to/acme-envelope.json \\
    --token-file /path/to/acme-robot-token.txt \\
    --output /tmp/neosecra-packages/
EOF
}


# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
CUSTOMER=""
ENVELOPE=""
TOKEN_FILE=""
OUTPUT_DIR="${DEFAULT_OUTPUT}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h)     usage ;;
    --customer)    shift; CUSTOMER="$1" ;;
    --envelope)    shift; ENVELOPE="$1" ;;
    --token-file)  shift; TOKEN_FILE="$1" ;;
    --output)      shift; OUTPUT_DIR="$1" ;;
    *)             die "Bilinmeyen argüman: $1 (--help kullanın)" 2 ;;
  esac
  shift
done

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------
[[ -z "$CUSTOMER" ]] && die "--customer parametresi zorunludur" 2
[[ -z "$ENVELOPE" ]] && die "--envelope parametresi zorunludur" 2
[[ -z "$TOKEN_FILE" ]] && die "--token-file parametresi zorunludur" 2

if ! [[ "$CUSTOMER" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]+$ ]]; then
  die "Geçersiz müşteri adı: '${CUSTOMER}' — yalnızca harf, rakam, tire ve alt çizgi kullanın" 2
fi

[[ -f "$ENVELOPE" ]] || die "Envelope dosyası bulunamadı: ${ENVELOPE}" 2
[[ -f "$TOKEN_FILE" ]] || die "Token dosyası bulunamadı: ${TOKEN_FILE}" 2

if command -v python3 &>/dev/null; then
  python3 -c "import json; json.load(open('${ENVELOPE}'))" 2>/dev/null \
    || die "Envelope dosyası geçerli JSON değil: ${ENVELOPE}" 2
elif command -v jq &>/dev/null; then
  jq -e . "$ENVELOPE" >/dev/null 2>&1 \
    || die "Envelope dosyası geçerli JSON değil: ${ENVELOPE}" 2
fi

TOKEN_CONTENT="$(cat "$TOKEN_FILE" | tr -d '[:space:]')"
[[ -n "$TOKEN_CONTENT" ]] || die "Token dosyası boş: ${TOKEN_FILE}" 2

UPGRADE_DIR="${REPO_ROOT}/deployment/upgrade"
[[ -d "$UPGRADE_DIR" ]] || die "upgrade dizini bulunamadı: ${UPGRADE_DIR}" 2
[[ -f "${REPO_ROOT}/bootstrap.sh" ]] || die "bootstrap.sh bulunamadı (repo kökü)" 2

[[ -f "${REPO_ROOT}/docs/CUSTOMER-INSTALL.md" ]] || die "docs/CUSTOMER-INSTALL.md bulunamadı" 2

# ---------------------------------------------------------------------------
# Setup output directory
# ---------------------------------------------------------------------------
ARCHIVE_NAME="neosecra-customer-${CUSTOMER}-${STAMP}"
OUTPUT_FILE="${OUTPUT_DIR}/${ARCHIVE_NAME}.tar.gz"
MANIFEST_FILE="${OUTPUT_DIR}/${ARCHIVE_NAME}.sha256"

mkdir -p "$OUTPUT_DIR"

# ---------------------------------------------------------------------------
# Build package in a temporary staging directory
# ---------------------------------------------------------------------------
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT

PKG_DIR="${STAGING}/neosecra-${CUSTOMER}"
mkdir -p "${PKG_DIR}/upgrade"

log "Paket hazırlanıyor: ${CUSTOMER} (${STAMP})"

cp "${REPO_ROOT}/bootstrap.sh"                     "${PKG_DIR}/bootstrap.sh"
cp "${REPO_ROOT}/docs/CUSTOMER-INSTALL.md"         "${PKG_DIR}/CUSTOMER-INSTALL.md"
cp "${UPGRADE_DIR}/upgrade.sh"                     "${PKG_DIR}/upgrade/upgrade.sh"
cp "$ENVELOPE"                                     "${PKG_DIR}/envelope.json"
cp "$TOKEN_FILE"                                   "${PKG_DIR}/robot-token.txt"

cat > "${PKG_DIR}/SUPPORT.md" <<'SUPPORT_EOF'
# NeoSecra Support

**Destek kanalları:**

- **E-posta:** support@neosecra.com
- **Portal:** https://support.neosecra.com
- **Acil durum:** +90-XXX-XXX-XXXX (7/24)

Lütfen aşağıdaki bilgileri destek talebinize ekleyin:
- Müşteri adı
- NeoSecra versiyonu (`neosecra --version`)
- Sorun açıklaması ve adımlar

---

*Bu dosya NeoSecra Ops tarafından doldurulacaktır.*
SUPPORT_EOF

chmod 0644 "${PKG_DIR}"/*.md "${PKG_DIR}"/*.json "${PKG_DIR}"/*.txt "${PKG_DIR}/bootstrap.sh"
chmod 0644 "${PKG_DIR}/upgrade/upgrade.sh"

# ---------------------------------------------------------------------------
# Create tarball
# ---------------------------------------------------------------------------
log "Arşiv oluşturuluyor: ${OUTPUT_FILE}"
tar -czf "$OUTPUT_FILE" -C "$STAGING" "neosecra-${CUSTOMER}"
ok "Paket oluşturuldu: ${OUTPUT_FILE} ($(du -h "$OUTPUT_FILE" | cut -f1))"

# ---------------------------------------------------------------------------
# Generate SHA256 manifest
# ---------------------------------------------------------------------------
{
  tar -tzf "$OUTPUT_FILE" | while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    tar -xOzf "$OUTPUT_FILE" "$entry" 2>/dev/null | sha256sum -b | \
      awk -v e="$entry" '{print $1 "  " e}'
  done
  sha256sum -b "$OUTPUT_FILE" | awk '{print $1 "  " substr($NF,2)}'
} > "$MANIFEST_FILE"

ok "Manifest oluşturuldu: ${MANIFEST_FILE}"

# ---------------------------------------------------------------------------
# Verify manifest integrity
# ---------------------------------------------------------------------------
log "Manifest doğrulanıyor..."

VERIFY_OK=0
while IFS= read -r line; do
  hash_val="${line%%  *}"
  file_path="${line#*  }"
  [[ "$file_path" == *.tar.gz ]] && continue

  actual=$(tar -xOzf "$OUTPUT_FILE" "$file_path" 2>/dev/null | sha256sum -b | awk '{print $1}')
  if [[ "$actual" == "$hash_val" ]]; then
    ok "  ✓ ${file_path}"
  else
    err "  ✗ ${file_path} — hash mismatch"
    VERIFY_OK=1
  fi
done < "$MANIFEST_FILE"

TARBALL_HASH=$(sha256sum -b "$OUTPUT_FILE" | awk '{print $1}')
MANIFEST_TARBALL_HASH=$(grep '.tar.gz$' "$MANIFEST_FILE" | awk '{print $1}')
if [[ "$TARBALL_HASH" != "$MANIFEST_TARBALL_HASH" ]]; then
  err "  ✗ Tarball hash mismatch"
  VERIFY_OK=1
else
  ok "  ✓ ${ARCHIVE_NAME}.tar.gz"
fi

if [[ $VERIFY_OK -eq 0 ]]; then
  ok "Manifest doğrulama başarılı — tüm dosyalar eşleşiyor"
else
  die "Manifest doğrulama BAŞARISIZ — yukarıdaki hataları inceleyin" 3
fi

# ---------------------------------------------------------------------------
# Security warning
# ---------------------------------------------------------------------------
warn "═══════════════════════════════════════════════════════════════════════"
warn "  GÜVENLİK UYARISI: Paket robot-token.txt içermektedir."
warn "  Bu dosya, müşterinin GHCR read-only PAT'ıdır."
warn "  Paket, müşteriye yalnızca GÜVENLİ KANAL üzerinden iletilmelidir."
warn "  (Şifreli e-posta / müşteri portalı / S3 presigned URL)"
warn "═══════════════════════════════════════════════════════════════════════"

ok "İşlem tamam: ${OUTPUT_FILE}"
exit 0