#!/usr/bin/env bash
# NeoSecra Hotspot - signed channel bootstrap installer.
#
# This entry point is intentionally product-specific. The generic distribution
# bootstrap installs Assessment; using it for hotspot would select the wrong
# channel and root directory.
set -Eeuo pipefail

CHANNEL_URL="${NEOSECRA_CHANNEL_URL:-https://update.neosecra.com/channels/hotspot-stable.json}"
INSTALL_ROOT="${NEOSECRA_INSTALL_ROOT:-/opt/neosecra/hotspot}"
DATA_ROOT="${NEOSECRA_DATA_ROOT:-/srv/neosecra/hotspot-data}"
EXPECTED_CHANNEL="hotspot-stable"
EXPECTED_PRODUCT="hotspot"
EXPECTED_EDITION="standard"
API_PORT="${HOTSPOT_API_PORT:-38001}"
BACKEND_UID="${HOTSPOT_BACKEND_UID:-1000:1000}"
REINSTALL=0
CUSTOMER_CONFIG=""
CHECK_CONFIG=0

RED=\033[31m; GREEN=\033[32m; RESET=\033[0m
info() { printf '%s[neosecra-hotspot]%s %s\n' "${GREEN}" "${RESET}" "$@"; }
die() { printf '%s[neosecra-hotspot]%s %s\n' "${RED}" "${RESET}" "$@" >&2; exit "${2:-1}"; }

usage() {
  cat <<'EOF'
NeoSecra Hotspot signed channel bootstrap

Usage:
  bootstrap-hotspot.sh [--reinstall] [--channel-url URL] [--install-root PATH]
                       [--data-root PATH] [--config FILE] [--check-config]

New installs require --config FILE. --check-config validates it offline without installing.

The script resolves the newest hotspot-stable release, verifies the signed
channel and archive, installs Docker/Compose if needed, starts the Compose
stack, installs the host update-agent, and only then switches current.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --reinstall) REINSTALL=1 ;;
    --config) shift; CUSTOMER_CONFIG="${1:-}" ;;
    --check-config) CHECK_CONFIG=1 ;;
    --channel-url) shift; CHANNEL_URL="${1:-}" ;;
    --install-root) shift; INSTALL_ROOT="${1:-}" ;;
    --data-root) shift; DATA_ROOT="${1:-}" ;;
    --help|-h) usage; exit 0 ;;
    *) die "Beklenmeyen arguman: $1" 2 ;;
  esac
  shift
done

# Parse customer input as data, never source a file containing credentials.
validate_customer_config() {
  python3 - "$1" <<'CUSTOMER_CONFIG_PY'
import re
import sys
from pathlib import Path
from urllib.parse import unquote, urlsplit

path = Path(sys.argv[1])
if not path.is_file() or path.is_symlink():
    sys.exit("Customer config must be a regular file")
values = {}
for line in path.read_text(encoding="utf-8-sig").splitlines():
    line = line.strip()
    if not line or line.startswith("#"):
        continue
    key, separator, value = line.partition("=")
    key, value = key.strip(), value.strip()
    if not separator or not re.fullmatch(r"[A-Z][A-Z0-9_]*", key) or key in values:
        sys.exit("Customer config contains an invalid or duplicate key")
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
        value = value[1:-1]
    if any(ord(char) < 0x20 and char != "\t" for char in value):
        sys.exit("Customer config contains a control character")
    values[key] = value
errors = []

def require_https(key, *, required=True):
    raw = values.get(key, "").strip()
    if not raw:
        if required:
            errors.append(f"Missing URL setting: {key}")
        return
    try:
        parsed = urlsplit(raw)
        port = parsed.port
        decoded_path = unquote(parsed.path)
        if (parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password
                or parsed.query or parsed.fragment or (port is not None and not 1 <= port <= 65535)
                or any(c.isspace() or c == "\\" for c in raw)
                or any(part in {".", ".."} for part in decoded_path.split("/"))
                or "//" in decoded_path):
            raise ValueError
    except ValueError:
        errors.append(f"{key} must be a credential-free HTTPS URL")

require_https("PORTAL_PUBLIC_BASE_URL")
require_https("PORTAL_APP_BASE_URL", required=False)
cors = values.get("CORS_ORIGINS", "")
if not cors:
    errors.append("Missing setting: CORS_ORIGINS")
elif "*" in cors:
    errors.append("CORS_ORIGINS must not contain a wildcard")
else:
    for origin in cors.split(","):
        candidate = origin.strip()
        if not candidate:
            errors.append("CORS_ORIGINS contains an empty origin")
            continue
        before = len(errors)
        values["__CORS_ORIGIN"] = candidate
        require_https("__CORS_ORIGIN")
        if len(errors) > before:
            errors[-1] = "CORS_ORIGINS entries must be credential-free HTTPS origins"
values.pop("__CORS_ORIGIN", None)
provider = values.get("SMS_PROVIDER", "").lower()
requirements = {
    "netgsm": [("NETGSM_USERCODE", "NETGSM_USER"), ("NETGSM_PASSWORD", "NETGSM_PASS")],
    "twilio": [("TWILIO_ACCOUNT_SID",), ("TWILIO_AUTH_TOKEN",), ("TWILIO_FROM_NUMBER",)],
    "vatansms": [("VATANSMS_API_ID",), ("VATANSMS_API_KEY",)],
    "iletimerkezi": [("ILETIMERKEZI_API_KEY",), ("ILETIMERKEZI_API_HASH",)],
    "muttl": [("MUTTL_API_KEY",), ("MUTTL_API_URL",)],
    "relateddigital": [("RELATEDDIGITAL_API_KEY",), ("RELATEDDIGITAL_API_URL",)],
    "http": [("SMS_HTTP_URL",)],
}
if provider not in requirements:
    errors.append("SMS_PROVIDER must select a configured real gateway")
else:
    for alternatives in requirements[provider]:
        if not any(values.get(key) for key in alternatives):
            errors.append("Missing SMS setting: " + "/".join(alternatives))
for key in {
    "http": ("SMS_HTTP_URL",),
    "muttl": ("MUTTL_API_URL",),
    "relateddigital": ("RELATEDDIGITAL_API_URL",),
}.get(provider, ()):
    require_https(key)
if values.get("TUBITAK_TSA_REQUIRED", "false").lower() in {"true", "1", "yes"}:
    for key in ("TUBITAK_TSA_URL", "TUBITAK_TSA_CA_BUNDLE"):
        if not values.get(key):
            errors.append("Missing timestamp setting: " + key)
    require_https("TUBITAK_TSA_URL")
    if values.get("TUBITAK_TSA_CA_BUNDLE", "") and not values["TUBITAK_TSA_CA_BUNDLE"].startswith("/"):
        errors.append("TUBITAK_TSA_CA_BUNDLE must be an absolute container path")
for key in ("ARCHIVE_ENCRYPTION_ENABLED", "ARCHIVE_MINIO_OBJECT_LOCK_REQUIRED", "CLICKHOUSE_ENABLED", "UPGRADE_CHANNEL_VERIFY_SSL"):
    if values.get(key, "").lower() not in {"true", "1", "yes"}:
        errors.append(f"{key} must be true for production")
if errors:
    sys.exit("Customer configuration incomplete:\n- " + "\n- ".join(errors))
print("Customer configuration syntax/prerequisites PASS; external delivery is not tested")
CUSTOMER_CONFIG_PY
}

if [[ $CHECK_CONFIG -eq 1 ]]; then
  command -v python3 >/dev/null 2>&1 || die "python3 gerekli; offline config kontrolu baslatilamadi" 2
  [[ -n "$CUSTOMER_CONFIG" ]] || die "--check-config icin --config FILE gerekli" 2
  validate_customer_config "$CUSTOMER_CONFIG" || exit 2
  exit 0
fi
[[ $REINSTALL -eq 0 || -z "$CUSTOMER_CONFIG" ]] || die "Reinstall mevcut credential'lari korur; --config yalnizca yeni kurulumda kullanilir" 2

[[ $EUID -eq 0 ]] || die "Root yetkisi gerekli (sudo ile calistirin)" 1
[[ "$INSTALL_ROOT" = /* && "$INSTALL_ROOT" != / && "$INSTALL_ROOT" != *$'\n'* && "$INSTALL_ROOT" != *$'\r'* ]] || die "Guvenli olmayan kurulum yolu" 2
[[ "$DATA_ROOT" = /* && "$DATA_ROOT" != / && "$DATA_ROOT" != *$'\n'* && "$DATA_ROOT" != *$'\r'* && "$DATA_ROOT" != *'/../'* && "$DATA_ROOT" != */.. ]] || die "Guvenli olmayan veri yolu" 2
[[ "$BACKEND_UID" =~ ^[0-9]+:[0-9]+$ ]] || die "HOTSPOT_BACKEND_UID UID:GID olmali" 2
missing_tools=()
for command_name in curl python3 sha256sum minisign findmnt df awk; do
  command -v "$command_name" >/dev/null 2>&1 || missing_tools+=("$command_name")
done
[[ ${#missing_tools[@]} -eq 0 ]] || die "Eksik host onkosullari: ${missing_tools[*]}; kuruluma devam etmeden once yukleyin" 2
python3 - "$CHANNEL_URL" <<'PY' || die "Kanal URL yalnizca credential icermeyen guvenli HTTPS olabilir" 2
import sys
from urllib.parse import urlsplit
try:
    value = sys.argv[1]
    parsed = urlsplit(value)
    port = parsed.port
    assert parsed.scheme == "https" and parsed.hostname and not parsed.username and not parsed.password
    assert not parsed.query and not parsed.fragment and not any(c.isspace() or c == "\\" for c in value)
    assert port is None or 1 <= port <= 65535
except (AssertionError, ValueError):
    raise SystemExit(1)
PY

command -v curl >/dev/null 2>&1 || die "curl bulunamadi" 2
command -v python3 >/dev/null 2>&1 || die "python3 bulunamadi" 2
command -v sha256sum >/dev/null 2>&1 || die "sha256sum bulunamadi" 2
command -v minisign >/dev/null 2>&1 || die "minisign bulunamadi; imza dogrulama zorunludur" 2
command -v findmnt >/dev/null 2>&1 || die "findmnt bulunamadi; veri diski mount kontrolu yapilamiyor" 2
if [[ -n "$CUSTOMER_CONFIG" ]]; then
  validate_customer_config "$CUSTOMER_CONFIG" || exit 2
elif [[ $REINSTALL -eq 0 ]]; then
  die "Yeni kurulum icin --config FILE gerekli; once --check-config ile dogrulayin" 2
fi

# Never silently place customer data on the OS filesystem. The installer
# requires the explicitly supplied data root to be the mount target of a
# separate filesystem before it creates any application state.
[[ -d "$DATA_ROOT" ]] || die "Veri mount noktasi yok: ${DATA_ROOT}" 2
DATA_MOUNT_TARGET="$(findmnt -T "$DATA_ROOT" -no TARGET 2>/dev/null || true)"
[[ "$DATA_MOUNT_TARGET" == "$DATA_ROOT" ]] || die "Veri diski ${DATA_ROOT} adresine ayri filesystem olarak mount edilmemis" 2
DATA_TOTAL_GB="$(df -BG --output=size "$DATA_ROOT" | awk 'NR==2 {gsub(/G/, "", $1); print $1}')"
DATA_FREE_GB="$(df -BG --output=avail "$DATA_ROOT" | awk 'NR==2 {gsub(/G/, "", $1); print $1}')"
[[ "$DATA_TOTAL_GB" =~ ^[0-9]+$ && "$DATA_FREE_GB" =~ ^[0-9]+$ ]] || die "Veri diski kapasitesi okunamadi" 2
[[ "$DATA_TOTAL_GB" -ge 500 && "$DATA_FREE_GB" -ge 100 ]] || die "Veri diskinde en az 500 GB toplam ve 100 GB bos alan gerekli" 2

CURL_OPTS=(--fail --silent --show-error --location --proto '=https' --proto-redir '=https' -H 'User-Agent: NeoSecra-Hotspot-Bootstrap/1.0')
TMP_DIR="$(mktemp -d /tmp/neosecra-hotspot-bootstrap.XXXXXXXXXX)"
trap 'rm -rf -- "$TMP_DIR"' EXIT
PUBKEY_DIR="$TMP_DIR/update-neosecra-com-keyring"
mkdir -m 700 "$PUBKEY_DIR"
cat > "$PUBKEY_DIR/update-neosecra-com.pub" <<'EOF'
untrusted comment: minisign public key C55D6825451AD013
RWQT0BpFJWhdxSQrTDsZBgPBOln9EFXrF6/Weuk16/l48T7XhMrBGYGK
EOF
cat > "$PUBKEY_DIR/update-neosecra-com-20260904.pub" <<'EOF'
untrusted comment: minisign public key 581BE94E5FAEDD35
RWQ13a5fTukbWMUED/CV1n92CQnY1qfHD2RXC8K4JZiTkYafcpDuux5Z
EOF

verify_minisign_keyring() {
  local file="$1" signature="$2" key
  for key in "$PUBKEY_DIR"/*.pub; do
    [[ -f "$key" && ! -L "$key" ]] || continue
    minisign -Vm "$file" -p "$key" -x "$signature" -q >/dev/null 2>&1 && return 0
  done
  return 1
}

fetch() { curl "${CURL_OPTS[@]}" -o "$2" "$1"; }

info "Kanal metadata aliniyor: $CHANNEL_URL"
fetch "$CHANNEL_URL" "$TMP_DIR/channel.json" || die "Kanal metadata indirilemedi" 4
fetch "$CHANNEL_URL.minisig" "$TMP_DIR/channel.json.minisig" || die "Kanal imzasi indirilemedi" 4
verify_minisign_keyring "$TMP_DIR/channel.json" "$TMP_DIR/channel.json.minisig" || die "Kanal Minisign imzasi gecersiz" 4

RELEASE_JSON="$TMP_DIR/release.json"
python3 - "$TMP_DIR/channel.json" "$RELEASE_JSON" "$EXPECTED_CHANNEL" "$EXPECTED_PRODUCT" "$EXPECTED_EDITION" "${NEOSECRA_VERSION:-}" <<'PY'
import json
import re
import sys
from pathlib import Path
from urllib.parse import urlsplit

source, destination, expected_channel, expected_product, expected_edition, requested_version = sys.argv[1:]
semver = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+$")
sha256 = re.compile(r"^[0-9a-f]{64}$")
channel = json.loads(Path(source).read_text(encoding="utf-8"))
if not isinstance(channel, dict):
    raise SystemExit("channel is not an object")
if (str(channel.get("channel") or "").strip().lower() != expected_channel
        or str(channel.get("product_code") or channel.get("product") or "").strip().lower() != expected_product
        or str(channel.get("edition") or "").strip().lower() != expected_edition):
    raise SystemExit("channel identity mismatch")
if str(channel.get("status") or "").strip().lower() not in {"available", "ready"}:
    raise SystemExit("channel is not available")
current_version = str(channel.get("current_version") or "").strip().lstrip("vV")
releases = channel.get("releases")
if not semver.fullmatch(current_version) or not isinstance(releases, list) or not releases:
    raise SystemExit("channel version or releases are invalid")
version = requested_version.strip().lstrip("vV") if requested_version.strip() else current_version
if not semver.fullmatch(version):
    raise SystemExit("requested version is invalid")
matches = []
seen = set()
for item in releases:
    if not isinstance(item, dict):
        raise SystemExit("release entry is invalid")
    item_version = str(item.get("version") or "").strip().lstrip("vV")
    if not semver.fullmatch(item_version) or item_version in seen:
        raise SystemExit("release version list is invalid")
    seen.add(item_version)
    if item_version == version:
        matches.append(item)
if len(matches) != 1:
    raise SystemExit("requested release is missing or duplicated")
release = matches[0]
archive = release.get("archive")
if not isinstance(archive, dict):
    raise SystemExit("archive metadata is missing")
archive_url = str(archive.get("url") or "").strip()
archive_sig = str(archive.get("signature_url") or "").strip()
archive_sha = str(archive.get("sha256") or "").strip().lower()
for value in (archive_url, archive_sig):
    parsed = urlsplit(value)
    if parsed.scheme != "https" or parsed.username or parsed.password or parsed.fragment:
        raise SystemExit("archive URL must be HTTPS without userinfo/fragment")
if not sha256.fullmatch(archive_sha):
    raise SystemExit("archive SHA-256 is invalid")
Path(destination).write_text(json.dumps({
    "version": version,
    "archive_url": archive_url,
    "archive_signature_url": archive_sig,
    "archive_sha256": archive_sha,
}, sort_keys=True, separators=(",", ":")) + "\n", encoding="utf-8")
PY

VERSION="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$RELEASE_JSON")"
ARCHIVE_URL="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["archive_url"])' "$RELEASE_JSON")"
ARCHIVE_SIG_URL="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["archive_signature_url"])' "$RELEASE_JSON")"
EXPECTED_SHA256="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["archive_sha256"])' "$RELEASE_JSON")"

CURRENT_LINK="${INSTALL_ROOT}/current"
CURRENT_ENV="${CURRENT_LINK}/backend/.env"
if [[ -e "$CURRENT_LINK" || -f "${INSTALL_ROOT}/state/installed-version" ]]; then
  [[ $REINSTALL -eq 1 ]] || die "Mevcut Hotspot kurulumu algilandi; upgrade-agent kullanin veya --reinstall ile acik onay verin" 1
fi

info "Hotspot v${VERSION} arsivi indiriliyor"
fetch "$ARCHIVE_URL" "$TMP_DIR/hotspot.tar.gz" || die "Hotspot arsivi indirilemedi" 4
fetch "$ARCHIVE_SIG_URL" "$TMP_DIR/hotspot.tar.gz.minisig" || die "Hotspot arsiv imzasi indirilemedi" 4
ACTUAL_SHA256="$(sha256sum "$TMP_DIR/hotspot.tar.gz" | awk '{print tolower($1)}')"
[[ "$ACTUAL_SHA256" == "$EXPECTED_SHA256" ]] || die "Hotspot arsiv SHA-256 uyusmuyor" 4
verify_minisign_keyring "$TMP_DIR/hotspot.tar.gz" "$TMP_DIR/hotspot.tar.gz.minisig" || die "Hotspot arsiv Minisign imzasi gecersiz" 4

EXTRACT_ROOT="$TMP_DIR/extract"
mkdir -p "$EXTRACT_ROOT"
python3 - "$TMP_DIR/hotspot.tar.gz" "$EXTRACT_ROOT" "$VERSION" <<'PY'
import os
import re
import sys
import tarfile
from pathlib import Path

archive, destination, target_version = sys.argv[1:]
root = Path(destination).resolve()
max_members = 10000
max_member_bytes = 2 * 1024 * 1024 * 1024
max_total_bytes = 4 * 1024 * 1024 * 1024
safe_component = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")

def fail(message):
    raise SystemExit(message)

def safe_name(raw):
    if not isinstance(raw, str) or not raw or "\x00" in raw or "\\" in raw:
        fail("unsafe archive member name")
    if any(ord(char) < 0x20 or ord(char) == 0x7F for char in raw):
        fail("archive member contains control characters")
    parts = raw.split("/")
    if raw.startswith("/") or any(part in {"", ".", ".."} for part in parts):
        fail("archive member contains traversal or empty components")
    for index, part in enumerate(parts):
        if safe_component.fullmatch(part):
            continue
        if part == ".env.example" and len(parts) == 3 and parts[0].startswith("neosecra-hotspot-") and parts[1] == "backend":
            continue
        fail("archive member component is unsafe")
    return parts

def ensure_parent(relative):
    parent = root.joinpath(*relative.parts[:-1])
    parent.mkdir(parents=True, exist_ok=True)
    cursor = root
    for part in relative.parts[:-1]:
        cursor = cursor / part
        if cursor.is_symlink() or not cursor.is_dir():
            fail("archive extraction encountered an unsafe parent")
    return parent

with tarfile.open(archive, "r:gz") as bundle:
    seen = set()
    top_levels = set()
    total_bytes = 0
    for index, member in enumerate(bundle, 1):
        if index > max_members:
            fail("archive contains too many members")
        if member.isdir() and member.name in {".", "./"}:
            continue
        parts = safe_name(member.name)
        name = "/".join(parts)
        if name in seen:
            fail("archive contains a duplicate member")
        seen.add(name)
        top_levels.add(parts[0])
        if member.size < 0 or member.size > max_member_bytes:
            fail("archive member is too large")
        total_bytes += member.size
        if total_bytes > max_total_bytes:
            fail("archive expands beyond the bounded extraction limit")
        if member.issym() or member.islnk() or member.isdev() or member.isfifo() or not (member.isfile() or member.isdir()):
            fail("archive member type is not permitted")
        relative = Path(*parts)
        target = root.joinpath(*parts)
        if member.isdir():
            if target.is_symlink() or (target.exists() and not target.is_dir()):
                fail("archive directory collides with an existing path")
            target.mkdir(parents=True, exist_ok=True)
            os.chmod(target, 0o700)
            continue
        parent = ensure_parent(relative)
        if target.exists() or target.is_symlink():
            fail("archive extraction would overwrite an existing path")
        source = bundle.extractfile(member)
        if source is None:
            fail("archive regular member has no data")
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        try:
            fd = os.open(target, flags, 0o600)
            with os.fdopen(fd, "wb") as output:
                while True:
                    chunk = source.read(1024 * 1024)
                    if not chunk:
                        break
                    output.write(chunk)
                output.flush()
                os.fsync(output.fileno())
            os.chmod(target, 0o700 if (member.mode & 0o111) else 0o600)
        except OSError as exc:
            try:
                target.unlink(missing_ok=True)
            except OSError:
                pass
            fail(f"archive extraction failed: {exc}")

if len(top_levels) != 1:
    fail("Hotspot archive must contain exactly one top-level root")
archive_root = next(iter(top_levels))
expected_prefix = f"neosecra-hotspot-{target_version}"
if archive_root != expected_prefix and not archive_root.startswith(expected_prefix + "-"):
    fail("Hotspot archive root does not match the signed target")
payload = root / archive_root
for marker in ("docker-compose.yml", "backend/.env.example", "deployment/v1/agent/install-hotspot-agent.sh"):
    candidate = payload / marker
    if not candidate.is_file() or candidate.is_symlink():
        fail(f"Hotspot archive is missing {marker}")
PY

PAYLOAD="$(find "$EXTRACT_ROOT" -mindepth 1 -maxdepth 1 -type d -name 'neosecra-hotspot-*' -print -quit)"
[[ -n "$PAYLOAD" && -f "$PAYLOAD/docker-compose.yml" && -f "$PAYLOAD/backend/.env.example" ]] || die "Arsiv Hotspot Compose payload'i icermiyor" 4
[[ -f "$PAYLOAD/deployment/v1/agent/install-hotspot-agent.sh" ]] || die "Arsiv signed update-agent payload'ini icermiyor" 4
[[ -f "$PAYLOAD/deployment/v1/ca/update-neosecra-com.pub" && -f "$PAYLOAD/deployment/v1/ca/update-neosecra-com-20260904.pub" ]] || die "Arsiv guncel update keyring'ini icermiyor" 4

RELEASES_DIR="${INSTALL_ROOT}/releases"
STATE_DIR="${INSTALL_ROOT}/state"
BACKUPS_DIR="${INSTALL_ROOT}/backups"
mkdir -p "$RELEASES_DIR" "$STATE_DIR" "$BACKUPS_DIR"
RELEASE_DIR="${RELEASES_DIR}/${VERSION}"
[[ ! -e "$RELEASE_DIR" && ! -L "$RELEASE_DIR" ]] || die "Release zaten mevcut: ${RELEASE_DIR}" 1
mkdir -p "$RELEASE_DIR"
cp -a "$PAYLOAD/." "$RELEASE_DIR/"

ENV_FILE="${RELEASE_DIR}/backend/.env"
if [[ -f "$CURRENT_ENV" ]]; then
  cp -a "$CURRENT_ENV" "$ENV_FILE"
elif [[ -n "$CUSTOMER_CONFIG" ]]; then
  cp -- "$CUSTOMER_CONFIG" "$ENV_FILE"
else
  die "Musteri ayar dosyasi bulunamadi" 2
fi
chmod 0600 "$ENV_FILE"

random_hex() { openssl rand -hex "$1" 2>/dev/null || python3 -c "import secrets; print(secrets.token_hex(${1}))"; }
random_fernet() { python3 -c 'import base64,os; print(base64.urlsafe_b64encode(os.urandom(32)).decode())'; }
set_env() {
  local key="$1" value="$2"
  KEY="$key" VALUE="$value" ENV_FILE="$ENV_FILE" python3 - <<'PY'
import os
from pathlib import Path
path = Path(os.environ["ENV_FILE"])
key = os.environ["KEY"]
value = os.environ["VALUE"]
lines = path.read_text(encoding="utf-8").splitlines()
replacement = f"{key}={value}"
updated = False
for index, line in enumerate(lines):
    candidate, separator, _ = line.partition("=")
    if separator == "=" and candidate.strip() == key and not line.lstrip().startswith("#"):
        lines[index] = replacement
        updated = True
        break
if not updated:
    lines.append(replacement)
path.write_text("\n".join(lines) + "\n", encoding="utf-8")
PY
}

env_value() {
  local key="$1"
  awk -F= -v k="$key" '$1 == k && $0 !~ /^[[:space:]]*#/ {sub(/^[^=]*=/, ""); sub(/\r$/, ""); print; exit}' "$ENV_FILE"
}
ensure_env() {
  local key="$1" generated="$2" existing
  existing="$(env_value "$key" || true)"
  if [[ -n "$existing" ]]; then
    printf '%s\n' "$existing"
  else
    set_env "$key" "$generated"
    printf '%s\n' "$generated"
  fi
}

# Reinstall must keep database and encryption credentials stable. Existing
# values are reused; only a fresh installation receives generated secrets.
PG_PASS="$(ensure_env POSTGRES_PASSWORD "$(random_hex 24)")"
SECRET_KEY_VALUE="$(ensure_env SECRET_KEY "$(random_hex 48)")"
CRYPTO_KEY_VALUE="$(ensure_env CRYPTO_KEY "$(random_fernet)")"
MINIO_ACCESS="$(ensure_env MINIO_ACCESS_KEY "$(random_hex 16)")"
MINIO_SECRET="$(ensure_env MINIO_SECRET_KEY "$(random_hex 32)")"
set_env MINIO_ACCESS_KEY "$MINIO_ACCESS"
set_env MINIO_SECRET_KEY "$MINIO_SECRET"
ensure_env CLICKHOUSE_PASSWORD "$(random_hex 32)" >/dev/null
RADIUS_KEY="$(ensure_env RADIUS_API_KEY "$(random_hex 32)")"
SYSLOG_KEY="$(ensure_env SYSLOG_API_KEY "$(random_hex 32)")"
ensure_env DEFAULT_SUPERADMIN_PASSWORD "Neosecra123!" >/dev/null
ensure_env POSTGRES_USER hotspot >/dev/null
ensure_env POSTGRES_DB hotspot >/dev/null
ensure_env CLICKHOUSE_USER default >/dev/null
if [[ -z "$(env_value DATABASE_URL || true)" ]]; then
  set_env DATABASE_URL "postgresql+asyncpg://hotspot:${PG_PASS}@postgres:5432/hotspot"
fi
set_env PRODUCT_VERSION "$VERSION"
# Keep the legacy settings field aligned with the canonical release version.
# Existing .env files may carry an older VERSION value from pre-0.3.24 builds.
set_env VERSION "$VERSION"
set_env UPGRADE_EXECUTION_PROVIDER AGENT
set_env UPGRADE_EXECUTION_ENABLED true
set_env UPGRADE_RELEASE_CHANNEL "$EXPECTED_CHANNEL"
set_env UPGRADE_PRODUCT neosecra-hotspot
set_env UPGRADE_EDITION standard
set_env UPGRADE_CHANNEL_URL "$CHANNEL_URL"
set_env UPGRADE_CHANNEL_CA_BUNDLE ""
set_env UPGRADE_CHANNEL_PUBLIC_KEY /app/ca
set_env STATE_BRIDGE_HOST_DIR "${INSTALL_ROOT}/state/upgrade-bridge"
set_env HOTSPOT_DATA_ROOT "$DATA_ROOT"
set_env HOTSPOT_PGDATA_SOURCE "${DATA_ROOT}/postgres"
set_env HOTSPOT_CLICKHOUSE_SOURCE "${DATA_ROOT}/clickhouse"
set_env HOTSPOT_MINIO_SOURCE "${DATA_ROOT}/minio"
set_env HOTSPOT_ARCHIVES_SOURCE "${DATA_ROOT}/archives"
set_env HOTSPOT_BACKUPS_SOURCE "${DATA_ROOT}/backups"
set_env HOTSPOT_RADIUS_RUNTIME_SOURCE "${DATA_ROOT}/radius-runtime"
# Production 5651 artifacts must be written to the locked MinIO bucket, not
# the compatibility-only local provider. The local volume remains mounted for
# legacy reads and emergency migration only.
set_env ENVIRONMENT production
set_env DEBUG false
set_env DEMO_MODE false
set_env DISABLE_RATE_LIMIT false
set_env AUTH_COOKIE_SECURE true
set_env ENFORCE_LICENSED_OPERATIONS true
set_env ARCHIVE_PROVIDER minio
set_env ARCHIVE_MINIO_ENDPOINT minio:9000
set_env ARCHIVE_MINIO_ACCESS_KEY "$MINIO_ACCESS"
set_env ARCHIVE_MINIO_SECRET_KEY "$MINIO_SECRET"
set_env ARCHIVE_MINIO_BUCKET hotspot-5651
set_env ARCHIVE_MINIO_SECURE false
set_env BACKUP_PATH /data/backups

for data_dir in postgres clickhouse minio archives backups radius-runtime; do
  install -d -m 0750 "${DATA_ROOT}/${data_dir}"
done
# Backend runs as UID/GID 1000 and needs only these two application mounts to
# be writable. Database/object-store images retain their own entrypoint ACLs.
chown 1000:1000 "${DATA_ROOT}/archives" "${DATA_ROOT}/backups" "${DATA_ROOT}/radius-runtime"

if ! command -v docker >/dev/null 2>&1; then
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq docker.io docker-compose-plugin || apt-get install -y -qq docker.io docker-compose
  else
    die "Docker bulunamadi; desteklenmeyen hostta uzaktan kurulum yapilmaz. Docker/Compose'u onceden kurun" 4
  fi
fi
command -v docker >/dev/null 2>&1 || die "Docker kurulumu dogrulanamadi" 4
docker compose version >/dev/null 2>&1 || die "Docker Compose v2 gerekli" 4
systemctl enable --now docker >/dev/null 2>&1 || true

info "Host update-agent kuruluyor"
bash "${RELEASE_DIR}/deployment/v1/agent/install-hotspot-agent.sh" \
  --hotspot-root "$INSTALL_ROOT" --backend-uid "$BACKEND_UID" \
  --backup-root "${DATA_ROOT}/backups" --channel-url "$CHANNEL_URL" || \
  die "Hotspot update-agent kurulumu basarisiz" 4

# Compose gives process variables precedence over --env-file. Pin these inputs
# so a caller's development shell cannot weaken a customer runtime.
export HOTSPOT_ENVIRONMENT=production
export HOTSPOT_ENFORCE_LICENSED_OPERATIONS=true
export HOTSPOT_CLICKHOUSE_ENABLED=true
COMPOSE=(docker compose --project-name neosecra-hotspot --project-directory "$RELEASE_DIR" --env-file "$ENV_FILE" -f "$RELEASE_DIR/docker-compose.yml")
"${COMPOSE[@]}" config >/dev/null || die "Compose config gecersiz" 4
info "Hotspot Compose stack baslatiliyor"
"${COMPOSE[@]}" up -d --build || die "Hotspot Compose baslatilamadi" 4

HEALTH_URL="http://127.0.0.1:${API_PORT}/health"
healthy=0
for _ in $(seq 1 90); do
  if curl -fsS --max-time 10 "$HEALTH_URL" >/dev/null 2>&1; then healthy=1; break; fi
  sleep 2
done
[[ $healthy -eq 1 ]] || die "Hotspot health kontrolu basarisiz: ${HEALTH_URL}"

atomic_switch() {
  local target="$1" tmp="${INSTALL_ROOT}/.current.new.$$"
  rm -f "$tmp"
  ln -s "$target" "$tmp"
  mv -Tf "$tmp" "$CURRENT_LINK"
}
atomic_write() {
  local destination="$1" content="$2" tmp="${destination}.tmp.$$"
  printf '%s\n' "$content" > "$tmp"
  chmod 0600 "$tmp"
  mv -f "$tmp" "$destination"
}
atomic_switch "$RELEASE_DIR"
atomic_write "${STATE_DIR}/installed-version" "$VERSION"
info "Hotspot v${VERSION} kuruldu; signed update kanali aktif: $CHANNEL_URL"
