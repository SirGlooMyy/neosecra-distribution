#!/usr/bin/env bash
# Registry-driven canonical publisher. Product decisions live in products/*.json.
# Preserve immutable release and anti-rollback checks before activation.
set +x
set -Eeuo pipefail
umask 077
export PYTHONDONTWRITEBYTECODE=1
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PRODUCT="" CHANNEL="" VERSION="" ARCHIVE="" BUNDLE="" IMAGES_LOCK="" MIGRATION_METADATA=""
KEY="${HOME}/.neosecra/update-signing.key"
WWW="${SCRIPT_DIR}/www"
RSYNC_TARGET="" DRY_RUN=0 STAGE="" PLAN="" LOCK="" SOURCE_CANDIDATE="" SOURCE_LOCK=""
REMOTE_HOSTS=() REMOTE_PATHS=()
usage() {
  cat <<'EOF'
Usage: publish.sh --product <code> --channel <channel> --version <semver> --archive <path>
  [--bundle <path>] [--images-lock <path>] [--migration-metadata <path>]
  [--key <path>] [--www <path>] [--rsync <user@host:/path>] [--dry-run]
Inputs, trust policy, gate, bootstrap and steps are defined by products/<code>.json.
MINISIGN_BIN selects the signer executable; UPDATE_SERVER_TARGETS adds rsync targets.
Signing passwords are read by Minisign on stdin/TTY, never by this script.
EOF
}
die() { echo "[ERROR] $*" >&2; exit 1; }
cleanup() {
  local index
  for index in "${!REMOTE_HOSTS[@]}"; do
    ssh -o StrictHostKeyChecking=yes "${REMOTE_HOSTS[$index]}" "python3 -c \"import shutil; shutil.rmtree('${REMOTE_PATHS[$index]}', ignore_errors=True)\"" >/dev/null 2>&1 || true
  done
  [[ -z "$PLAN" ]] || rm -f -- "$PLAN"
  [[ -z "$SOURCE_CANDIDATE" ]] || rm -f -- "$SOURCE_CANDIDATE" "$SOURCE_CANDIDATE.minisig"
  [[ -z "$STAGE" ]] || rm -rf -- "$STAGE"
  [[ -z "$LOCK" ]] || rmdir -- "$LOCK"
  [[ -z "$SOURCE_LOCK" ]] || rmdir -- "$SOURCE_LOCK"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --dry-run) DRY_RUN=1; shift; continue ;;
    --product|--channel|--version|--archive|--bundle|--images-lock|--migration-metadata|--key|--www|--rsync)
      [[ $# -ge 2 && -n "$2" ]] || die "Option requires a value" ;;
    *) die "Unknown option" ;;
  esac
  case "$1" in
    --product) PRODUCT="$2" ;; --channel) CHANNEL="$2" ;; --version) VERSION="$2" ;;
    --archive) ARCHIVE="$2" ;; --bundle) BUNDLE="$2" ;; --images-lock) IMAGES_LOCK="$2" ;;
    --migration-metadata) MIGRATION_METADATA="$2" ;; --key) KEY="$2" ;;
    --www) WWW="$2" ;; --rsync) RSYNC_TARGET="$2" ;;
  esac
  shift 2
done
[[ -n "$PRODUCT" && -n "$CHANNEL" && -n "$VERSION" && -n "$ARCHIVE" ]] || die "Required options: --product --channel --version --archive"
command -v python3 >/dev/null 2>&1 || die "python3 is required"
PLAN="$(mktemp "${TMPDIR:-/tmp}/publish-plan.XXXXXXXX")"
python3 "${SCRIPT_DIR}/lib/registry.py" plan "$REPO_ROOT" "$PRODUCT" "$CHANNEL" "$VERSION" "$ARCHIVE" "$BUNDLE" "$IMAGES_LOCK" "$MIGRATION_METADATA" > "$PLAN"
mapfile -d '' -t SETTINGS < "$PLAN"
BOOTSTRAP_SRC="${SETTINGS[0]}" GATE_SCRIPT="${SETTINGS[1]}" TRUST_POLICY="${SETTINGS[2]}" RELEASE_RELATIVE="${SETTINGS[3]}" RUN_GATE="${SETTINGS[4]}"
REGISTRY_FILE="${REPO_ROOT}/products/${PRODUCT}.json"
if [[ -z "${MINISIGN_BIN:-}" ]]; then
  MINISIGN_BIN="$(command -v minisign || true)"
  if [[ -z "$MINISIGN_BIN" ]]; then
    for candidate in "${HOME}/.local/bin/minisign" "${HOME}/bin/minisign" /usr/local/bin/minisign /usr/bin/minisign; do
      if [[ -x "$candidate" ]]; then MINISIGN_BIN="$candidate"; break; fi
    done
  fi
fi
[[ -n "$MINISIGN_BIN" && -x "$MINISIGN_BIN" ]] || die "Minisign is required (set MINISIGN_BIN)"
export MINISIGN_BIN
command -v sha256sum >/dev/null 2>&1 || die "sha256sum is required"
case "$TRUST_POLICY" in
  minisign-package-v1) ;;
  cosign-spdx-v1) command -v cosign >/dev/null 2>&1 || die "cosign is required by registered trust policy" ;;
  *) die "Unknown trust policy" ;;
esac
PUBLIC_KEYS_DIR="${REPO_ROOT}/public-keys"
python3 - "$SCRIPT_DIR" "$PUBLIC_KEYS_DIR" <<'PY'
import sys
sys.path.insert(0,sys.argv[1]+'/lib')
from verify import keys
keys(sys.argv[2])
PY
RSYNC_TARGETS=()
if [[ -n "${UPDATE_SERVER_TARGETS:-}" ]]; then read -ra RSYNC_TARGETS <<< "$UPDATE_SERVER_TARGETS"; fi
if [[ -n "$RSYNC_TARGET" ]]; then RSYNC_TARGETS+=("$RSYNC_TARGET"); fi
for target in "${RSYNC_TARGETS[@]}"; do
  [[ "$target" =~ ^([a-zA-Z0-9._-]+@)?[a-zA-Z0-9._-]+:/[a-zA-Z0-9/._-]+$ && "$target" != *".."* ]] || die "Unsafe rsync target"
done
if [[ ${#RSYNC_TARGETS[@]} -gt 0 ]]; then
  command -v rsync >/dev/null 2>&1 || die "rsync is required"
  command -v ssh >/dev/null 2>&1 || die "ssh is required"
fi
if [[ "$DRY_RUN" -eq 0 ]]; then
  [[ -f "$KEY" && ! -L "$KEY" ]] || die "Signing key is missing or unsafe"
  mkdir -p "$REPO_ROOT/channels"
  mkdir -- "$REPO_ROOT/channels/.publish-lock" 2>/dev/null || die "Source channels are locked"
  SOURCE_LOCK="$REPO_ROOT/channels/.publish-lock"
  # A single writer covers channels sharing immutable product/version paths.
  mkdir -p -- "$WWW"
  mkdir -- "$WWW/.publish-lock" 2>/dev/null || die "Publisher is locked; inspect interrupted publication before retry"
  LOCK="$WWW/.publish-lock"
  STAGE="$(mktemp -d "$WWW/.publish.XXXXXXXX")"
else
  STAGE="$(mktemp -d "${TMPDIR:-/tmp}/publish-preview.XXXXXXXX")"
fi
mkdir -p "$STAGE/upload/$RELEASE_RELATIVE" "$STAGE/upload/channels" "$STAGE/transformed"
CHANNEL_JSON="${PRODUCT}-${CHANNEL}.json"
REPO_CHANNEL="${REPO_ROOT}/channels/${CHANNEL_JSON}"
WWW_CHANNEL="${WWW}/channels/${CHANNEL_JSON}"
SOURCE_SNAPSHOT="$STAGE/source-channel"
WWW_SNAPSHOT="$STAGE/www-channel"
for origin in source www; do
  if [[ "$origin" == source ]]; then channel_file="$REPO_CHANNEL"; snapshot="$SOURCE_SNAPSHOT";
  else channel_file="$WWW_CHANNEL"; snapshot="$WWW_SNAPSHOT"; fi
  if [[ -e "$channel_file" ]]; then
    [[ -f "$channel_file" && ! -L "$channel_file" && -f "$channel_file.minisig" && ! -L "$channel_file.minisig" ]] || die "Unsafe channel pair"
    cp -- "$channel_file" "$snapshot"
    cp -- "$channel_file.minisig" "$snapshot.minisig"
    python3 "${SCRIPT_DIR}/lib/registry.py" validate-channel "$REPO_ROOT" "$PRODUCT" "$CHANNEL" "$snapshot"
    python3 "${SCRIPT_DIR}/lib/verify.py" signature "$snapshot" "$PUBLIC_KEYS_DIR"
  fi
done
if [[ -f "$SOURCE_SNAPSHOT" && -f "$WWW_SNAPSHOT" ]]; then
  cmp -s "$SOURCE_SNAPSHOT" "$WWW_SNAPSHOT" || die "Channel source drift"
  cmp -s "$SOURCE_SNAPSHOT.minisig" "$WWW_SNAPSHOT.minisig" || die "Channel signature source drift"
fi
SOURCE_CHANNEL="$SOURCE_SNAPSHOT"
if [[ ! -f "$SOURCE_CHANNEL" && -f "$WWW_SNAPSHOT" ]]; then SOURCE_CHANNEL="$WWW_SNAPSHOT"; fi
ARCHIVE_NAME="$(basename "$ARCHIVE")"
# Preserve original filenames throughout transformation, hashing and signing.
cp -- "$ARCHIVE" "$STAGE/upload/$RELEASE_RELATIVE/$ARCHIVE_NAME"
ARCHIVE="$STAGE/upload/$RELEASE_RELATIVE/$ARCHIVE_NAME"
if [[ -n "$BUNDLE" ]]; then
  BUNDLE_NAME="$(basename "$BUNDLE")"
  [[ "$BUNDLE_NAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ && "$BUNDLE_NAME" != "$ARCHIVE_NAME" && "$BUNDLE_NAME" != "bootstrap.sh" ]] || die "Unsafe or conflicting bundle filename"
  cp -- "$BUNDLE" "$STAGE/upload/$RELEASE_RELATIVE/$BUNDLE_NAME"
  BUNDLE="$STAGE/upload/$RELEASE_RELATIVE/$BUNDLE_NAME"
fi
if [[ -n "$IMAGES_LOCK" ]]; then cp -- "$IMAGES_LOCK" "$STAGE/images.lock"; IMAGES_LOCK="$STAGE/images.lock"; fi
if [[ -n "$MIGRATION_METADATA" ]]; then cp -- "$MIGRATION_METADATA" "$STAGE/migration.json"; MIGRATION_METADATA="$STAGE/migration.json"; fi
RELEASE_EXTRA="$STAGE/release-extra.json"
python3 "${SCRIPT_DIR}/lib/archive.py" "$REGISTRY_FILE" "$ARCHIVE" "$BUNDLE"
IFS=',' read -ra STEPS <<< "${SETTINGS[5]}"
for step in "${STEPS[@]}"; do
  [[ -n "$step" ]] || continue
  echo "[INFO] Registered step: $step"
  # registry.py already rejected unknown names and paths outside the repository.
  source "$SCRIPT_DIR/lib/steps/$step.sh"
done
if [[ "$ARCHIVE" != "$STAGE/upload/$RELEASE_RELATIVE/$ARCHIVE_NAME" ]]; then
  mv -- "$ARCHIVE" "$STAGE/upload/$RELEASE_RELATIVE/$ARCHIVE_NAME"
  ARCHIVE="$STAGE/upload/$RELEASE_RELATIVE/$ARCHIVE_NAME"
fi
python3 "${SCRIPT_DIR}/lib/registry.py" validate-manifest "$REPO_ROOT" "$PRODUCT" "$ARCHIVE" "$BUNDLE"
BOOTSTRAP=""
if [[ -n "$BOOTSTRAP_SRC" ]]; then
  [[ "$ARCHIVE_NAME" != "bootstrap.sh" ]] || die "Archive conflicts with bootstrap"
  cp -- "$REPO_ROOT/$BOOTSTRAP_SRC" "$STAGE/upload/$RELEASE_RELATIVE/bootstrap.sh"
  BOOTSTRAP="$STAGE/upload/$RELEASE_RELATIVE/bootstrap.sh"
fi
CHANNEL_CANDIDATE="$STAGE/upload/channels/$CHANNEL_JSON"
python3 "${SCRIPT_DIR}/lib/channel.py" build "$REGISTRY_FILE" "${PRODUCT}-${CHANNEL}" "$VERSION" "$SOURCE_CHANNEL" "$CHANNEL_CANDIDATE" "$RELEASE_RELATIVE" "$ARCHIVE" "$BUNDLE" "$BOOTSTRAP" "$RELEASE_EXTRA"
if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "[DRY-RUN] Product=$PRODUCT channel=$CHANNEL version=$VERSION trust=$TRUST_POLICY"
  echo "[DRY-RUN] Release path=$RELEASE_RELATIVE bootstrap=${BOOTSTRAP_SRC:-none}"
  echo "[DRY-RUN] Gate=$GATE_SCRIPT enabled=$RUN_GATE; input is the final transformed archive"
  echo "[DRY-RUN] Sign and verify SHA-256/Minisign; activate identical source and WWW channel pairs"
  for target in "${RSYNC_TARGETS[@]}"; do echo "[DRY-RUN] Transfer only this publication to $target (no deletion)"; done
  exit 0
fi
# Gates receive the exact staged artifact that will be signed and renamed.
if [[ "$RUN_GATE" -eq 1 ]]; then
  GATE_ARGS=()
  IFS=',' read -ra GATE_INPUTS <<< "${SETTINGS[6]}"
  for input in "${GATE_INPUTS[@]}"; do
    case "$input" in
      archive) GATE_ARGS+=(--archive "$ARCHIVE") ;; version) GATE_ARGS+=(--version "$VERSION") ;;
      bundle) GATE_ARGS+=(--bundle "$BUNDLE") ;; images-lock) GATE_ARGS+=(--images-lock "$IMAGES_LOCK") ;;
      trust-policy) GATE_ARGS+=(--trust-policy "$TRUST_POLICY") ;; registry) GATE_ARGS+=(--registry "$REGISTRY_FILE") ;; *) die "Unknown gate input" ;;
    esac
  done
  GATE_FILES=("$ARCHIVE" "$CHANNEL_CANDIDATE")
  for file in "$BUNDLE" "$BOOTSTRAP" "$IMAGES_LOCK" "$MIGRATION_METADATA"; do [[ -z "$file" ]] || GATE_FILES+=("$file"); done
  before="$(sha256sum "${GATE_FILES[@]}")"
  bash "$REPO_ROOT/$GATE_SCRIPT" "${GATE_ARGS[@]}" || die "Registered pre-release gate failed"
  [[ "$(sha256sum "${GATE_FILES[@]}")" == "$before" ]] || die "Gate modified the final release inputs"
fi
sign_file() {
  # Only the signer inherits the key descriptor. Its arguments contain neither
  # private-key contents/path nor a password, and no temporary key copy exists.
  if ! (
    exec 3<"$KEY"
    "$MINISIGN_BIN" -S -s /dev/fd/3 -m "$1" -t "NeoSecra $PRODUCT $CHANNEL v$VERSION"
  ) >/dev/null 2>&1; then die "Minisign signing failed"; fi
}
for file in "$ARCHIVE" "$BUNDLE" "$BOOTSTRAP"; do
  [[ -n "$file" ]] || continue
  (cd "$(dirname "$file")" && sha256sum "$(basename "$file")" > "$(basename "$file").sha256")
  sign_file "$file"
  python3 "$SCRIPT_DIR/lib/verify.py" artifact "$file" "$PUBLIC_KEYS_DIR"
  chmod 644 "$file" "$file.sha256" "$file.minisig"
done
sign_file "$CHANNEL_CANDIDATE"
python3 "$SCRIPT_DIR/lib/verify.py" signature "$CHANNEL_CANDIDATE" "$PUBLIC_KEYS_DIR"
mkdir -p "$REPO_ROOT/channels" "$WWW/channels"
chmod 755 "$WWW/channels"
SOURCE_CANDIDATE="$(mktemp "$REPO_ROOT/channels/.publish-channel.XXXXXXXX")"
cp -- "$CHANNEL_CANDIDATE" "$SOURCE_CANDIDATE"
cp -- "$CHANNEL_CANDIDATE.minisig" "$SOURCE_CANDIDATE.minisig"
# All copies precede verification. activate.py verifies and renames each exact candidate.
chmod 644 "$SOURCE_CANDIDATE" "$SOURCE_CANDIDATE.minisig" "$CHANNEL_CANDIDATE" "$CHANNEL_CANDIDATE.minisig"
for origin in source www; do
  if [[ "$origin" == source ]]; then channel_file="$REPO_CHANNEL"; snapshot="$SOURCE_SNAPSHOT";
  else channel_file="$WWW_CHANNEL"; snapshot="$WWW_SNAPSHOT"; fi
  if [[ -f "$snapshot" ]]; then
    cmp -s "$snapshot" "$channel_file" && cmp -s "$snapshot.minisig" "$channel_file.minisig" || die "Channel changed during publication"
  else
    [[ ! -e "$channel_file" && ! -e "$channel_file.minisig" ]] || die "Channel appeared during publication"
  fi
done
RELEASE_DEST="$WWW/$RELEASE_RELATIVE"
if [[ -e "$RELEASE_DEST" ]]; then
  # Reuse an identical release across channels without rewriting its signatures.
  python3 - "$SCRIPT_DIR" "$STAGE/upload/$RELEASE_RELATIVE" "$RELEASE_DEST" "$PUBLIC_KEYS_DIR" <<'PY'
import hashlib,sys
from pathlib import Path
sys.path.insert(0,sys.argv[1]+'/lib')
from verify import artifact
source,destination=map(Path,sys.argv[2:4])
if destination.is_symlink(): raise SystemExit('unsafe release destination')
for file in source.iterdir():
    if file.name.endswith(('.minisig','.sha256')): continue
    existing=destination/file.name
    artifact(existing,sys.argv[4])
    if hashlib.sha256(file.read_bytes()).digest()!=hashlib.sha256(existing.read_bytes()).digest():
        raise SystemExit('immutable release violation: existing release path has different content')
PY
fi
if [[ ${#RSYNC_TARGETS[@]} -gt 0 ]]; then
  mkdir -p "$STAGE/upload/public-keys" "$STAGE/upload/lib"
  python3 - "$SCRIPT_DIR" "$PUBLIC_KEYS_DIR" "$STAGE/upload/public-keys" <<'PY'
import shutil,sys
from pathlib import Path
sys.path.insert(0,sys.argv[1]+'/lib')
from verify import keys
for key in keys(sys.argv[2]): shutil.copyfile(key,Path(sys.argv[3])/key.name)
PY
  cp -- "$SCRIPT_DIR/lib/remote.py" "$SCRIPT_DIR/lib/activate.py" "$SCRIPT_DIR/lib/verify.py" "$SCRIPT_DIR/lib/registry.py" "$STAGE/upload/lib/"
  cp -- "$REGISTRY_FILE" "$STAGE/upload/registry.json"
  incoming=".publish-incoming.${STAGE##*.publish.}"
  for target in "${RSYNC_TARGETS[@]}"; do
    host="${target%%:*}" remote_root="${target#*:}"
    REMOTE_HOSTS+=("$host") REMOTE_PATHS+=("$remote_root/$incoming")
    ssh -o StrictHostKeyChecking=yes "$host" "mkdir -p '$remote_root/$incoming' && chmod 700 '$remote_root/$incoming'"
    rsync -a -e 'ssh -o StrictHostKeyChecking=yes' "$STAGE/upload/" "$host:$remote_root/$incoming/"
    ssh -o StrictHostKeyChecking=yes "$host" "python3 '$remote_root/$incoming/lib/remote.py' '$remote_root' '$incoming' '$RELEASE_RELATIVE' '$CHANNEL_JSON'"
  done
fi
if [[ ! -e "$RELEASE_DEST" ]]; then
  mkdir -p -- "$(dirname "$RELEASE_DEST")"
  mv -- "$STAGE/upload/$RELEASE_RELATIVE" "$RELEASE_DEST"
  chmod 755 "$WWW/releases" "$RELEASE_DEST"
  if [[ "$RELEASE_RELATIVE" == releases/*/* ]]; then chmod 755 "$(dirname "$RELEASE_DEST")"; fi
fi
python3 "$SCRIPT_DIR/lib/activate.py" "$PUBLIC_KEYS_DIR" "$CHANNEL_CANDIDATE" "$WWW_CHANNEL" "$SOURCE_CANDIDATE" "$REPO_CHANNEL"
echo "[INFO] Published $PRODUCT $CHANNEL v$VERSION: https://update.neosecra.com/$RELEASE_RELATIVE/$ARCHIVE_NAME"
