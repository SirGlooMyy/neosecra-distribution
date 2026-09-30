#!/usr/bin/env bash
# NeoSecra Assessment — tek komut kurulum
set -Eeuo pipefail
umask 077
TMP_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TMP_DIR"' EXIT
BASE="${NEOSECRA_INSTALL_ROOT:-/opt/neosecra/assessment}"
err() { printf '[neosecra] %s\n' "$*" >&2; exit 1; }
[[ "$EUID" -eq 0 ]] || err "Root required"
for tool in curl python3 minisign sha256sum; do
  command -v "$tool" >/dev/null 2>&1 || err "Install prerequisite $tool from your signed OS package repository"
done
PUBKEY_DIR="$TMP_DIR/keyring"
mkdir -m 700 "$PUBKEY_DIR"
cat > "$PUBKEY_DIR/update-neosecra-com.pub" <<'KEY'
untrusted comment: minisign public key C55D6825451AD013
RWQT0BpFJWhdxSQrTDsZBgPBOln9EFXrF6/Weuk16/l48T7XhMrBGYGK
KEY
cat > "$PUBKEY_DIR/update-neosecra-com-20260904.pub" <<'KEY'
untrusted comment: minisign public key 581BE94E5FAEDD35
RWQ13a5fTukbWMUED/CV1n92CQnY1qfHD2RXC8K4JZiTkYafcpDuux5Z
KEY
verify_minisign_keyring() {
  local file="$1" signature="$2" key
  for key in "$PUBKEY_DIR"/*.pub; do
    minisign -Vm "$file" -p "$key" -x "$signature" -q >/dev/null 2>&1 && return 0
  done
  return 1
}

VERSION=""
FRONTEND_IMAGE_VERSION=""

# ---------------------------------------------------------------------------
# T4 TLS: TLS mode selection
#   NEOSECRA_TLS_MODE=public   (default) — Let's Encrypt, system trust store
#   NEOSECRA_TLS_MODE=internal — Custom CA (embedded below, air-gap / lab)
# ---------------------------------------------------------------------------
NEOSECRA_TLS_MODE="${NEOSECRA_TLS_MODE:-public}"

# ---------------------------------------------------------------------------
# Centralised curl options — carries User-Agent + optional --cacert
# ---------------------------------------------------------------------------
CURL_OPTS=(--fail --silent --show-error --location --proto "=https" --proto-redir "=https" --tlsv1.2 -H "User-Agent: NeoSecra-Bootstrap/1.0")
NEOSECRA_CA_CERT="${NEOSECRA_CA_CERT:-}"
if [[ "${NEOSECRA_TLS_MODE}" == "internal" && -n "${NEOSECRA_CA_CERT}" && -f "${NEOSECRA_CA_CERT}" ]]; then
  CURL_OPTS+=("--cacert" "$NEOSECRA_CA_CERT")
fi

# ---------------------------------------------------------------------------
# T4 TLS: Embedded CA certificate for update.neosecra.com
# Used only in internal mode (custom CA). In public mode the system trust
# store already validates Let's Encrypt certificates, so no CA install needed.
# ---------------------------------------------------------------------------
NEOSECRA_CA_B64='LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0tCk1JSUIvakNDQVlTZ0F3SUJBZ0lVS3R3SSt1NitkZTN1T1Y3MGpka3dtRWN2N2RNd0NnWUlLb1pJemowRUF3TXcKTGpFWk1CY0dBMVVFQXd3UVRtVnZVMlZqY21FZ1VtOXZkQ0JEUVRFUk1BOEdBMVVFQ2d3SVRtVnZVMlZqY21FdwpIaGNOTWpZd056STNNRGt5TkRFMFdoY05Nell3TnpJME1Ea3lOREUwV2pBdU1Sa3dGd1lEVlFRRERCQk9aVzlUClpXTnlZU0JTYjI5MElFTkJNUkV3RHdZRFZRUUtEQWhPWlc5VFpXTnlZVEIyTUJBR0J5cUdTTTQ5QWdFR0JTdUIKQkFBaUEySUFCT0NUekl2UzY0aW9XaVdmUGVEdXcvRkRqR2VHLzFVWUhaSkM2WGd4WkdVVVgwOFA0M3pheGk4YgpkSlcrNTV0OFp5cVBXSndGUHZUZHFxa3AxQmV1dyt3QW5HSFNzcmljV052OEkzeFh3NHVWeDRydmJzL3JENTFhCjhyNGczZFRRTUtOak1HRXdIUVlEVlIwT0JCWUVGRlkza25JZ0dyZ015eFU3eHk2aUJQM0dVRlpGTUI4R0ExVWQKSXdRWU1CYUFGRlkza25JZ0dyZ015eFU3eHk2aUJQM0dVRlpGTUE4R0ExVWRFd0VCL3dRRk1BTUJBZjh3RGdZRApWUjBQQVFIL0JBUURBZ0VHTUFvR0NDcUdTTTQ5QkFNREEyZ0FNR1VDTUZvbzZKSzg4b3VaM1ZVNWo1RDhwMndCCjlyL08wN25QNGdQd01YdHU1b3cybWpwVmtObWU0SURqOHphMWROSXJxZ0l4QUp5UzgzZDhoV2ZCd3FRa2NHZVoKMTU1NW9pYkg4WHl2S3I4YmtacWIveHV6TzlXY01xOUVIcTEwb2RnM3RrR3JDUT09Ci0tLS0tRU5EIENFUlRJRklDQVRFLS0tLS0K'

install_update_server_ca() {
  local ca_path="/usr/local/share/ca-certificates/update-neosecra-com.crt"
  if [[ -f "$ca_path" ]] && openssl x509 -in "$ca_path" -noout 2>/dev/null; then
    return 0  # Already installed
  fi
  local tmp_ca
  tmp_ca="$TMP_DIR/update-ca.crt"
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
if [[ -n "${LOCAL_MANIFEST:-}" ]]; then
  cp -- "$LOCAL_MANIFEST" "$TMP_DIR/channel.json"
  cp -- "${LOCAL_MANIFEST}.minisig" "$TMP_DIR/channel.json.minisig"
else
  curl "${CURL_OPTS[@]}" -o "$TMP_DIR/channel.json" "$CHANNEL_URL"
  curl "${CURL_OPTS[@]}" -o "$TMP_DIR/channel.json.minisig" "${CHANNEL_URL}.minisig"
fi
verify_minisign_keyring "$TMP_DIR/channel.json" "$TMP_DIR/channel.json.minisig" || err "Channel Minisign signature verification failed"
python3 - "$TMP_DIR/channel.json" "$BASE" "${NEOSECRA_VERSION:-}" "$TMP_DIR/release-fields" "${NEOSECRA_DISTRIBUTION_ARCHIVE_URL:-}" <<'CHANNEL_PY'
import json
import re
import sys
from pathlib import Path
from urllib.parse import urlsplit

source, base, requested, output, override_url = sys.argv[1:]
pattern = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9]+)*$")
def version_key(value):
    if not isinstance(value, str) or not pattern.fullmatch(value):
        raise SystemExit("Invalid version string")
    major, minor, patch, suffix = re.fullmatch(r"([0-9]+)\.([0-9]+)\.([0-9]+)(.*)", value).groups()
    tokens = tuple((0, int(x)) if x.isdigit() else (1, x) for x in re.split(r"[.-]", suffix)[1:])
    rank = 0 if suffix.startswith("-") else 2 if suffix.startswith(".") else 1
    return int(major), int(minor), int(patch), rank, tokens
channel = json.loads(Path(source).read_text(encoding="utf-8"))
if (not isinstance(channel, dict) or channel.get("channel") != "assessment-stable"
        or channel.get("product") != "assessment"
        or channel.get("product_code", "assessment") != "assessment"):
    raise SystemExit("Channel identity mismatch")
version = channel.get("current_version")
target = version_key(version)
if requested and requested != version:
    raise SystemExit("Version override must match signed current_version")
base = Path(base)
for marker in (base / "state/installed-version", base / "state/active-release",
               base / "current/VERSION", base / "current/v1/VERSION"):
    if (marker.exists() or marker.is_symlink()) and version_key(marker.read_text(encoding="utf-8").strip()) > target:
        raise SystemExit("Anti-rollback: target is older than installed version")
current = base / "current"
if current.exists() and not current.is_symlink() and not any(
        p.exists() for p in (base / "state/installed-version", base / "state/active-release",
                            current / "VERSION", current / "v1/VERSION")):
    raise SystemExit("Installed version state missing")
if current.is_symlink():
    if not current.exists():
        raise SystemExit("Installed current pointer is dangling")
    if version_key(current.resolve().name) > target:
        raise SystemExit("Anti-rollback: target is older than current release")
releases = channel.get("releases")
if not isinstance(releases, list):
    raise SystemExit("Signed releases missing")
matches = [r for r in releases if isinstance(r, dict) and r.get("version") == version]
if len(matches) != 1:
    raise SystemExit("Signed release is missing or duplicated")
release = matches[0]
archive = release.get("archive")
if isinstance(archive, dict):
    url, digest = archive.get("url"), archive.get("sha256")
else:
    url, digest = archive or release.get("url"), release.get("sha256")
if not isinstance(url, str) or any(c.isspace() or c == "\\" for c in url):
    raise SystemExit("Invalid signed archive URL")
parsed = urlsplit(url)
if (parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password
        or parsed.query or parsed.fragment):
    raise SystemExit("Signed archive URL must be credential-free HTTPS")
if override_url and override_url != url:
    raise SystemExit("Archive override must match signed URL")
if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-fA-F]{64}", digest):
    raise SystemExit("Signed archive SHA-256 missing or invalid")
Path(output).write_bytes(("\n".join((version, url, digest.lower())) + "\n").encode("utf-8"))

CHANNEL_PY
mapfile -t RELEASE_FIELDS < "$TMP_DIR/release-fields"
VERSION="${RELEASE_FIELDS[0]}"
DISTRIBUTION_ARCHIVE_URL="${RELEASE_FIELDS[1]}"
EXPECTED_SHA256="${RELEASE_FIELDS[2]}"
FRONTEND_IMAGE_VERSION="$VERSION"
RED='\033[31m'; GRN='\033[32m'; RST='\033[0m'
info() { echo -e "${GRN}[neosecra]${RST} $*"; }
err()  { echo -e "${RED}[neosecra]${RST} $*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || err "Root required"

# Release signatures are mandatory; an environment override must not permit
# an untrusted payload to reach the installation path.
[[ "${NEOSECRA_REQUIRE_SIGNATURE:-1}" == "1" ]] || \
  err "NEOSECRA_REQUIRE_SIGNATURE=0 is unsupported; signed releases are mandatory"
NEOSECRA_REQUIRE_SIGNATURE=1

# ---------------------------------------------------------------------------
# Image registry — NeoSecra images live at registry.neosecra.com (our own
# registry on the Tailscale/LAN, TLS via custom CA in internal mode).
# No Docker login/token is required: the registry is reached over the private
# network and authenticated by TLS, not by Docker credentials.
#
# Legacy NEOSECRA_GHCR_USER / NEOSECRA_GHCR_TOKEN env vars are accepted for
# backward compatibility with existing customer runbooks but are intentionally
# unused — GHCR is no longer in the image supply chain.
# ---------------------------------------------------------------------------
NEOSECRA_REGISTRY="${NEOSECRA_REGISTRY:-registry.neosecra.com}"
: "${NEOSECRA_GHCR_USER:=}"
: "${NEOSECRA_GHCR_TOKEN:=}"
if [[ -n "$NEOSECRA_GHCR_USER" || -n "$NEOSECRA_GHCR_TOKEN" ]]; then
  info "NEOSECRA_GHCR_* algılandı ama artık kullanılmıyor (registry.neosecra.com token'siz)"
  unset NEOSECRA_GHCR_TOKEN
fi

registry_reachable() {
  local ref="${NEOSECRA_REGISTRY}/security-health-backend:${VERSION}"
  if docker manifest inspect "$ref" >/dev/null 2>&1; then
    info "NeoSecra registry erişilebilir (${NEOSECRA_REGISTRY})"
    return 0
  fi
  # TLS-protected registry: try the unauthenticated /v2/ ping (honours custom CA)
  local curl_args=("${CURL_OPTS[@]}" --max-time 10)
  if [[ -n "${CURL_CA_BUNDLE:-}" && -f "${CURL_CA_BUNDLE:-}" ]]; then
    curl_args+=(--cacert "$CURL_CA_BUNDLE")
  fi
  if curl "${curl_args[@]}" "https://${NEOSECRA_REGISTRY}/v2/" >/dev/null 2>&1; then
    info "NeoSecra registry API erişilebilir (${NEOSECRA_REGISTRY}/v2)"
    return 0
  fi
  return 1
}

# Soft preflight: warn (do not hard-fail) so a transient DNS/CA issue does not
# block install. The real gate is `docker compose pull` later in install.sh.
if ! registry_reachable; then
  info "[warn] ${NEOSECRA_REGISTRY} şimdilik erişilemedi — /etc/hosts ve CA sertifikasını kontrol edin; pull sırasında tekrar denenecek"
fi



info "NeoSecra Assessment v${VERSION} kurulum başlıyor..."

# --- Docker ---
install_docker() {
  info "Docker bulunamadı — otomatik kurulum başlatılıyor"
  local os_id=""
  if [[ -f /etc/os-release ]]; then
    os_id="$(. /etc/os-release && echo "${ID:-}")"
  fi

  command -v apt-get >/dev/null 2>&1 && [[ "$os_id" =~ ^(debian|ubuntu)$ ]] || \
    err "Install Docker/Compose using your distribution's signed package repository first"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq || err "Signed apt index update failed"
  apt-get install -y -qq docker.io || err "Docker Engine install failed"
  if ! docker compose version >/dev/null 2>&1; then
    apt-get install -y -qq docker-compose-v2 || \
      apt-get install -y -qq docker-compose-plugin || err "Docker Compose v2 install failed"
  fi
  systemctl enable --now docker >/dev/null 2>&1 || err "Docker service start failed"

  docker --version >/dev/null 2>&1 || err "Docker kurulumu doğrulanamadı — 'docker --version' çalışmıyor"
  docker compose version >/dev/null 2>&1 || err "Docker Compose v2 plugin doğrulanamadı — 'docker compose version' çalışmıyor"
  info "Docker hazır: $(docker --version 2>/dev/null) / $(docker compose version 2>/dev/null)"
}

if ! command -v docker &>/dev/null; then
  install_docker
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

env_value_from() {
  # Mevcut bir .env.v1'den değeri grep-and-keep ile al; yoksa boş döner.
  # Secret'ları yeniden üretmek yerine KORUMAK için kullanılır.
  local file="$1" key="$2"
  if [[ -f "$file" ]]; then
    grep -E "^${key}=" "$file" 2>/dev/null | tail -n1 | cut -d= -f2- || true
  fi
}

random_admin_password() {
  local candidate lower
  for ((attempt = 0; attempt < 30; attempt++)); do
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
# NEOSECRA_INSTALL_ROOT yalnızca bootstrap'in kendi base dizinini ezmek içindir
# (sandbox/staging testleri). Varsayılan canlı hedef /opt/neosecra/assessment.
RELEASE_DIR="${BASE}/releases/${VERSION}"
CURRENT_RELEASE_DIR=""
if [[ -L "${BASE}/current" ]]; then
  CURRENT_RELEASE_DIR="$(readlink -f "${BASE}/current" 2>/dev/null || true)"
fi

# ---------------------------------------------------------------------------
# Kurulum guard'ı — mevcut kurulumu asla "fresh" sanma (veri kaybı koruması).
# En kötü olay: canlı müşteri kurulumu olan makinede bootstrap.sh yeniden
# çalıştırıldı, .env.v1 taze rastgele parolalarla yeniden üretildi, postgres
# farklı/uyumsuz bir veri dizinine karşı yeniden oluşturuldu ve müşteri
# veritabanı (users/customers/license) fiilen silindi. Bu blok bunu imkânsız
# kılar:
#   * current/.env.v1 VARSA  -> fresh install REDDEDİLİR (exit 1)
#   * --reinstall / NEOSECRA_REINSTALL=1 -> açık onay istenir ve mevcut
#     secret'lar KORUNUR (yeniden üretilmez, grep-and-keep).
# ---------------------------------------------------------------------------
CURRENT_ENV="${BASE}/current/.env.v1"

REINSTALL=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --reinstall) REINSTALL=1 ;;
    --help|-h)
      cat <<'HELP'
NeoSecra Assessment — tek komut kurulum

Kullanım:
  bootstrap.sh [--reinstall] [--help]

  --reinstall   Mevcut kurulum üzerine fresh install'a izin verir (yıkıcı
                olabilir; aksi halde reddedilir). NEOSECRA_REINSTALL=1 ile de
                açılır. Onay gerekir: NEOSECRA_REINSTALL_CONFIRM=1 veya
                interaktif terminalde 'REINSTALL' yazmak. Secret'lar asla
                yeniden üretilmez; mevcut .env.v1 kullanılır.
  --help        Bu yardımı göster
HELP
      exit 0 ;;
    *) err "Beklenmeyen argüman: $1" ;;
  esac
  shift
done
[[ "${NEOSECRA_REINSTALL:-0}" == "1" ]] && REINSTALL=1

if [[ -f "$CURRENT_ENV" ]]; then
  if [[ $REINSTALL -ne 1 ]]; then
    err "Mevcut kurulum algılandı (${CURRENT_ENV}) — veri kaybını önlemek için fresh install iptal. Yükseltme için: upgrade/upgrade.sh"
  fi
  info "Reinstall modu: mevcut kurulum tespit edildi — mevcut secret'lar korunacak, yeniden üretilmeyecek"
  if [[ "${NEOSECRA_REINSTALL_CONFIRM:-0}" != "1" ]]; then
    if [[ ! -t 0 ]]; then
      err "Reinstall onayı gerekli: NEOSECRA_REINSTALL_CONFIRM=1 ile tekrar çalıştırın (veya interaktif terminalde devam etmek için REINSTALL yazın)"
    fi
    read -r -p "[neosecra] Devam etmek için 'REINSTALL' yazın: " _reinstall_answer
    [[ "$_reinstall_answer" == "REINSTALL" ]] || err "Reinstall onayı verilmedi — iptal"
  fi
  export NEOSECRA_REINSTALL=1
fi

INSTALLED_VERSION=""
if [[ -f "${BASE}/state/installed-version" ]]; then
  INSTALLED_VERSION="$(cat "${BASE}/state/installed-version" 2>/dev/null || true)"
fi

info "Downloading signed archive: ${DISTRIBUTION_ARCHIVE_URL}"
curl "${CURL_OPTS[@]}" -o "$TMP_DIR/dist.tar.gz" "$DISTRIBUTION_ARCHIVE_URL"
curl "${CURL_OPTS[@]}" -o "$TMP_DIR/dist.tar.gz.sha256" "${DISTRIBUTION_ARCHIVE_URL}.sha256"
curl "${CURL_OPTS[@]}" -o "$TMP_DIR/dist.tar.gz.minisig" "${DISTRIBUTION_ARCHIVE_URL}.minisig"
# Never use an untrusted sidecar filename as a local hashing target.
SIDECAR_SHA256="$(python3 - "$TMP_DIR/dist.tar.gz.sha256" <<'HASH_PY'
import re
import sys
from pathlib import Path
value = Path(sys.argv[1]).read_text(encoding="ascii").strip()
match = re.fullmatch(r"([0-9a-fA-F]{64})(?:[ \t]+\*?[^\r\n]+)?", value)
if not match:
    raise SystemExit("Invalid SHA-256 sidecar")
print(match[1].lower())
HASH_PY
)"
ACTUAL_SHA256="$(sha256sum "$TMP_DIR/dist.tar.gz" | cut -d' ' -f1)"
[[ "$ACTUAL_SHA256" == "$EXPECTED_SHA256" && "$ACTUAL_SHA256" == "$SIDECAR_SHA256" ]] || err "Archive SHA-256 mismatch"
verify_minisign_keyring "$TMP_DIR/dist.tar.gz" "$TMP_DIR/dist.tar.gz.minisig" || err "Archive Minisign signature verification failed"

# The packaged extractor is not available yet. Validate the entire tar index
# and version declaration before any extraction; never execute archive helpers.
EXTRACT_ROOT="$TMP_DIR/extract"
python3 - "$TMP_DIR/dist.tar.gz" "$EXTRACT_ROOT" "$VERSION" <<'EXTRACT_PY'
import os
import re
import shutil
import sys
import tarfile
from pathlib import Path

archive, destination, version = sys.argv[1:]
def fail(message):
    raise SystemExit("SECURITY VIOLATION: " + message)
if Path(archive).stat().st_size > 2 * 1024**3:
    fail("compressed archive exceeds size limit")
root = Path(destination)
with tarfile.open(archive, "r:gz") as bundle:
    members = []
    names = set()
    roots = set()
    total = 0
    for index, member in enumerate(bundle, 1):
        if index > 10000:
            fail("too many archive members")
        if member.isdir() and member.name in {".", "./"}:
            continue
        parts = member.name.split("/")
        if (member.name.startswith("/") or "\\" in member.name
                or any(not re.fullmatch(r"[A-Za-z0-9_][A-Za-z0-9._-]{0,127}", part) for part in parts)
                or any(part in {"", ".", ".."} for part in parts)):
            fail("unsafe archive member path")
        if member.name in names:
            fail("duplicate archive member")
        names.add(member.name)
        roots.add(parts[0])
        if not (member.isfile() or member.isdir()):
            fail("archive links/devices/FIFOs are forbidden")
        if member.size < 0 or member.size > 2 * 1024**3:
            fail("archive member exceeds size limit")
        total += member.size
        if total > 4 * 1024**3:
            fail("archive exceeds total size limit")
        members.append(member)
    if len(roots) != 1:
        fail("archive requires a single root")
    archive_root = next(iter(roots))
    expected = "neosecra-distribution-" + version
    if archive_root != expected and not archive_root.startswith(expected + "-"):
        fail("archive root version mismatch")
    files = {m.name for m in members if m.isfile()}
    for name in names:
        parts = name.split("/")
        if any("/".join(parts[:i]) in files for i in range(1, len(parts))):
            fail("archive parent is a regular file")
    marker = archive_root + "/deployment/VERSION"
    found = [m for m in members if m.name == marker and m.isfile()]
    if len(found) != 1 or found[0].size > 256:
        fail("archive VERSION declaration missing or oversized")
    if bundle.extractfile(found[0]).read().decode("utf-8").strip() != version:
        fail("archive VERSION does not match signed channel")
    root.mkdir(mode=0o700)
    print("Archive preflight passed; extracting verified payload", flush=True)
    for member in members:
        target = root.joinpath(*member.name.split("/"))
        if member.isdir():
            target.mkdir(parents=True, exist_ok=True, mode=0o700)
            continue
        target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
        with os.fdopen(os.open(target, flags, 0o600), "wb") as output:
            source = bundle.extractfile(member)
            if source is None:
                fail("regular member has no data")
            with source:
                shutil.copyfileobj(source, output, 1024 * 1024)
        os.chmod(target, 0o600 | (member.mode & 0o555))
EXTRACT_PY
DIST_DIR="$(find "$EXTRACT_ROOT" -mindepth 1 -maxdepth 1 -type d -name 'neosecra-distribution-*' -print -quit)"
[[ -n "$DIST_DIR" && -d "$DIST_DIR" ]] || err "Distribution directory missing"
cd "$DIST_DIR"

if [[ -d "$RELEASE_DIR" ]]; then
  BACKUP_DIR="${BASE}/backups/preinstall-${VERSION}-$(date -u +%Y%m%dT%H%M%SZ)"
  mkdir -p "$BACKUP_DIR"
  cp -a "$RELEASE_DIR" "${BACKUP_DIR}/release-${VERSION}"
  info "Existing release backed up: ${BACKUP_DIR}/release-${VERSION}"
fi
mkdir -p "$RELEASE_DIR"
rsync -a deployment/ "$RELEASE_DIR/" 2>/dev/null || cp -r deployment/* "$RELEASE_DIR/" 2>/dev/null || err "Script dosyaları kopyalanamadı"

# U6: Script checksum divergence check — compare deployed scripts against manifest
if [[ -f "${RELEASE_DIR}/release-manifest.yaml" ]]; then
    manifest_checksums=$(grep -E '^script_checksums:' "${RELEASE_DIR}/release-manifest.yaml" 2>/dev/null | cut -d' ' -f2- | tr -d '"' || true)
    if [[ -n "$manifest_checksums" ]]; then
        divergence=0
        IFS=',' read -ra CHECKS <<< "$manifest_checksums"
        for entry in "${CHECKS[@]}"; do
            script_path="${entry%%=*}"
            expected_hash="${entry#*=}"
            [[ -z "$script_path" || -z "$expected_hash" ]] && continue
            # The manifest path is relative to deployment/ repo root; in release dir it's under <release>/
            actual_hash=$(sha256sum "${RELEASE_DIR}/${script_path#deployment/}" 2>/dev/null | cut -d' ' -f1 || true)
            if [[ -n "$actual_hash" && "$actual_hash" != "$expected_hash" ]]; then
                info "[warn] Script divergence: ${script_path} checksum ${actual_hash} != manifest ${expected_hash}"
                divergence=1
            fi
        done
        if [[ $divergence -eq 1 ]]; then
            info "[warn] Script checksum divergence detected — live skeleton may have been edited outside release process"
        fi
    fi
fi

info "Verified temporary distribution will be removed on exit"

cd "$RELEASE_DIR"

# Mevcut kurulumun .env.v1'ini yeni release'e taşı — secret'ları yeniden üretme.
if [[ -f "$CURRENT_ENV" && ! -f .env.v1 ]]; then
  cp -a "$CURRENT_ENV" .env.v1
  chmod 0600 .env.v1 2>/dev/null || true
  info "Mevcut kurulumun .env.v1'i korundu (secret'lar yeniden üretilmedi): ${CURRENT_ENV}"
elif [[ -f .env.v1 && -f "$CURRENT_ENV" ]] && ! cmp -s .env.v1 "$CURRENT_ENV"; then
  ENV_BACKUP="${RELEASE_DIR}/.env.v1.backup-$(date -u +%Y%m%dT%H%M%SZ)"
  cp -a .env.v1 "$ENV_BACKUP"
  chmod 0600 "$ENV_BACKUP" 2>/dev/null || true
  info "Mevcut .env.v1 yedeklendi (VERİ KAYBINA KARŞI): ${ENV_BACKUP}"
  cp -a "$CURRENT_ENV" .env.v1
  chmod 0600 .env.v1 2>/dev/null || true
  info "Mevcut kurulumun .env.v1'i uygulandı: ${CURRENT_ENV}"
fi

# --- .env oluştur ---
if [[ ! -f .env.v1 ]]; then
  umask 077
  # Secret'ları asla körlemesine üretme: mevcut kurulumun .env.v1'i varsa
  # (grep-and-keep) DEĞERLERİNİ YENİDEN KULLAN, sadece eksik olanları üret.
  # Aksi halde POSTGRES_PASSWORD değişirse mevcut pgdata'ya yazılamaz ve
  # postgres baştan "taze" bir veri dizinine açılır = veri kaybı.
  PG_PASS="$(env_value_from "$CURRENT_ENV" POSTGRES_PASSWORD)"; [[ -n "$PG_PASS" ]] || PG_PASS=$(random_hex 24)
  SECRET_KEY_VALUE="$(env_value_from "$CURRENT_ENV" SECRET_KEY)"; [[ -n "$SECRET_KEY_VALUE" ]] || SECRET_KEY_VALUE=$(random_hex 48)
  OTP_SECRET_VALUE="$(env_value_from "$CURRENT_ENV" OTP_SECRET)"; [[ -n "$OTP_SECRET_VALUE" ]] || OTP_SECRET_VALUE=$(random_hex 48)
  FIRST_ADMIN_PASSWORD_VALUE="$(env_value_from "$CURRENT_ENV" FIRST_ADMIN_PASSWORD)"
  [[ -n "$FIRST_ADMIN_PASSWORD_VALUE" ]] || FIRST_ADMIN_PASSWORD_VALUE="${NEOSECRA_FIRST_ADMIN_PASSWORD:-Neosecra123!}"
  FIRST_ADMIN_EMAIL_VALUE="$(env_value_from "$CURRENT_ENV" FIRST_ADMIN_EMAIL)"
  [[ -n "$FIRST_ADMIN_EMAIL_VALUE" ]] || FIRST_ADMIN_EMAIL_VALUE="${NEOSECRA_FIRST_ADMIN_EMAIL:-admin@neosecra.com}"
  ADMIN_RECOVERY_KEY_VALUE="$(env_value_from "$CURRENT_ENV" ADMIN_RECOVERY_KEY)"; [[ -n "$ADMIN_RECOVERY_KEY_VALUE" ]] || ADMIN_RECOVERY_KEY_VALUE=$(random_hex 32)
  OPENVAS_PASSWORD_VALUE="$(env_value_from "$CURRENT_ENV" OV_PASSWORD)"; [[ -n "$OPENVAS_PASSWORD_VALUE" ]] || OPENVAS_PASSWORD_VALUE=$(random_hex 24)
  OPENVAS_GVM_PASSWORD_VALUE="$(env_value_from "$CURRENT_ENV" OPENVAS_PASS)"; [[ -n "$OPENVAS_GVM_PASSWORD_VALUE" ]] || OPENVAS_GVM_PASSWORD_VALUE=$(random_hex 24)
  OPENVAS_GMP_PASSWORD_VALUE="$(env_value_from "$CURRENT_ENV" OPENVAS_GMP_PASS)"; [[ -n "$OPENVAS_GMP_PASSWORD_VALUE" ]] || OPENVAS_GMP_PASSWORD_VALUE=$(random_hex 24)
  DB_URL="postgresql+asyncpg://neosecra:${PG_PASS}@postgres:5432/neosecra_assessment"
  if [[ -n "${NEOSECRA_LICENSE_PUBLIC_KEY_B64:-}" ]]; then
    LICENSE_PUBLIC_KEY_LINE="LICENSE_PUBLIC_KEY_B64=${NEOSECRA_LICENSE_PUBLIC_KEY_B64}"
  else
    LICENSE_PUBLIC_KEY_LINE="LICENSE_PUBLIC_KEY_B64=$(env_value_from "$CURRENT_ENV" LICENSE_PUBLIC_KEY_B64)"
    [[ "$LICENSE_PUBLIC_KEY_LINE" != "LICENSE_PUBLIC_KEY_B64=" ]] || LICENSE_PUBLIC_KEY_LINE="LICENSE_PUBLIC_KEY_B64=qe+qrDcT1FNuvTcVNUEf/bwru4dJakikHPaf0ELEdf8="
  fi

  printf '%s\n' \
    "NEOSECRA_VERSION=${VERSION}" \
    "${LICENSE_PUBLIC_KEY_LINE}" \
    "POSTGRES_IMAGE=postgres:15.18-alpine3.24" \
    "REDIS_IMAGE=redis:7.4.9-alpine3.21" \
    "BACKEND_IMAGE=${NEOSECRA_REGISTRY}/security-health-backend:${VERSION}" \
    "WORKER_IMAGE=${NEOSECRA_REGISTRY}/security-health-backend:${VERSION}" \
    "FRONTEND_IMAGE=${NEOSECRA_REGISTRY}/security-health-frontend:${FRONTEND_IMAGE_VERSION}" \
    "OPENVAS_IMAGE=immauss/openvas:26.07.12.01" \
    "POSTGRES_USER=neosecra" \
    "POSTGRES_PASSWORD=${PG_PASS}" \
    "POSTGRES_DB=neosecra_assessment" \
    "DATABASE_URL=${DB_URL}" \
    "REDIS_URL=redis://redis:6379/0" \
    "SECRET_KEY=${SECRET_KEY_VALUE}" \
    "OTP_SECRET=${OTP_SECRET_VALUE}" \
    "FIRST_ADMIN_EMAIL=${FIRST_ADMIN_EMAIL_VALUE}" \
    "FIRST_ADMIN_PASSWORD=${FIRST_ADMIN_PASSWORD_VALUE}" \
    "ADMIN_RECOVERY_KEY=${ADMIN_RECOVERY_KEY_VALUE}" \
    "POSTGRES_PORT=25433" \
    "REDIS_PORT=23639" \
    "BACKEND_PORT=23800" \
    "FRONTEND_PORT=23300" \
    "FRONTEND_TLS_PORT=23443" \
    "NEOSECRA_EDITION=security_health" \
    "VITE_NEOSECRA_EDITION=security-health" \
    "ENVIRONMENT=production" \
    "BACKEND_CORS_ORIGINS=https://localhost:23443,https://127.0.0.1:23443,http://localhost:23300,http://127.0.0.1:23300" \
    "ALGORITHM=HS256" \
    "ACCESS_TOKEN_EXPIRE_MINUTES=15" \
    "REFRESH_TOKEN_EXPIRE_DAYS=7" \
    "UPLOAD_DIR=/app/uploads" \
    "REPORT_DIR=/app/reports" \
    "DATA_RETENTION_ENABLED=true" \
    "DATA_RETENTION_DAYS=365" \
    "DATA_RETENTION_FAILED_DAYS=90" \
    "UPGRADE_CHANNEL_URL=https://update.neosecra.com/channels/assessment-stable.json" \
    "UPGRADE_CHANNEL_PUBLIC_KEY=/etc/neosecra/ca/update-neosecra-com.pub" \
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
      ensure_frontend_tls
      run_compose up -d postgres redis
      wait_service_healthy postgres 90
      wait_service_healthy redis 90
      reconcile_postgres_password
      ensure_assessment_schema_compatibility || die "Assessment schema compatibility repair failed" 11
      sync_initial_admin_credentials || die "Initial admin credential synchronization failed" 11
      run_compose pull -q openvas || true
      if ! run_compose --profile openvas up -d; then
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
info "Web: https://<sunucu-ip>:23443 (self-signed — tarayıcı güven uyarısı normal, kabul edin)"
info "     http://<sunucu-ip>:23300 otomatik HTTPS'e yönlendirir"
info "Yönetim: neosecra <komut>"
info "============================================"
