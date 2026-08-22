#!/usr/bin/env bash
# NeoSecra Update Server — Build distribution release archive
# Usage: build-release.sh <version>
# Output: update-server/www/releases/<version>/distribution.tar.gz
set -euo pipefail

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
    echo "Usage: $0 <version>"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# Default publishes into the update-server web tree; override with
# NEOSECRA_BUILD_OUTPUT_DIR for local/test builds (keeps www/releases clean).
OUTPUT_DIR="${NEOSECRA_BUILD_OUTPUT_DIR:-${SCRIPT_DIR}/www/releases/${VERSION}}"
ARCHIVE_NAME="distribution.tar.gz"
ARCHIVE_DIRNAME="neosecra-distribution-${VERSION}"

echo "[build-release] Building distribution archive for v${VERSION}"

# Create temp working directory
TMP_DIR="$(mktemp -d)"
trap "rm -rf '${TMP_DIR}'" EXIT

# Create the archive root directory
ARCHIVE_ROOT="${TMP_DIR}/${ARCHIVE_DIRNAME}"
mkdir -p "${ARCHIVE_ROOT}"

# Copy repository contents into archive root
echo "[build-release] Copying repository contents..."
cd "${REPO_ROOT}"

# Copy only tracked files to avoid .git, secrets, etc.
# Exclude the entire update-server/ tree: it is the *publisher* (build/sign/
# serve tooling plus previously-published artifacts). It is not customer
# payload, bloats the archive with nested tarballs and old bootstrap.sh copies,
# and its build scripts (this one) carry ghcr.io patterns that must NOT be
# rewritten by the stamping step below. The CA cert is added separately.
git ls-files | while IFS= read -r f; do
    case "$f" in
        update-server/*) continue ;;
    esac
    mkdir -p "${ARCHIVE_ROOT}/$(dirname "$f")"
    cp -a "$f" "${ARCHIVE_ROOT}/$f"
done

# Ensure CA certificate is included in archive (for client-side TLS verification).
# The runtime (bootstrap/upgrade) reads it from deployment/ca/, which is the
# only copy shipped. update-server/ is excluded below as it is the publisher,
# not customer payload, and its build-tool scripts would otherwise self-collide
# with the ghcr stamping step below.
if [[ -d deployment/ca ]]; then
  mkdir -p "${ARCHIVE_ROOT}/deployment/ca"
  cp -a deployment/ca/update-neosecra-com-root.crt "${ARCHIVE_ROOT}/deployment/ca/" 2>/dev/null || true
fi

echo "[build-release] Stamping version ${VERSION}..."
echo "${VERSION}" > "${ARCHIVE_ROOT}/deployment/VERSION"

# Stamp the shipped v1 subtree as well: v1/VERSION and
# v1/release-manifest.yaml are what the installed preflight compares
# (lib/common.sh VERSION_FILE/MANIFEST_FILE resolve under v1/). 1.3.45
# shipped v1/VERSION=1.3.44 + manifest version 1.3.2 -> preflight
# "Version mismatch" on every fresh install.
if [[ -d "${ARCHIVE_ROOT}/deployment/v1" ]]; then
    echo "${VERSION}" > "${ARCHIVE_ROOT}/deployment/v1/VERSION"
fi

# U7: Compute script checksums for the manifest
SCRIPT_CHECKSUMS=""
checksum_script() {
    local path="$1"
    if [[ -f "${ARCHIVE_ROOT}/$path" ]]; then
        local hash
        hash=$(sha256sum "${ARCHIVE_ROOT}/$path" | cut -d' ' -f1)
        SCRIPT_CHECKSUMS="${SCRIPT_CHECKSUMS}${path}=${hash},"
    fi
}
checksum_script "deployment/upgrade/upgrade.sh"
checksum_script "deployment/install/preflight.sh"
checksum_script "deployment/install/postflight.sh"
checksum_script "deployment/lib/common.sh"
checksum_script "deployment/lib/manifest.sh"
checksum_script "deployment/lib/state.sh"
checksum_script "deployment/lib/docker.sh"
checksum_script "deployment/lib/logging.sh"
checksum_script "deployment/upgrade/rollback.sh"
checksum_script "bootstrap.sh"
# Strip trailing comma
SCRIPT_CHECKSUMS="${SCRIPT_CHECKSUMS%,}"

# Update release-manifest.yaml version, image refs, script checksums, release date
# Stamps BOTH the top-level manifest and the shipped v1 subtree manifest (the
# v1 manifest is the one preflight/install actually reads on customer hosts).
MANIFESTS=("${ARCHIVE_ROOT}/deployment/release-manifest.yaml" "${ARCHIVE_ROOT}/deployment/v1/release-manifest.yaml")
RELEASE_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
DB_REVISION=""

# Try to get revision from alembic if available
ASSESSMENT_REPO="${REPO_ROOT}/../neosecra-assessment"
if [[ -d "${ASSESSMENT_REPO}/backend" ]]; then
    DB_REVISION=$(cd "${ASSESSMENT_REPO}/backend" && \
        DATABASE_URL=sqlite+aiosqlite:///:memory: alembic heads 2>/dev/null | awk '/\(head\)/{print $1}' || true)
fi

for MANIFEST in "${MANIFESTS[@]}"; do
if [[ -f "$MANIFEST" ]]; then
    sed -i "s/^version:.*/version: ${VERSION}/" "$MANIFEST"
    sed -i "s|security-health-backend:[0-9.]*\$|security-health-backend:${VERSION}|g" "$MANIFEST"
    sed -i "s|security-health-frontend:[0-9.]*\$|security-health-frontend:${VERSION}|g" "$MANIFEST"

    # U7: script_checksums only on the top-level manifest (the v1 manifest
    # schema predates that field; keep the shipped v1 manifest minimal).
    # NOTE: | delimiter — SCRIPT_CHECKSUMS contains / (paths like deployment/upgrade/upgrade.sh=...)
    if [[ "$MANIFEST" == "${ARCHIVE_ROOT}/deployment/release-manifest.yaml" ]]; then
        if grep -q '^script_checksums:' "$MANIFEST"; then
            sed -i "s|^script_checksums:.*|script_checksums: \"${SCRIPT_CHECKSUMS}\"|" "$MANIFEST"
        else
            sed -i "/^database_revision:/a script_checksums: \"${SCRIPT_CHECKSUMS}\"" "$MANIFEST"
        fi
    fi

    if grep -q '^release_date:' "$MANIFEST"; then
        sed -i "s|^release_date:.*|release_date: \"${RELEASE_DATE}\"|" "$MANIFEST"
    elif grep -q '^script_checksums:' "$MANIFEST"; then
        sed -i "/^script_checksums:/a release_date: \"${RELEASE_DATE}\"" "$MANIFEST"
    else
        sed -i "/^database_revision:/a release_date: \"${RELEASE_DATE}\"" "$MANIFEST"
    fi

    if [[ -n "$DB_REVISION" ]]; then
        sed -i "s|^database_revision:.*|database_revision: \"${DB_REVISION}\"|" "$MANIFEST"
    fi

    echo "[build-release] Manifest stamped (${MANIFEST#"${ARCHIVE_ROOT}"/}):"
    grep -E '^(version:|database_revision:|script_checksums:|release_date:)' "$MANIFEST" | sed 's/^/  /'
fi
done

# U9: Pin every image reference to registry.neosecra.com and assert the archive
# carries NO ghcr.io reference in any artifact. The 1.3.13 regression was caused
# by stale ghcr refs leaking into .env.v1; this is the hard contract that
# prevents recurrence. Two rewrites:
#   1. ghcr.io/sirgloomyy/neosecra-assessment/<img>  -> registry.neosecra.com/<img>
#   2. residual bare ghcr.io (login/firewall prose)   -> registry.neosecra.com
echo "[build-release] Stamping image refs -> registry.neosecra.com ..."
while IFS= read -r -d '' f; do
    sed -i \
        -e 's|ghcr.io/sirgloomyy/neosecra-assessment|registry.neosecra.com|g' \
        -e 's|ghcr\.io|registry.neosecra.com|g' "$f"
done < <(grep -rIl --null 'ghcr\.io' "$ARCHIVE_ROOT" 2>/dev/null || true)

# Hard contract: no ghcr.io may remain in the shipped archive.
mapfile -t -d '' GHCR_HITS < <(grep -rIl --null 'ghcr\.io' "$ARCHIVE_ROOT" 2>/dev/null || true)
if [[ ${#GHCR_HITS[@]} -ne 0 ]]; then
    echo "[build-release] ERROR: ghcr.io references remain in archive after stamping:" >&2
    printf '  %s\n' "${GHCR_HITS[@]}" >&2
    exit 1
fi
echo "[build-release] Verified: no ghcr.io references in archive"

# Create the tarball
echo "[build-release] Creating archive..."
mkdir -p "${OUTPUT_DIR}"
cd "${TMP_DIR}"
tar czf "${OUTPUT_DIR}/${ARCHIVE_NAME}" "${ARCHIVE_DIRNAME}"

# Show result
echo "[build-release] Archive created: ${OUTPUT_DIR}/${ARCHIVE_NAME}"
echo "[build-release] Size: $(du -h "${OUTPUT_DIR}/${ARCHIVE_NAME}" | cut -f1)"
echo "[build-release] Contents:"
tar tzf "${OUTPUT_DIR}/${ARCHIVE_NAME}" | head -20 || true
echo "[build-release] Done."
