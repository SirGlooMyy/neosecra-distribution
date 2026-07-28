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
# The CA cert is referenced by upgrade.sh via SCRIPT_DIR/../ca/
if [[ -d update-server/ca ]]; then
  mkdir -p "${ARCHIVE_ROOT}/update-server/ca"
  cp -a update-server/ca/update-neosecra-com-root.crt "${ARCHIVE_ROOT}/update-server/ca/" 2>/dev/null || true
fi
if [[ -d deployment/ca ]]; then
  mkdir -p "${ARCHIVE_ROOT}/deployment/ca"
  cp -a deployment/ca/update-neosecra-com-root.crt "${ARCHIVE_ROOT}/deployment/ca/" 2>/dev/null || true
fi


# Also include untracked deployment/ files that are needed
# (git-ls-files already covers tracked files)

# Stamp version into deployment/VERSION and release-manifest.yaml
echo "[build-release] Stamping version ${VERSION}..."
echo "${VERSION}" > "${ARCHIVE_ROOT}/deployment/VERSION"

# Update release-manifest.yaml version and image refs
MANIFEST="${ARCHIVE_ROOT}/deployment/release-manifest.yaml"
if [[ -f "$MANIFEST" ]]; then
    sed -i "s/^version:.*/version: ${VERSION}/" "$MANIFEST"
    sed -i "s|security-health-backend:[0-9.]*\$|security-health-backend:${VERSION}|g" "$MANIFEST"
    sed -i "s|security-health-frontend:[0-9.]*\$|security-health-frontend:${VERSION}|g" "$MANIFEST"
    echo "[build-release] Manifest stamped: $(grep '^version:' "$MANIFEST")"
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
tar tzf "${OUTPUT_DIR}/${ARCHIVE_NAME}" | head -20 || true  # SIGPIPE under pipefail is cosmetic-only here
echo "[build-release] Done."
