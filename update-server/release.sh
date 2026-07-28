#!/usr/bin/env bash
# NeoSecra Distribution — Full release orchestration script
#
# Orchestrates: assessment repo version bump + tag → CI wait → build → publish → rsync
# Usage: release.sh <version> [options]
#
set -euo pipefail

# ============================================================================
# Help
# ============================================================================
usage() {
    cat <<EOF
Usage: $(basename "$0") <version> [options]

Orchestrate a full NeoSecra Security Health release across assessment and
distribution repositories.

Steps:
  [1/5] Bump VERSION + release-manifest.yaml in assessment repo, commit, tag, push
  [2/5] Wait for GitHub Actions CI (security-health-release.yml) to complete
  [3/5] Build distribution archive via build-release.sh
  [4/5] Sign & publish archive via publish.sh
  [5/5] Rsync published artifacts to update server(s)

Arguments:
  <version>          Semantic version (X.Y.Z) to release

Options:
  --assessment-repo <path>   Path to neosecra-assessment repo
                             (default: ../neosecra-assessment relative to repo root)
  --skip-ci-wait             Skip waiting for GitHub CI completion
  --rsync <target>           rsync target for publish.sh (user@host:/path)
  --dry-run                  Print actions without executing anything destructive
  --help                     Show this help and exit

Environment:
  UPDATE_SERVER_TARGETS   Space-separated rsync targets (alternative to --rsync).
                          When combined with --rsync, all targets are synced.

Examples:
  ./release.sh 9.9.9 --dry-run
  ./release.sh 1.4.0 --assessment-repo ~/projects/neosecra-assessment --rsync user@lab:/srv/update
EOF
    exit 0
}

# ============================================================================
# Parse arguments
# ============================================================================
VERSION=""
ASSESSMENT_REPO=""
SKIP_CI_WAIT=0
RSYNC_TARGET=""
DRY_RUN=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --assessment-repo) ASSESSMENT_REPO="$2";  shift 2 ;;
        --skip-ci-wait)    SKIP_CI_WAIT=1;        shift   ;;
        --rsync)           RSYNC_TARGET="$2";     shift 2 ;;
        --dry-run)         DRY_RUN=1;             shift   ;;
        --help)            usage                         ;;
        -*)
            echo "[ERROR] Unknown option: $1"
            usage
            ;;
        *)
            if [[ -z "$VERSION" ]]; then
                VERSION="$1"
            else
                echo "[ERROR] Unexpected argument: $1"
                usage
            fi
            shift
            ;;
    esac
done

# ============================================================================
# Validate
# ============================================================================
if [[ -z "$VERSION" ]]; then
    echo "[ERROR] <version> is required"
    usage
fi
if ! echo "$VERSION" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    echo "[ERROR] Version must be X.Y.Z format (got: $VERSION)"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Resolve assessment repo path — default relative to repo root
if [[ -z "$ASSESSMENT_REPO" ]]; then
    ASSESSMENT_REPO="$(cd "${REPO_ROOT}/../neosecra-assessment" && pwd 2>/dev/null || true)"
fi
if [[ ! -d "$ASSESSMENT_REPO" ]]; then
    echo "[ERROR] Assessment repo not found at: ${ASSESSMENT_REPO}"
    echo "  Specify via --assessment-repo <path>"
    exit 1
fi
ASSESSMENT_REPO="$(cd "$ASSESSMENT_REPO" && pwd)"   # normalize path

# ============================================================================
# Constants / derived paths
# ============================================================================
ASSESSMENT_VERSION_FILE="${ASSESSMENT_REPO}/VERSION"
ASSESSMENT_V1_VERSION_FILE="${ASSESSMENT_REPO}/deployment/v1/VERSION"
MANIFEST_FILE="${ASSESSMENT_REPO}/deployment/v1/release-manifest.yaml"
ALEMBIC_DIR="${ASSESSMENT_REPO}/backend/alembic/versions"
ARCHIVE_DIR="${SCRIPT_DIR}/www/releases/${VERSION}"
TAG="security-health-v${VERSION}"
PRODUCT="assessment"
CHANNEL="stable"

PUBLISH_TMPDIR=""
cleanup() {
    [[ -n "$PUBLISH_TMPDIR" && -d "$PUBLISH_TMPDIR" ]] && rm -rf "$PUBLISH_TMPDIR"
}
trap cleanup EXIT

# ============================================================================
# Helper functions
# ============================================================================
log()     { echo -e "$*"; }
log_step() {
    echo ""
    echo "================================================================================"
    echo "  [$1/$2] $3"
    echo "================================================================================"
}

run_cmd() {
    if [[ $DRY_RUN -eq 1 ]]; then
        echo "[DRY-RUN] $*"
    else
        eval "$@"
    fi
}

guard_gh() {
    if ! command -v gh &>/dev/null; then
        echo "[ERROR] GitHub CLI (gh) is not installed."
        echo "  Install from https://cli.github.com/ or use --skip-ci-wait"
        exit 1
    fi
    if ! gh auth status 2>&1 | grep -q 'Logged in to'; then
        echo "[ERROR] GitHub CLI is not authenticated. Run 'gh auth login' first."
        exit 1
    fi
}

# ============================================================================
# Pre-flight info
# ============================================================================
echo ""
echo "  NeoSecra Release Orchestrator"
echo "  ─────────────────────────────"
echo "  Version:         ${VERSION}"
echo "  Tag:             ${TAG}"
echo "  Assessment repo: ${ASSESSMENT_REPO}"
echo "  Dry-run:         ${DRY_RUN}"
echo ""

# Check if tag already exists in assessment repo (for idempotent re-runs)
TAG_EXISTS=0
if cd "$ASSESSMENT_REPO" && git rev-parse -q --verify "refs/tags/${TAG}" &>/dev/null; then
    TAG_EXISTS=1
    log " [i] Tag '${TAG}' already exists — will skip Step 1 (bump + tag)."
fi

# Read current VERSION from assessment repo
CURRENT_VERSION=""
if [[ -f "$ASSESSMENT_VERSION_FILE" ]]; then
    CURRENT_VERSION="$(cat "$ASSESSMENT_VERSION_FILE" | tr -d '[:space:]')"
fi

NEEDS_BUMP=1
if [[ "$CURRENT_VERSION" == "$VERSION" ]]; then
    log " [i] VERSION already at ${VERSION} — no bump needed."
    NEEDS_BUMP=0
fi

# ============================================================================
# [1/5] Assessment repo: version bump + manifest + commit + tag + push
# ============================================================================
log_step 1 5 "Assessment repo — version bump, manifest update, commit, tag, push"

if [[ $TAG_EXISTS -eq 1 ]]; then
    log " [SKIP] Tag '${TAG}' already exists — step 1 completed previously."
elif [[ $DRY_RUN -eq 1 ]]; then
    if [[ $NEEDS_BUMP -eq 1 ]]; then
        log " [DRY-RUN]   Write '${VERSION}' → VERSION + deployment/v1/VERSION"
    else
        log " [DRY-RUN]   Version already at ${VERSION} — bump skipped."
    fi
    log " [DRY-RUN]   Update release-manifest.yaml (version: ${VERSION}, minimum_upgrade_version: ${CURRENT_VERSION}, build_commit, database_revision)"
    log " [DRY-RUN]   First commit: \"release: ${VERSION} — version bump + manifest\""
    log " [DRY-RUN]   Second commit: \"release: stamp build_commit <hash>\""
    log " [DRY-RUN]   git tag -a ${TAG} -m \"NeoSecra Security Health v${VERSION}\""
    log " [DRY-RUN]   git push origin <current-branch> + ${TAG}"
else
    (
        cd "$ASSESSMENT_REPO"

        # Version bump (if needed)
        if [[ $NEEDS_BUMP -eq 1 ]]; then
            echo "$VERSION" > VERSION
            echo "$VERSION" > deployment/v1/VERSION
            log " VERSION files updated to ${VERSION}"
        fi

        # Find database revision head
        DATABASE_REVISION=$(python3 << 'PYEOF'
import os, re

versions_dir = "backend/alembic/versions"
all_revisions = {}
down_references = set()

for f in os.listdir(versions_dir):
    if not f.endswith('.py') or f == '__init__.py':
        continue
    content = open(os.path.join(versions_dir, f)).read()
    rev_match = re.search(r'^revision\s*=\s*[\'"]([^\'"]+)[\'"]', content, re.MULTILINE)
    if not rev_match:
        continue
    rev = rev_match.group(1)
    all_revisions[rev] = f

    down_match = re.search(r'^down_revision\s*=\s*[\'"]([^\'"]+)[\'"]', content, re.MULTILINE)
    if down_match:
        down_references.add(down_match.group(1))
    else:
        down_match2 = re.search(r'^down_revision\s*=\s*(.+)', content, re.MULTILINE)
        if down_match2:
            val = down_match2.group(1).strip()
            if val != 'None':
                for g in re.findall(r'[\'"]([^\'"]+)[\'"]', val):
                    down_references.add(g)

for rev in all_revisions:
    if rev not in down_references:
        print(rev)
        break
PYEOF
)
        log " Database revision head: ${DATABASE_REVISION}"

        # Current HEAD short hash for build_commit (first pass)
        BUILD_COMMIT=$(git rev-parse --short HEAD)
        log " Build commit (pre-bump HEAD): ${BUILD_COMMIT}"

        # Update release-manifest.yaml
        sed -i "s/^version:.*/version: ${VERSION}/" deployment/v1/release-manifest.yaml
        sed -i "s/^minimum_upgrade_version:.*/minimum_upgrade_version: \"${CURRENT_VERSION}\"/" deployment/v1/release-manifest.yaml
        sed -i "s/^build_commit:.*/build_commit: ${BUILD_COMMIT}/" deployment/v1/release-manifest.yaml
        sed -i "s/^database_revision:.*/database_revision: \"${DATABASE_REVISION}\"/" deployment/v1/release-manifest.yaml
        log " release-manifest.yaml updated"

        # Stage all modified files
        git add VERSION deployment/v1/VERSION deployment/v1/release-manifest.yaml

        # First commit
        git commit -m "release: ${VERSION} — version bump + manifest"
        log " First commit created"

        # Second commit — stamp build_commit with actual release commit hash
        FIRST_COMMIT_HASH=$(git rev-parse --short HEAD)
        sed -i "s/^build_commit:.*/build_commit: ${FIRST_COMMIT_HASH}/" deployment/v1/release-manifest.yaml
        git add deployment/v1/release-manifest.yaml
        git commit -m "release: stamp build_commit ${FIRST_COMMIT_HASH}"
        log " Second commit created: build_commit -> ${FIRST_COMMIT_HASH}"

        # Tag
        git tag -a "${TAG}" -m "NeoSecra Security Health v${VERSION}"
        log " Tag created: ${TAG}"

        # Push
        CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
        git push origin "${CURRENT_BRANCH}"
        git push origin "${TAG}"
        log " Pushed ${CURRENT_BRANCH} + tag ${TAG}"
    )
fi

# ============================================================================
# [2/5] Wait for GitHub Actions CI to complete
# ============================================================================
log_step 2 5 "Waiting for GitHub Actions CI (security-health-release.yml)"

if [[ $SKIP_CI_WAIT -eq 1 ]]; then
    log " [SKIP] --skip-ci-wait flag set — skipping CI wait."
elif [[ $DRY_RUN -eq 1 ]]; then
    log " [DRY-RUN]   gh run list --workflow security-health-release.yml --limit 1 --json databaseId,status"
    log " [DRY-RUN]   gh run watch <id> --exit-status --repo SirGlooMyy/neosecra-assessment"
elif [[ $TAG_EXISTS -eq 1 ]]; then
    log " [SKIP] Tag already existed — no new CI run to wait for."
else
    guard_gh
    CI_RUN_ID=$(gh run list --workflow security-health-release.yml --limit 1 --json databaseId --jq '.[0].databaseId' --repo SirGlooMyy/neosecra-assessment)
    if [[ -z "$CI_RUN_ID" ]]; then
        echo "[ERROR] No workflow run found for security-health-release.yml"
        exit 1
    fi
    log " Watching CI run #${CI_RUN_ID}..."
    gh run watch "${CI_RUN_ID}" --exit-status --repo SirGlooMyy/neosecra-assessment
    log " CI completed successfully."
fi

# ============================================================================
# [3/5] Build distribution archive
# ============================================================================
log_step 3 5 "Building distribution archive via build-release.sh"

if [[ $DRY_RUN -eq 1 ]]; then
    log " [DRY-RUN]   bash ${SCRIPT_DIR}/build-release.sh ${VERSION}"
else
    bash "${SCRIPT_DIR}/build-release.sh" "${VERSION}"
    log " Build complete: ${ARCHIVE_DIR}/distribution.tar.gz"
fi

# ============================================================================
# [4/5] Sign and publish archive
# ============================================================================
log_step 4 5 "Signing and publishing archive via publish.sh"

if [[ $DRY_RUN -eq 1 ]]; then
    log " [DRY-RUN]   mktemp -d"
    log " [DRY-RUN]   cp ${ARCHIVE_DIR}/distribution.tar.gz -> <tmp>/distribution-${VERSION}.tar.gz"
    if [[ -n "$RSYNC_TARGET" ]]; then
        log " [DRY-RUN]   bash ${SCRIPT_DIR}/publish.sh --product ${PRODUCT} --channel ${CHANNEL} --version ${VERSION} --archive <tmp>/distribution-${VERSION}.tar.gz --rsync ${RSYNC_TARGET}"
    else
        log " [DRY-RUN]   bash ${SCRIPT_DIR}/publish.sh --product ${PRODUCT} --channel ${CHANNEL} --version ${VERSION} --archive <tmp>/distribution-${VERSION}.tar.gz"
    fi
else
    PUBLISH_TMPDIR="$(mktemp -d)"
    log " Temp dir: ${PUBLISH_TMPDIR}"

    ARCHIVE_SRC="${ARCHIVE_DIR}/distribution.tar.gz"
    if [[ ! -f "$ARCHIVE_SRC" ]]; then
        echo "[ERROR] Archive not found at ${ARCHIVE_SRC}. Did build-release.sh succeed?"
        exit 1
    fi

    ARCHIVE_COPY="${PUBLISH_TMPDIR}/distribution-${VERSION}.tar.gz"
    cp "${ARCHIVE_SRC}" "${ARCHIVE_COPY}"
    log " Archive copied to: ${ARCHIVE_COPY}"

    PUBLISH_ARGS=(
        --product "${PRODUCT}"
        --channel "${CHANNEL}"
        --version "${VERSION}"
        --archive "${ARCHIVE_COPY}"
    )
    if [[ -n "$RSYNC_TARGET" ]]; then
        PUBLISH_ARGS+=(--rsync "${RSYNC_TARGET}")
    fi

    bash "${SCRIPT_DIR}/publish.sh" "${PUBLISH_ARGS[@]}"
    log " Publish complete."
fi

# ============================================================================
# [5/5] Rsync to update server(s)
# ============================================================================
log_step 5 5 "Rsyncing published artifacts to update server(s)"

if [[ $DRY_RUN -eq 1 ]]; then
    if [[ -n "$RSYNC_TARGET" ]]; then
        log " [DRY-RUN]   Rsync target provided: ${RSYNC_TARGET} (passed to publish.sh in step 4)"
    fi
    if [[ -n "${UPDATE_SERVER_TARGETS:-}" ]]; then
        log " [DRY-RUN]   UPDATE_SERVER_TARGETS set: ${UPDATE_SERVER_TARGETS} (respected by publish.sh)"
    fi
    if [[ -z "$RSYNC_TARGET" && -z "${UPDATE_SERVER_TARGETS:-}" ]]; then
        log " [SKIP] No rsync target specified — step 5 skipped."
    fi
else
    # publish.sh handles rsync internally (--rsync flag + UPDATE_SERVER_TARGETS env).
    # This step reports the outcome.
    TARGETS_COUNT=0
    if [[ -n "$RSYNC_TARGET" ]]; then
        TARGETS_COUNT=$((TARGETS_COUNT + 1))
    fi
    if [[ -n "${UPDATE_SERVER_TARGETS:-}" ]]; then
        read -ra ENV_TARGETS <<< "$UPDATE_SERVER_TARGETS"
        TARGETS_COUNT=$((TARGETS_COUNT + ${#ENV_TARGETS[@]}))
    fi
    if [[ $TARGETS_COUNT -gt 0 ]]; then
        log " Rsync handled by publish.sh — ${TARGETS_COUNT} target(s) configured."
    else
        log " [SKIP] No rsync target specified — step 5 skipped."
    fi
fi

# ============================================================================
# Summary
# ============================================================================
echo ""
echo "================================================================================"
echo "  Release Summary"
echo "================================================================================"
echo "  Tag:             ${TAG}"
if [[ $DRY_RUN -eq 0 ]]; then
    CHANNEL_JSON="${SCRIPT_DIR}/www/channels/${PRODUCT}-${CHANNEL}.json"
    if [[ -f "$CHANNEL_JSON" ]]; then
        CURRENT_CHANNEL_VER=$(python3 -c "import json; print(json.load(open('${CHANNEL_JSON}'))['current_version'])")
        echo "  Channel version: ${CURRENT_CHANNEL_VER}"
    fi
    ARCHIVE_SHA_FILE="${ARCHIVE_DIR}/distribution.tar.gz.sha256"
    if [[ -f "$ARCHIVE_SHA_FILE" ]]; then
        ARCHIVE_SHA=$(cut -d' ' -f1 "$ARCHIVE_SHA_FILE")
        echo "  Archive SHA256:  ${ARCHIVE_SHA}"
    fi
else
    log " [DRY-RUN] No actual write operations performed."
fi
echo "================================================================================"
