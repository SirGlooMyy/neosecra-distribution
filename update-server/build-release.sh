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
OUTPUT_DIR="${SCRIPT_DIR}/www/releases/${VERSION}"
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
git ls-files | while IFS= read -r f; do
    mkdir -p "${ARCHIVE_ROOT}/$(dirname "$f")"
    cp -a "$f" "${ARCHIVE_ROOT}/$f"
done

# Ensure CA certificate is included in archive (for client-side TLS verification)
if [[ -d update-server/ca ]]; then
  mkdir -p "${ARCHIVE_ROOT}/update-server/ca"
  cp -a update-server/ca/update-neosecra-com-root.crt "${ARCHIVE_ROOT}/update-server/ca/" 2>/dev/null || true
fi
if [[ -d deployment/ca ]]; then
  mkdir -p "${ARCHIVE_ROOT}/deployment/ca"
  cp -a deployment/ca/update-neosecra-com-root.crt "${ARCHIVE_ROOT}/deployment/ca/" 2>/dev/null || true
fi

echo "[build-release] Stamping version ${VERSION}..."
echo "${VERSION}" > "${ARCHIVE_ROOT}/deployment/VERSION"

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
MANIFEST="${ARCHIVE_ROOT}/deployment/release-manifest.yaml"
if [[ -f "$MANIFEST" ]]; then
    RELEASE_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    DB_REVISION=""

    # Try to get revision from alembic if available
    ASSESSMENT_REPO="${REPO_ROOT}/../neosecra-assessment"
    if [[ -d "${ASSESSMENT_REPO}/backend" ]]; then
        DB_REVISION=$(cd "${ASSESSMENT_REPO}/backend" && \
            DATABASE_URL=sqlite+aiosqlite:///:memory: alembic heads 2>/dev/null | awk '/\(head\)/{print $1}' || true)
    fi

    sed -i "s/^version:.*/version: ${VERSION}/" "$MANIFEST"
    sed -i "s|security-health-backend:[0-9.]*\$|security-health-backend:${VERSION}|g" "$MANIFEST"
    sed -i "s|security-health-frontend:[0-9.]*\$|security-health-frontend:${VERSION}|g" "$MANIFEST"

    # U7: Add or update script_checksums, release_date, database_revision fields
    if grep -q '^script_checksums:' "$MANIFEST"; then
        sed -i "s/^script_checksums:.*/script_checksums: \"${SCRIPT_CHECKSUMS}\"/" "$MANIFEST"
    else
        sed -i "/^database_revision:/a script_checksums: \"${SCRIPT_CHECKSUMS}\"" "$MANIFEST"
    fi

    if grep -q '^release_date:' "$MANIFEST"; then
        sed -i "s/^release_date:.*/release_date: \"${RELEASE_DATE}\"/" "$MANIFEST"
    else
        sed -i "/^script_checksums:/a release_date: \"${RELEASE_DATE}\"" "$MANIFEST"
    fi

    if [[ -n "$DB_REVISION" ]]; then
        sed -i "s/^database_revision:.*/database_revision: \"${DB_REVISION}\"/" "$MANIFEST"
    fi

    echo "[build-release] Manifest stamped:"
    grep -E '^(version:|database_revision:|script_checksums:|release_date:)' "$MANIFEST" | sed 's/^/  /'
fi

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
