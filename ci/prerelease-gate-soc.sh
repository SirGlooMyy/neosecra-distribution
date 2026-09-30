#!/usr/bin/env bash
# Offline, fail-closed stable-promotion gate for SOC release inputs.
set +x
set -Eeuo pipefail
umask 077

usage() {
  cat <<'EOF'
Usage: prerelease-gate-soc.sh --archive <path> --bundle <path> --images-lock <path> --version <semver>
EOF
}

ARCHIVE=""
BUNDLE=""
IMAGES_LOCK=""
VERSION=""
EXPECTED_METHOD=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --archive) shift; ARCHIVE="${1:-}" ;;
    --bundle) shift; BUNDLE="${1:-}" ;;
    --images-lock) shift; IMAGES_LOCK="${1:-}" ;;
    --version) shift; VERSION="${1:-}" ;;
    --trust-policy) shift; EXPECTED_METHOD="${1:-}" ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

die() { echo "SOC_GATE|FAIL|$*" >&2; exit 1; }
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "version is invalid"
for path in "$ARCHIVE" "$BUNDLE" "$IMAGES_LOCK"; do
  [[ -f "$path" && ! -L "$path" && -s "$path" ]] || die "release input is missing or unsafe"
done
command -v python3 >/dev/null 2>&1 || die "python3 is required"
command -v tar >/dev/null 2>&1 || die "tar is required"

# A publisher operator cannot replace the approved verifier with an argument.
POLICY_FILE="/etc/neosecra/distribution/soc-attestation-policy"
[[ -f "$POLICY_FILE" && ! -L "$POLICY_FILE" ]] || die "root-managed SOC attestation policy is missing"
policy_owner="$(stat -c '%U:%G' "$POLICY_FILE")"
policy_mode="$(stat -c '%a' "$POLICY_FILE")"
[[ "$policy_owner" == "root:root" ]] || die "SOC attestation policy owner is invalid"
(( (8#$policy_mode & 022) == 0 )) || die "SOC attestation policy is writable by group or others"
mapfile -t policy_lines < <(grep -Ev '^[[:space:]]*(#|$)' "$POLICY_FILE")
METHOD=""
COSIGN_PUBLIC_KEY=""
MINISIGN_PUBLIC_KEY=""
PREFLIGHT_RECEIPT=""
if [[ "${#policy_lines[@]}" -eq 1 && "${policy_lines[0]}" == COSIGN_PUBLIC_KEY=* ]]; then
  METHOD="cosign-spdx-v1"
  COSIGN_PUBLIC_KEY="${policy_lines[0]#COSIGN_PUBLIC_KEY=}"
elif [[ "${#policy_lines[@]}" -eq 5 && "${policy_lines[0]}" == "METHOD=minisign-package-v1" ]]; then
  METHOD="minisign-package-v1"
  [[ "${policy_lines[1]}" == MINISIGN_PUBLIC_KEY=* && "${policy_lines[2]}" == MINISIGN_PUBLIC_KEY_SHA256=* &&
     "${policy_lines[3]}" == PREFLIGHT_RECEIPT=* && "${policy_lines[4]}" == PREFLIGHT_RECEIPT_SHA256=* ]] ||
    die "SOC Minisign policy fields are incomplete or out of order"
  MINISIGN_PUBLIC_KEY="${policy_lines[1]#MINISIGN_PUBLIC_KEY=}"
  MINISIGN_PUBLIC_KEY_SHA256="${policy_lines[2]#MINISIGN_PUBLIC_KEY_SHA256=}"
  PREFLIGHT_RECEIPT="${policy_lines[3]#PREFLIGHT_RECEIPT=}"
  PREFLIGHT_RECEIPT_SHA256="${policy_lines[4]#PREFLIGHT_RECEIPT_SHA256=}"
  [[ "$MINISIGN_PUBLIC_KEY_SHA256" =~ ^[0-9a-f]{64}$ && "$PREFLIGHT_RECEIPT_SHA256" =~ ^[0-9a-f]{64}$ ]] ||
    die "SOC Minisign policy digest is invalid"
else
  die "SOC attestation policy method is unsupported"
fi

[[ -z "$EXPECTED_METHOD" || "$EXPECTED_METHOD" == "$METHOD" ]] || die "registered trust policy differs from approved host policy"

require_root_file() {
  local path="$1" description="$2" owner mode
  [[ "$path" == /* && "$path" != *".."* && -f "$path" && ! -L "$path" ]] || die "$description is missing or unsafe"
  owner="$(stat -c '%U:%G' "$path")"
  mode="$(stat -c '%a' "$path")"
  [[ "$owner" == "root:root" ]] || die "$description owner is invalid"
  (( (8#$mode & 022) == 0 )) || die "$description is writable by group or others"
}

if [[ "$METHOD" == "cosign-spdx-v1" ]]; then
  [[ -n "$COSIGN_PUBLIC_KEY" && "$COSIGN_PUBLIC_KEY" != *[[:space:]]* ]] || die "SOC verifier reference is invalid"
  [[ "$COSIGN_PUBLIC_KEY" == *"://"* ]] || require_root_file "$COSIGN_PUBLIC_KEY" "approved SOC verifier key"
  command -v cosign >/dev/null 2>&1 || die "cosign is required for SOC Cosign promotion"
else
  require_root_file "$MINISIGN_PUBLIC_KEY" "SOC Minisign public key"
  require_root_file "$PREFLIGHT_RECEIPT" "SOC preflight receipt"
  [[ "$(sha256sum "$MINISIGN_PUBLIC_KEY" | awk '{print $1}')" == "$MINISIGN_PUBLIC_KEY_SHA256" ]] ||
    die "SOC Minisign public key digest mismatch"
  [[ "$(sha256sum "$PREFLIGHT_RECEIPT" | awk '{print $1}')" == "$PREFLIGHT_RECEIPT_SHA256" ]] ||
    die "SOC preflight receipt digest mismatch"
  cmp -s "$MINISIGN_PUBLIC_KEY" "/opt/neosecra/distribution/public-keys/update-neosecra-com.pub" ||
    die "SOC Minisign key differs from Distribution signer public key"
  MINISIGN_BIN="${HOME}/.local/bin/minisign"
  [[ -x "$MINISIGN_BIN" ]] || die "Minisign verifier is unavailable"
  "$MINISIGN_BIN" -Vm /opt/neosecra/distribution/update-server/www/channels/soc-beta.json \
    -x /opt/neosecra/distribution/update-server/www/channels/soc-beta.json.minisig \
    -p "$MINISIGN_PUBLIC_KEY" >/dev/null || die "signed SOC beta provenance is invalid"
fi

# Docker-save bundles must contain a manifest. Image trust is checked by digest.
tar -tf "$BUNDLE" | grep -x 'manifest.json' >/dev/null || die "Docker bundle lacks manifest.json"

TMP_DIR="$(mktemp -d /tmp/neosecra-soc-gate.XXXXXXXXXX)"
trap 'rm -rf -- "$TMP_DIR"' EXIT
PAYLOAD="$TMP_DIR/neosecra-soc-$VERSION"
python3 - "$ARCHIVE" "$TMP_DIR" "$VERSION" <<'PY'
import sys
import tarfile
from pathlib import PurePosixPath

archive, destination, version = sys.argv[1:]
expected_root = f"neosecra-soc-{version}"
with tarfile.open(archive, "r:gz") as bundle:
    members = bundle.getmembers()
    if not members:
        raise SystemExit("archive is empty")
    for member in members:
        path = PurePosixPath(member.name)
        if path.is_absolute() or ".." in path.parts or not path.parts or path.parts[0] != expected_root:
            raise SystemExit("archive path escapes the expected SOC payload root")
        if not (member.isdir() or member.isfile()):
            raise SystemExit("archive contains a non-regular filesystem entry")
    bundle.extractall(destination, members=members)
PY

[[ -d "$PAYLOAD" ]] || die "SOC archive payload root is missing"
for relative in   release/channel-client.sh   release/images.lock   release/python-runtime.sh   release/release-manifest.yaml   release/soc-cli   release/verify-image-attestation.sh   release/verify-release-gate.sh; do
  [[ -f "$PAYLOAD/$relative" && ! -L "$PAYLOAD/$relative" ]] || die "SOC archive is missing $relative"
done
cmp -s "$IMAGES_LOCK" "$PAYLOAD/release/images.lock" || die "publisher lock differs from packaged lock"

python3 - "$PAYLOAD" "$ARCHIVE" "$BUNDLE" "$IMAGES_LOCK" "$VERSION" "$METHOD" "$PREFLIGHT_RECEIPT" <<'PY'
import hashlib
import json
import re
import sys
from pathlib import Path

payload, archive, bundle, images_lock = map(Path, sys.argv[1:5])
version, method, receipt_path = sys.argv[5:8]
checksums = payload / "release" / "checksums.sha256"
rows = checksums.read_text(encoding="utf-8").splitlines()
if not rows:
    raise SystemExit("SOC package checksum manifest is empty")
for row in rows:
    match = re.fullmatch(r"([0-9a-f]{64}) [ *](.+)", row)
    if not match:
        raise SystemExit("SOC package checksum entry is invalid")
    relative = Path(match.group(2))
    if relative.is_absolute() or ".." in relative.parts:
        raise SystemExit("SOC package checksum path is unsafe")
    target = payload / relative
    if not target.is_file() or target.is_symlink() or hashlib.sha256(target.read_bytes()).hexdigest() != match.group(1):
        raise SystemExit("SOC package checksum mismatch")
manifest = payload / "release" / "release-manifest.yaml"
fields = {}
for line in manifest.read_text(encoding="utf-8").splitlines():
    if ":" not in line:
        continue
    key, value = line.split(":", 1)
    if key.strip() in {"product", "edition", "version", "channel", "build_commit", "rollback_pointer", "release_package_ready", "rollback_runtime_verified"}:
        fields[key.strip()] = value.strip().strip("'\"")
if (fields.get("product") != "neosecra-soc" or fields.get("edition") != "soc" or
        fields.get("version") != version or fields.get("channel") != "stable" or
        fields.get("release_package_ready") != "true" or
        fields.get("rollback_runtime_verified") != "true" or
        fields.get("rollback_pointer") != "/var/lib/neosecra/soc/rollback-pointer" or
        not re.fullmatch(r"[0-9a-f]{40}", fields.get("build_commit", ""))):
    raise SystemExit("SOC stable package metadata is incomplete or inconsistent")
sbom_dir = payload / "release" / "sbom"
expected = {"ai", "backend", "caddy", "frontend", "nginx", "postgres", "redis"}
actual = {path.name.removesuffix(".spdx.json") for path in sbom_dir.glob("*.spdx.json")}
if actual != expected:
    raise SystemExit("SOC package SBOM set is incomplete or unexpected")
for name in expected:
    data = json.loads((sbom_dir / f"{name}.spdx.json").read_text(encoding="utf-8"))
    if data.get("spdxVersion") != "SPDX-2.3" or not isinstance(data.get("packages"), list) or not data["packages"]:
        raise SystemExit(f"SOC SBOM is not SPDX-2.3: {name}")
if method == "minisign-package-v1":
    receipt = json.loads(Path(receipt_path).read_text(encoding="utf-8"))
    if (receipt.get("format") != "soc-stable-preflight-v1" or receipt.get("version") != version or
            receipt.get("source_revision") != fields["build_commit"] or
            receipt.get("archive_sha256") != hashlib.sha256(archive.read_bytes()).hexdigest() or
            receipt.get("bundle_sha256") != hashlib.sha256(bundle.read_bytes()).hexdigest() or
            receipt.get("images_lock_sha256") != hashlib.sha256(images_lock.read_bytes()).hexdigest() or
            not re.fullmatch(r"[0-9a-f]{64}", receipt.get("previous_images_lock_sha256", "")) or
            not str(receipt.get("poc_backup_path", "")).startswith("/var/backups/neosecra-soc/") or
            receipt.get("target_database_revision") != "120_soc_intake_processing_state"):
        raise SystemExit("SOC root-pinned preflight receipt does not bind release inputs")
    for key in ("poc_backup_checksum_verified", "isolated_postgres_restore_verified",
                "isolated_redis_restore_verified", "previous_backend_schema120_health_verified"):
        if receipt.get(key) is not True:
            raise SystemExit("SOC preflight receipt lacks a verified rollback gate")
PY

if [[ "$METHOD" == "cosign-spdx-v1" ]]; then
  RELEASE_GATE_MODE=stable COSIGN_PUBLIC_KEY="$COSIGN_PUBLIC_KEY" \
    bash "$PAYLOAD/release/verify-image-attestation.sh" \
    "$PAYLOAD/release/release-manifest.yaml" "$PAYLOAD/release/images.lock"
fi

echo "SOC_GATE|PASS|stable ${METHOD} inputs, SBOMs and rollback preflight verified"
