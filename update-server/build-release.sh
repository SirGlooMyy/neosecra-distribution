#!/usr/bin/env bash
# NeoSecra Update Server - build the signed-channel release archive for Assessment.
#
# Usage:
#   build-release.sh --version X.Y.Z --product-root <Assessment checkout> \
#       --images-lock <images.lock> [--output <file>] [--release-date YYYY-MM-DDTHH:MM:SSZ]
#
# The archive is assembled by lib/assessment_package.py from the product files
# Assessment owns (compose, DAST overlay, env template, release manifest, nginx
# config, scanner scripts) and the shared runtime this repository owns (agent,
# upgrade, lib, install, backup, bin, smoke-tests, schemas, ca).  It carries ONE
# release manifest (stamped with version, database head, trust_policy and the
# digests of the image lock) and release/images.lock.  The version comes from the
# argument; no VERSION file of either repository is modified.
#
# images.lock is produced from real, pushed images by make-images-lock.sh.
# Output (default): dist/distribution-<version>.tar.gz
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
VERSION="" PRODUCT_ROOT="" IMAGES_LOCK="" OUTPUT="" RELEASE_DATE=""

usage() { sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'; }
die() { echo "[build-release] ERROR: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) VERSION="${2:-}"; shift 2 ;;
    --product-root) PRODUCT_ROOT="${2:-}"; shift 2 ;;
    --images-lock) IMAGES_LOCK="${2:-}"; shift 2 ;;
    --output) OUTPUT="${2:-}"; shift 2 ;;
    --release-date) RELEASE_DATE="${2:-}"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) usage >&2; die "unknown option: $1" ;;
  esac
done
[[ -n "$VERSION" && -n "$PRODUCT_ROOT" && -n "$IMAGES_LOCK" ]] || { usage >&2; die "--version, --product-root and --images-lock are required"; }
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "version must be numeric semver X.Y.Z"
[[ -d "$PRODUCT_ROOT/deployment/v1" ]] || die "not an Assessment checkout: $PRODUCT_ROOT"
[[ -f "$IMAGES_LOCK" ]] || die "image lock not found: $IMAGES_LOCK"
[[ -n "$OUTPUT" ]] || OUTPUT="${NEOSECRA_BUILD_OUTPUT_DIR:-${REPO_ROOT}/dist}/distribution-${VERSION}.tar.gz"

if [[ -n "${PYTHON_BIN:-}" ]]; then PYTHON="$PYTHON_BIN"
elif command -v python3 >/dev/null 2>&1 && python3 -c 'import sys' >/dev/null 2>&1; then PYTHON=python3
elif command -v python >/dev/null 2>&1 && python -c 'import sys' >/dev/null 2>&1; then PYTHON=python
else die "python3 is required"; fi

commit_of() { git -C "$1" rev-parse HEAD 2>/dev/null || true; }
ARGS=(build --version "$VERSION" --product-root "$PRODUCT_ROOT" --shared-root "$REPO_ROOT"
      --images-lock "$IMAGES_LOCK" --output "$OUTPUT")
[[ -z "$RELEASE_DATE" ]] || ARGS+=(--release-date "$RELEASE_DATE")
BUILD_COMMIT="$(commit_of "$PRODUCT_ROOT")"; [[ -z "$BUILD_COMMIT" ]] || ARGS+=(--build-commit "$BUILD_COMMIT")
DIST_COMMIT="$(commit_of "$REPO_ROOT")"; [[ -z "$DIST_COMMIT" ]] || ARGS+=(--distribution-commit "$DIST_COMMIT")

echo "[build-release] Assembling Assessment ${VERSION} (product ${PRODUCT_ROOT})"
"$PYTHON" "${SCRIPT_DIR}/lib/assessment_package.py" "${ARGS[@]}"
echo "[build-release] Validated with the publisher's archive checks (links, secrets, single manifest, trust_policy)."
echo "[build-release] Next: publish.sh --product assessment --channel candidate --version ${VERSION} --archive ${OUTPUT} --images-lock ${IMAGES_LOCK} --dry-run"
