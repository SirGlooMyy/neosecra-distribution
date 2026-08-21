#!/usr/bin/env bash
# NeoSecra Update Server — Publish a release
# Stage artifacts, sign them, update channel JSON, and optionally rsync.
set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults
# --------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_WWW="${SCRIPT_DIR}/www"
DEFAULT_KEY="${HOME}/.neosecra/update-signing.key"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CHANNELS_REPO_DIR="${REPO_ROOT}/channels"
PUBLIC_KEYS_DIR="${REPO_ROOT}/public-keys"
BASE_URL="https://update.neosecra.com"

# ---------------------------------------------------------------------------
# Help / usage
# ---------------------------------------------------------------------------
usage() {
    cat <<EOF
Usage: $(basename "$0") --product <product> --channel <channel> --version <semver> --archive <path> [options]

Required:
  --product <product>    Product name, e.g. "assessment"
  --channel <channel>    Channel name, e.g. "stable" (-> <product>-<channel>.json)
  --version <semver>     Semantic version, e.g. 1.1.2 (must match ^[0-9]+\.[0-9]+\.[0-9]+$)
  --archive <path>       Path to distribution.tar.gz

Options:
  --bundle <path>        Path to docker-bundle-<version>.tar.zst (optional)
  --key <path>           Minisign secret key (default: ${DEFAULT_KEY})
  --www <path>           WWW directory (default: ${DEFAULT_WWW})
  --rsync <target>       rsync target, e.g. user@host:/srv/update
  --dry-run              Print actions without executing
  --help                 Show this help and exit

Environment:
  UPDATE_SERVER_TARGETS   Space-separated rsync targets (alternative to --rsync).
                          When combined with --rsync, all targets are synced.
                          Example: UPDATE_SERVER_TARGETS="user@lab:/srv/update user@public:/srv/update"
EOF
    exit 0
}

# ---------------------------------------------------------------------------
# Parse arguments
# --------------------------------------------------------------------------
PRODUCT=""
CHANNEL=""
VERSION=""
ARCHIVE=""
BUNDLE=""
KEY="${DEFAULT_KEY}"
WWW="${DEFAULT_WWW}"
RSYNC_TARGET=""
DRY_RUN=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --product)   PRODUCT="$2";  shift 2 ;;
        --channel)   CHANNEL="$2";  shift 2 ;;
        --version)   VERSION="$2";  shift 2 ;;
        --archive)   ARCHIVE="$2";  shift 2 ;;
        --bundle)    BUNDLE="$2";   shift 2 ;;
        --key)       KEY="$2";      shift 2 ;;
        --www)       WWW="$2";      shift 2 ;;
        --rsync)     RSYNC_TARGET="$2"; shift 2 ;;
        --dry-run)   DRY_RUN=1;     shift ;;
        --help)      usage ;;
        *) echo "[ERROR] Unknown argument: $1"; usage ;;
    esac
done

# ---------------------------------------------------------------------------
# Validate required args
# --------------------------------------------------------------------------
FAIL=""
[[ -z "$PRODUCT" ]] && { echo "[ERROR] --product is required"; FAIL=1; }
[[ -z "$CHANNEL" ]] && { echo "[ERROR] --channel is required"; FAIL=1; }
[[ -z "$VERSION" ]] && { echo "[ERROR] --version is required"; FAIL=1; }
[[ -z "$ARCHIVE" ]] && { echo "[ERROR] --archive is required"; FAIL=1; }
[[ -n "$FAIL" ]] && exit 1

# Validate semver
if ! echo "$VERSION" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    echo "[ERROR] --version must match ^[0-9]+\.[0-9]+\.[0-9]+$ (got: $VERSION)"
    exit 1
fi

# ---------------------------------------------------------------------------
# Preflight: required tools
# --------------------------------------------------------------------------
PREREQ_MISSING=0
check_prereq() {
    local cmd="$1"
    local hint="${2:-}"
    if ! command -v "$cmd" &>/dev/null; then
        echo "[ERROR] Required tool not found: ${cmd}${hint:+ (${hint})}"
        PREREQ_MISSING=1
    fi
}

check_prereq "minisign" "Install or download the static binary to ~/.local/bin"
check_prereq "sha256sum"
check_prereq "python3" "Preferred for JSON editing"

if command -v python3 &>/dev/null; then
    JSON_EDITOR="python3"
elif command -v jq &>/dev/null; then
    JSON_EDITOR="jq"
else
    echo "[ERROR] At least one of python3 or jq is required for JSON editing."
    PREREQ_MISSING=1
fi

[[ $PREREQ_MISSING -ne 0 ]] && exit 1

# ---------------------------------------------------------------------------
# Preflight: files exist
# --------------------------------------------------------------------------
[[ -f "$ARCHIVE" ]] || { echo "[ERROR] Archive not found: $ARCHIVE"; exit 1; }
[[ -n "$BUNDLE" && ! -f "$BUNDLE" ]] && { echo "[ERROR] Bundle not found: $BUNDLE"; exit 1; }

BOOTSTRAP_SRC="${REPO_ROOT}/bootstrap.sh"
if [[ -f "$BOOTSTRAP_SRC" ]]; then
    BOOTSTRAP_BASENAME="bootstrap.sh"
else
    BOOTSTRAP_BASENAME=""
    echo "[WARN] bootstrap.sh not found at ${BOOTSTRAP_SRC}; will not stage it."
fi

# ---------------------------------------------------------------------------
# Preflight: signing key
# --------------------------------------------------------------------------
if [[ ! -f "$KEY" ]]; then
    echo "[ERROR] Minisign secret key not found: ${KEY}"
    echo "        Generate one with: minisign -G -s ${KEY} -p ${PUBLIC_KEYS_DIR}/update-neosecra-com.pub"
    exit 1
fi

# ---------------------------------------------------------------------------
# Dry-run helpers
# --------------------------------------------------------------------------
log() {
    if [[ $DRY_RUN -eq 1 ]]; then
        echo "[DRY-RUN] $*"
    else
        echo "[INFO] $*"
    fi
}

run_cmd() {
    if [[ $DRY_RUN -eq 1 ]]; then
        echo "[DRY-RUN]" "$@"
    else
        "$@"
    fi
}

# ---------------------------------------------------------------------------
# Determine paths
# --------------------------------------------------------------------------
CHANNEL_NAME="${PRODUCT}-${CHANNEL}"
CHANNEL_JSON="${CHANNEL_NAME}.json"
CHANNEL_SIG="${CHANNEL_JSON}.minisig"

WWW_CHANNELS="${WWW}/channels"
WWW_RELEASES="${WWW}/releases"
WWW_RELEASE_DIR="${WWW_RELEASES}/${VERSION}"
WWW_CHANNEL_FILE="${WWW_CHANNELS}/${CHANNEL_JSON}"
WWW_CHANNEL_SIG="${WWW_CHANNELS}/${CHANNEL_SIG}"

REPO_CHANNEL_FILE="${CHANNELS_REPO_DIR}/${CHANNEL_JSON}"

ARCHIVE_BASENAME="$(basename "$ARCHIVE")"
ARCHIVE_SHA_FILE="${ARCHIVE_BASENAME}.sha256"
ARCHIVE_SIG_FILE="${ARCHIVE_BASENAME}.minisig"

BUNDLE_BASENAME=""
BUNDLE_SHA_FILE=""
BUNDLE_SIG_FILE=""
if [[ -n "$BUNDLE" ]]; then
    BUNDLE_BASENAME="$(basename "$BUNDLE")"
    BUNDLE_SHA_FILE="${BUNDLE_BASENAME}.sha256"
    BUNDLE_SIG_FILE="${BUNDLE_BASENAME}.minisig"
fi

BOOTSTRAP_SHA_FILE=""
BOOTSTRAP_SIG_FILE=""
if [[ -n "$BOOTSTRAP_BASENAME" ]]; then
    BOOTSTRAP_SHA_FILE="${BOOTSTRAP_BASENAME}.sha256"
    BOOTSTRAP_SIG_FILE="${BOOTSTRAP_BASENAME}.minisig"
fi

# ---------------------------------------------------------------------------
# Print summary
# --------------------------------------------------------------------------
echo "========================================"
echo " NeoSecra Update — Publish Summary"
echo "========================================"
echo " Product:        ${PRODUCT}"
echo " Channel:        ${CHANNEL}"
echo " Version:        ${VERSION}"
echo " Archive:        ${ARCHIVE}"
echo " Bundle:         ${BUNDLE:-<not provided>}"
echo " Bootstrap:      ${BOOTSTRAP_BASENAME:-<not found>}"
echo " Key:            ${KEY}"
echo " WWW dir:        ${WWW}"
echo " Channel file:   ${WWW_CHANNEL_FILE}"
echo " Release dir:    ${WWW_RELEASE_DIR}"
echo " RSYNC target:   ${RSYNC_TARGET:-<none>}"
echo " JSON editor:    ${JSON_EDITOR}"
echo " Dry-run:        ${DRY_RUN}"
echo "========================================"

if [[ $DRY_RUN -eq 1 ]]; then
    echo ""
    echo "[DRY-RUN] Actions that would be performed:"
fi

# ---------------------------------------------------------------------------
# 1. Stage release artifacts into www/releases/<version>/
# --------------------------------------------------------------------------
log "Create release directory: ${WWW_RELEASE_DIR}"
run_cmd mkdir -p "${WWW_RELEASE_DIR}"

log "Copy archive: ${ARCHIVE} -> ${WWW_RELEASE_DIR}/"
run_cmd cp "${ARCHIVE}" "${WWW_RELEASE_DIR}/"

if [[ -n "$BOOTSTRAP_BASENAME" ]]; then
    log "Copy bootstrap: ${BOOTSTRAP_SRC} -> ${WWW_RELEASE_DIR}/"
    run_cmd cp "${BOOTSTRAP_SRC}" "${WWW_RELEASE_DIR}/"
fi

if [[ -n "$BUNDLE" ]]; then
    log "Copy bundle: ${BUNDLE} -> ${WWW_RELEASE_DIR}/"
    run_cmd cp "${BUNDLE}" "${WWW_RELEASE_DIR}/"
fi

# Generate .sha256
log "Generate SHA256: ${WWW_RELEASE_DIR}/${ARCHIVE_SHA_FILE}"
run_cmd sh -c "cd '${WWW_RELEASE_DIR}' && sha256sum '${ARCHIVE_BASENAME}' > '${ARCHIVE_SHA_FILE}'"

if [[ -n "$BOOTSTRAP_BASENAME" ]]; then
    log "Generate SHA256: ${WWW_RELEASE_DIR}/${BOOTSTRAP_SHA_FILE}"
    run_cmd sh -c "cd '${WWW_RELEASE_DIR}' && sha256sum '${BOOTSTRAP_BASENAME}' > '${BOOTSTRAP_SHA_FILE}'"
fi

if [[ -n "$BUNDLE" ]]; then
    log "Generate SHA256: ${WWW_RELEASE_DIR}/${BUNDLE_SHA_FILE}"
    run_cmd sh -c "cd '${WWW_RELEASE_DIR}' && sha256sum '${BUNDLE_BASENAME}' > '${BUNDLE_SHA_FILE}'"
fi

# Minisign
log "Sign archive: ${WWW_RELEASE_DIR}/${ARCHIVE_BASENAME}"
run_cmd minisign -S -s "${KEY}" -m "${WWW_RELEASE_DIR}/${ARCHIVE_BASENAME}" \
    -t "NeoSecra ${PRODUCT} ${CHANNEL} v${VERSION}"

if [[ -n "$BOOTSTRAP_BASENAME" ]]; then
    log "Sign bootstrap: ${WWW_RELEASE_DIR}/${BOOTSTRAP_BASENAME}"
    run_cmd minisign -S -s "${KEY}" -m "${WWW_RELEASE_DIR}/${BOOTSTRAP_BASENAME}" \
        -t "NeoSecra ${PRODUCT} ${CHANNEL} v${VERSION} bootstrap"
fi

if [[ -n "$BUNDLE" ]]; then
    log "Sign bundle: ${WWW_RELEASE_DIR}/${BUNDLE_BASENAME}"
    run_cmd minisign -S -s "${KEY}" -m "${WWW_RELEASE_DIR}/${BUNDLE_BASENAME}" \
        -t "NeoSecra ${PRODUCT} ${CHANNEL} v${VERSION} docker bundle"
fi

# ---------------------------------------------------------------------------
# 2. Update channel JSON
# --------------------------------------------------------------------------
log "Update channel JSON: ${WWW_CHANNEL_FILE}"

if [[ $DRY_RUN -eq 1 ]]; then
    echo "[DRY-RUN] Would seed channel JSON from ${REPO_CHANNEL_FILE} if ${WWW_CHANNEL_FILE} does not exist"
    echo "[DRY-RUN] Would update current_version=${VERSION}, updated=<now UTC>"
    echo "[DRY-RUN] Would add/replace release entry for version ${VERSION}"
    echo "[DRY-RUN] Would sign channel JSON"
else
    # Seed from repo if www copy doesn't exist
    if [[ ! -f "${WWW_CHANNEL_FILE}" ]]; then
        if [[ -f "${REPO_CHANNEL_FILE}" ]]; then
            log "Seeding ${WWW_CHANNEL_FILE} from ${REPO_CHANNEL_FILE}"
            cp "${REPO_CHANNEL_FILE}" "${WWW_CHANNEL_FILE}"
        else
            echo "[ERROR] Channel file not found in repo: ${REPO_CHANNEL_FILE}"
            echo "        Create it first in channels/ directory."
            exit 1
        fi
    fi

    # Build release entry data
    ARCHIVE_SIZE=$(stat -c%s "${WWW_RELEASE_DIR}/${ARCHIVE_BASENAME}" 2>/dev/null || echo "0")
    ARCHIVE_SHA256=$(cut -d' ' -f1 "${WWW_RELEASE_DIR}/${ARCHIVE_SHA_FILE}")

    BOOTSTRAP_SIZE=""
    BOOTSTRAP_SHA256=""
    if [[ -n "$BOOTSTRAP_BASENAME" ]]; then
        BOOTSTRAP_SIZE=$(stat -c%s "${WWW_RELEASE_DIR}/${BOOTSTRAP_BASENAME}" 2>/dev/null || echo "0")
        BOOTSTRAP_SHA256=$(cut -d' ' -f1 "${WWW_RELEASE_DIR}/${BOOTSTRAP_SHA_FILE}")
    fi

    BUNDLE_SIZE=""
    BUNDLE_SHA256=""
    if [[ -n "$BUNDLE" ]]; then
        BUNDLE_SIZE=$(stat -c%s "${WWW_RELEASE_DIR}/${BUNDLE_BASENAME}" 2>/dev/null || echo "0")
        BUNDLE_SHA256=$(cut -d' ' -f1 "${WWW_RELEASE_DIR}/${BUNDLE_SHA_FILE}")
    fi

    RELEASED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    # Temp file on same filesystem for atomic mv
    TMPFILE=$(mktemp "${WWW_CHANNEL_FILE}.tmp.XXXXXX")
    # shellcheck disable=SC2064
    trap "rm -f '${TMPFILE}'" EXIT

    # Use python3 for safe JSON editing
    python3 -c '
import json, sys

inpath  = sys.argv[1]
outpath = sys.argv[2]
version = sys.argv[3]
released_at = sys.argv[4]

archive_url      = sys.argv[5]
archive_sha256   = sys.argv[6]
archive_size     = int(sys.argv[7])
archive_sig_url  = sys.argv[8]

bootstrap_url     = sys.argv[9]
bootstrap_sha256  = sys.argv[10]
bootstrap_size    = int(sys.argv[11])
bootstrap_sig_url = sys.argv[12]

bundle_url     = sys.argv[13]
bundle_sha256  = sys.argv[14]
bundle_size    = int(sys.argv[15])
bundle_sig_url = sys.argv[16]

with open(inpath, "r") as f:
    channel = json.load(f)

channel["current_version"] = version
channel["updated"] = released_at

# Build new release entry — extends existing keys, never removes them
new_rel = {
    "version": version,
    "released_at": released_at,
    "archive": {
        "url": archive_url,
        "sha256": archive_sha256,
        "size_bytes": archive_size,
        "signature_url": archive_sig_url,
    },
    "bootstrap": {
        "url": bootstrap_url,
        "sha256": bootstrap_sha256,
        "size_bytes": bootstrap_size,
        "signature_url": bootstrap_sig_url,
    } if bootstrap_url != "none" else None,
}

if bundle_url != "none":
    new_rel["docker_bundle"] = {
        "url": bundle_url,
        "sha256": bundle_sha256,
        "size_bytes": bundle_size,
        "signature_url": bundle_sig_url,
    }
    # Backward compat: already-deployed backends read the top-level
    # bundle_url field instead of docker_bundle.url — emit both (same value).
    new_rel["bundle_url"] = bundle_url

# Find and update existing entry, or append
found = False
for i, rel in enumerate(channel.get("releases", [])):
    if rel.get("version") == version:
        # Preserve keys in the old entry that are not in the new one
        preserved = {k: v for k, v in rel.items() if k not in new_rel}
        preserved.update(new_rel)
        channel["releases"][i] = preserved
        found = True
        break

if not found:
    channel["releases"].append(new_rel)

with open(outpath, "w") as f:
    json.dump(channel, f, indent=2, ensure_ascii=False)
    f.write("\n")
' \
    "${WWW_CHANNEL_FILE}" "${TMPFILE}" \
    "${VERSION}" "${RELEASED_AT}" \
    "${BASE_URL}/releases/${VERSION}/${ARCHIVE_BASENAME}" \
    "${ARCHIVE_SHA256}" "${ARCHIVE_SIZE}" \
    "${BASE_URL}/releases/${VERSION}/${ARCHIVE_SIG_FILE}" \
    "${BASE_URL}/releases/${VERSION}/${BOOTSTRAP_BASENAME:-none}" \
    "${BOOTSTRAP_SHA256:-0}" "${BOOTSTRAP_SIZE:-0}" \
    "${BASE_URL}/releases/${VERSION}/${BOOTSTRAP_SIG_FILE:-none}" \
    "${BASE_URL}/releases/${VERSION}/${BUNDLE_BASENAME:-none}" \
    "${BUNDLE_SHA256:-0}" "${BUNDLE_SIZE:-0}" \
    "${BASE_URL}/releases/${VERSION}/${BUNDLE_SIG_FILE:-none}"

    # Atomic mv
    mv "${TMPFILE}" "${WWW_CHANNEL_FILE}"
fi

# ---------------------------------------------------------------------------
# 3. Sign channel JSON
# --------------------------------------------------------------------------
if [[ $DRY_RUN -eq 0 ]]; then
    log "Sign channel JSON: ${WWW_CHANNEL_FILE}"
    run_cmd minisign -S -s "${KEY}" -m "${WWW_CHANNEL_FILE}" \
        -t "NeoSecra ${PRODUCT} ${CHANNEL} channel v${VERSION}"
fi

# ---------------------------------------------------------------------------
# 4. Optional rsync to one or more production servers
# --------------------------------------------------------------------------
# Multiple targets can be specified in UPDATE_SERVER_TARGETS env var
# (space-separated), or via the --rsync flag (single target).
# --------------------------------------------------------------------------
RSYNC_TARGETS=()
if [[ -n "${UPDATE_SERVER_TARGETS:-}" ]]; then
  read -ra RSYNC_TARGETS <<< "$UPDATE_SERVER_TARGETS"
fi
if [[ -n "$RSYNC_TARGET" ]]; then
  RSYNC_TARGETS+=("$RSYNC_TARGET")
fi

if [[ ${#RSYNC_TARGETS[@]} -gt 0 ]]; then
  for target in "${RSYNC_TARGETS[@]}"; do
    log "Rsync to ${target}"
    if [[ $DRY_RUN -eq 1 ]]; then
      echo "[DRY-RUN] rsync -az --delete-after ${WWW}/ ${target}"
    else
      run_cmd rsync -az --delete-after "${WWW}/" "${target}"
    fi
  done
fi

# ---------------------------------------------------------------------------
# Summary
# --------------------------------------------------------------------------
echo ""
echo "========================================"
echo " Publish Complete"
echo "========================================"
echo " Channel: ${BASE_URL}/channels/${CHANNEL_JSON}"
echo " Channel signature: ${BASE_URL}/channels/${CHANNEL_SIG}"
echo " Archive: ${BASE_URL}/releases/${VERSION}/${ARCHIVE_BASENAME}"
echo " Archive SHA256: ${BASE_URL}/releases/${VERSION}/${ARCHIVE_SHA_FILE}"
echo " Archive signature: ${BASE_URL}/releases/${VERSION}/${ARCHIVE_SIG_FILE}"
if [[ -n "$BOOTSTRAP_BASENAME" ]]; then
    echo " Bootstrap: ${BASE_URL}/releases/${VERSION}/${BOOTSTRAP_BASENAME}"
    echo " Bootstrap SHA256: ${BASE_URL}/releases/${VERSION}/${BOOTSTRAP_SHA_FILE}"
    echo " Bootstrap signature: ${BASE_URL}/releases/${VERSION}/${BOOTSTRAP_SIG_FILE}"
fi
if [[ -n "$BUNDLE" ]]; then
    echo " Docker bundle: ${BASE_URL}/releases/${VERSION}/${BUNDLE_BASENAME}"
    echo " Docker bundle SHA256: ${BASE_URL}/releases/${VERSION}/${BUNDLE_SHA_FILE}"
    echo " Docker bundle signature: ${BASE_URL}/releases/${VERSION}/${BUNDLE_SIG_FILE}"
fi
echo "========================================"
