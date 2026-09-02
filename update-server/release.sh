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
  [1/6] Bump VERSION + release-manifest.yaml in assessment repo, commit, tag, push
  [2/6] Wait for GitHub Actions CI (security-health-release.yml) to complete
  [3/6] Build distribution archive via build-release.sh
  [4/6] Promote signed image digests from GHCR to registry.neosecra.com
  [5/6] Sign & publish archive via publish.sh
  [6/6] Rsync published artifacts to update server(s)

Arguments:
  <version>          Semantic version (X.Y.Z) to release

Options:
  --assessment-repo <path>   Path to neosecra-assessment repo
                             (default: ../neosecra-assessment relative to repo root)
  --skip-ci-wait             Skip waiting for GitHub CI completion
  --skip-registry-push       Skip image promotion (only with an explicit reason)
  --image-digests <path>     JSON lock produced by CI with backend/frontend
                             sha256 digests; required for image promotion
  --rsync <target>           rsync target for publish.sh (user@host:/path)
  --dry-run                  Print actions without executing anything destructive
  --help                     Show this help and exit

Environment:
  UPDATE_SERVER_TARGETS   Space-separated rsync targets (alternative to --rsync).
                          When combined with --rsync, all targets are synced.
  UPDATE_REGISTRY_COSIGN_PUBLIC_KEY
                          Trusted cosign public-key path on the promotion host

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
SKIP_REGISTRY_PUSH=0
IMAGE_DIGESTS_FILE="${NEOSECRA_IMAGE_DIGESTS_FILE:-}"
RSYNC_TARGET=""
DRY_RUN=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --assessment-repo)   ASSESSMENT_REPO="$2";  shift 2 ;;
        --skip-ci-wait)      SKIP_CI_WAIT=1;        shift   ;;
        --skip-registry-push) SKIP_REGISTRY_PUSH=1;  shift   ;;
        --image-digests)     IMAGE_DIGESTS_FILE="$2"; shift 2 ;;
        --rsync)             RSYNC_TARGET="$2";     shift 2 ;;
        --dry-run)           DRY_RUN=1;             shift   ;;
        --help)              usage                         ;;
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

REGISTRY_PUSH_TARGET="${UPDATE_REGISTRY_PUSH_TARGET:-ssh neosecra@100.125.0.108}"

PUBLISH_TMPDIR=""
cleanup() {
    [[ -n "$PUBLISH_TMPDIR" && -d "$PUBLISH_TMPDIR" ]] && rm -rf "$PUBLISH_TMPDIR"
    return 0
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

validate_image_digest() {
    local name="$1" digest="$2"
    if [[ ! "$digest" =~ ^sha256:[0-9a-f]{64}$ ]]; then
        echo "[ERROR] ${name} image digest is missing or not a lowercase sha256 digest" >&2
        return 1
    fi
}

# Resolve the CI-produced image digests before any registry promotion.  A
# mutable GHCR tag is never accepted as the transport identity.  CI may hand
# us a small JSON lock (for example {"backend":{"digest":"sha256:..."},
# "frontend":{"digest":"sha256:..."}}); when it does not, the assessment
# release manifest is the only fallback and must contain both digests.
load_image_digests() {
    local output backend frontend
    backend="${NEOSECRA_BACKEND_DIGEST:-${BACKEND_DIGEST:-}}"
    frontend="${NEOSECRA_FRONTEND_DIGEST:-${FRONTEND_DIGEST:-}}"

    if [[ -n "$IMAGE_DIGESTS_FILE" ]]; then
        [[ -f "$IMAGE_DIGESTS_FILE" && ! -L "$IMAGE_DIGESTS_FILE" ]] || {
            echo "[ERROR] Image digest lock is missing or unsafe: ${IMAGE_DIGESTS_FILE}" >&2
            return 1
        }
        output="$(python3 - "$IMAGE_DIGESTS_FILE" <<'PY'
import json
import sys

path = sys.argv[1]
try:
    with open(path, encoding="utf-8") as stream:
        value = json.load(stream)
except (OSError, ValueError) as exc:
    print(f"invalid image digest lock: {exc}", file=sys.stderr)
    raise SystemExit(1)
if not isinstance(value, dict):
    print("image digest lock must be a JSON object", file=sys.stderr)
    raise SystemExit(1)
images = value.get("images") if isinstance(value.get("images"), dict) else value
for name in ("backend", "frontend"):
    item = images.get(name)
    digest = item.get("digest") if isinstance(item, dict) else item
    if not isinstance(digest, str):
        print(f"{name}=", end="\n")
    else:
        print(f"{name}={digest}")
PY
        )" || return 1
        backend="$(printf '%s\n' "$output" | awk -F= '$1=="backend" {print $2; exit}')"
        frontend="$(printf '%s\n' "$output" | awk -F= '$1=="frontend" {print $2; exit}')"
    elif [[ -z "$backend" || -z "$frontend" ]]; then
        [[ -f "$MANIFEST_FILE" && ! -L "$MANIFEST_FILE" ]] || {
            echo "[ERROR] Assessment release manifest is missing or unsafe: ${MANIFEST_FILE}" >&2
            return 1
        }
        output="$(python3 - "$MANIFEST_FILE" <<'PY'
import re
import sys

path = sys.argv[1]
try:
    lines = open(path, encoding="utf-8")
except OSError as exc:
    print(exc, file=sys.stderr)
    raise SystemExit(1)
inside_images = False
current = None
found = {}
for raw in lines:
    if re.match(r"^images:\s*$", raw):
        inside_images = True
        current = None
        continue
    if inside_images and re.match(r"^\S", raw):
        inside_images = False
        current = None
    match = re.match(r"^\s*-\s+name:\s*([a-z0-9_-]+)\s*$", raw)
    if inside_images and match:
        current = match.group(1)
        continue
    match = re.match(r"^\s+digest:\s*(sha256:[0-9a-f]{64})\s*$", raw)
    if inside_images and current in {"backend", "frontend"} and match:
        found.setdefault(current, match.group(1))
for name in ("backend", "frontend"):
    print(f"{name}={found.get(name, '')}")
PY
        )" || return 1
        [[ -n "$backend" ]] || backend="$(printf '%s\n' "$output" | awk -F= '$1=="backend" {print $2; exit}')"
        [[ -n "$frontend" ]] || frontend="$(printf '%s\n' "$output" | awk -F= '$1=="frontend" {print $2; exit}')"
    fi

    validate_image_digest "backend" "$backend" || return 1
    validate_image_digest "frontend" "$frontend" || return 1
    IMAGE_BACKEND_DIGEST="$backend"
    IMAGE_FRONTEND_DIGEST="$frontend"
    return 0
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

        # Find database revision head — via alembic itself (naive file parsing
        # is unreliable with branches/type annotations). Requires alembic on PATH.
        DATABASE_REVISION=$(
            cd backend
            DATABASE_URL=sqlite+aiosqlite:///:memory: alembic heads 2>/dev/null | awk '/\(head\)/{print $1}'
        )
        HEAD_COUNT=$(printf '%s\n' "${DATABASE_REVISION}" | grep -c . || true)
        if [[ "${HEAD_COUNT}" != "1" ]]; then
            echo "[ERROR] alembic heads did not return exactly one head (got: '${DATABASE_REVISION}'). Install alembic or resolve branches."
            exit 1
        fi
        log " Database revision head: ${DATABASE_REVISION}"

        # Current HEAD short hash for build_commit (first pass)
        BUILD_COMMIT=$(git rev-parse --short HEAD)
        log " Build commit (pre-bump HEAD): ${BUILD_COMMIT}"

        # U7: Stamped fields — release_date, script_checksums
        RELEASE_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

        sed -i "s/^version:.*/version: ${VERSION}/" deployment/v1/release-manifest.yaml
        # minimum_upgrade_version = the version being replaced. Only stamp it
        # when the version actually advanced; on idempotent re-runs
        # (tag deleted, VERSION already at target) CURRENT_VERSION == VERSION
        # and re-stamping would wrongly require upgrading from the release
        # itself, blocking all real upgrades.
        if [[ $NEEDS_BUMP -eq 1 ]]; then
            sed -i "s/^minimum_upgrade_version:.*/minimum_upgrade_version: \"${CURRENT_VERSION}\"/" deployment/v1/release-manifest.yaml
        fi
        sed -i "s/^build_commit:.*/build_commit: ${BUILD_COMMIT}/" deployment/v1/release-manifest.yaml
        sed -i "s/^database_revision:.*/database_revision: \"${DATABASE_REVISION}\"/" deployment/v1/release-manifest.yaml
        if grep -q '^release_date:' deployment/v1/release-manifest.yaml; then
            sed -i "s/^release_date:.*/release_date: \"${RELEASE_DATE}\"/" deployment/v1/release-manifest.yaml
        else
            sed -i "/^database_revision:/a release_date: \"${RELEASE_DATE}\"" deployment/v1/release-manifest.yaml
        fi
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
    # Wait for a run belonging to THIS tag's commit — right after push,
    # `gh run list --limit 1` can still return the previous release's run.
    TAG_SHA=$(git -C "${ASSESSMENT_REPO}" rev-parse "refs/tags/${TAG}^{commit}" 2>/dev/null || true)
    CI_RUN_ID=""
    for _ in $(seq 1 30); do
        if [[ -n "$TAG_SHA" ]]; then
            CI_RUN_ID=$(gh run list --workflow security-health-release.yml --limit 10 --json databaseId,headSha --jq ".[] | select(.headSha == \"$TAG_SHA\") | .databaseId" --repo SirGlooMyy/neosecra-assessment | head -1)
        fi
        [[ -n "$CI_RUN_ID" ]] && break
        sleep 10
    done
    if [[ -z "$CI_RUN_ID" ]]; then
        echo "[ERROR] No workflow run found for tag $TAG (sha ${TAG_SHA:-unknown}) after 5 minutes"
        exit 1
    fi
    log " Watching CI run #${CI_RUN_ID}..."
    gh run watch "${CI_RUN_ID}" --exit-status --repo SirGlooMyy/neosecra-assessment
    log " CI completed successfully."
fi

# ============================================================================
# [3/6] Build distribution archive
# ============================================================================
log_step 3 6 "Building distribution archive via build-release.sh"

if [[ $DRY_RUN -eq 1 ]]; then
    log " [DRY-RUN]   bash ${SCRIPT_DIR}/build-release.sh ${VERSION}"
else
    bash "${SCRIPT_DIR}/build-release.sh" "${VERSION}"
    log " Build complete: ${ARCHIVE_DIR}/distribution.tar.gz"
fi

# ============================================================================
# [4/6] Push container images to private registry
# ============================================================================
log_step 4 6 "Pushing container images to registry.neosecra.com"

GHCR_BACKEND_BASE="ghcr.io/sirgloomyy/neosecra-assessment/security-health-backend"
GHCR_FRONTEND_BASE="ghcr.io/sirgloomyy/neosecra-assessment/security-health-frontend"
REGISTRY_BACKEND="registry.neosecra.com/security-health-backend:${VERSION}"
REGISTRY_FRONTEND="registry.neosecra.com/security-health-frontend:${VERSION}"
COSIGN_PUBLIC_KEY="${UPDATE_REGISTRY_COSIGN_PUBLIC_KEY:-/etc/neosecra/certs/cosign.pub}"
SPDX_ATTESTATION_TYPE="${UPDATE_REGISTRY_SPDX_ATTESTATION_TYPE:-https://spdx.dev/Document}"

if [[ $SKIP_REGISTRY_PUSH -eq 1 ]]; then
    if [[ "$CHANNEL" == "stable" && "$DRY_RUN" -eq 0 ]]; then
        echo "[ERROR] Stable promotion cannot skip immutable image promotion." >&2
        exit 4
    fi
    log " [SKIP] --skip-registry-push flag set — no image promotion will be performed."
elif [[ $DRY_RUN -eq 1 ]]; then
    if ! load_image_digests; then
        log " [DRY-RUN]   image promotion would fail closed: CI digest lock is required"
    else
        log " [DRY-RUN]   verify cosign signature + SPDX attestation for immutable digests"
        log " [DRY-RUN]   ${REGISTRY_PUSH_TARGET} docker buildx imagetools create --tag '${REGISTRY_BACKEND}' '${GHCR_BACKEND_BASE}@${IMAGE_BACKEND_DIGEST}'"
        log " [DRY-RUN]   ${REGISTRY_PUSH_TARGET} docker buildx imagetools create --tag '${REGISTRY_FRONTEND}' '${GHCR_FRONTEND_BASE}@${IMAGE_FRONTEND_DIGEST}'"
    fi
else
    load_image_digests || {
        echo "[ERROR] Immutable CI image digests are required; refusing mutable image promotion." >&2
        exit 4
    }
    if [[ "$REGISTRY_PUSH_TARGET" == "ssh "* ]]; then
        remote_host="${REGISTRY_PUSH_TARGET#ssh }"
        [[ "$remote_host" != *[!A-Za-z0-9@._:-]* ]] || {
            echo "[ERROR] UPDATE_REGISTRY_PUSH_TARGET contains unsafe SSH host characters" >&2
            exit 4
        }
        remote_script=$(cat <<'REMOTE'
set -Eeuo pipefail
command -v docker >/dev/null 2>&1 || { echo '[ERROR] docker is required on registry host' >&2; exit 4; }
docker buildx version >/dev/null 2>&1 || { echo '[ERROR] docker buildx imagetools is required on registry host' >&2; exit 4; }
command -v cosign >/dev/null 2>&1 || { echo '[ERROR] cosign is required on registry host' >&2; exit 4; }
[[ -f "$COSIGN_PUBLIC_KEY" && ! -L "$COSIGN_PUBLIC_KEY" ]] || { echo '[ERROR] trusted cosign public key is missing or unsafe' >&2; exit 4; }

extract_digest() {
  awk '$1 == "Digest:" {print $2; exit}'
}

inspect_digest() {
  local ref="$1" output rc digest lower
  if output="$(docker buildx imagetools inspect "$ref" 2>&1)"; then
    digest="$(printf '%s\n' "$output" | extract_digest)"
    [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "[ERROR] registry returned no valid digest for $ref" >&2; return 1; }
    printf '%s' "$digest"
    return 0
  else
    rc=$?
    lower="${output,,}"
    case "$lower" in
      *"manifest unknown"*|*"no such manifest"*|*"not found"*|*"404"*) return 2 ;;
      *) echo "$output" >&2; return "$rc" ;;
    esac
  fi
}

promote_immutable() {
  local name="$1" source_base="$2" target_ref="$3" expected="$4" source_ref target_digest rc
  [[ "$expected" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "[ERROR] invalid $name digest" >&2; return 4; }
  source_ref="${source_base}@${expected}"

  source_digest="$(inspect_digest "$source_ref")" || {
    echo "[ERROR] immutable $name source is unavailable: $source_ref" >&2
    return 4
  }
  [[ "$source_digest" == "$expected" ]] || {
    echo "[ERROR] immutable $name source digest mismatch: $source_digest != $expected" >&2
    return 4
  }
  cosign verify --key "$COSIGN_PUBLIC_KEY" "$source_ref" >/dev/null || {
    echo "[ERROR] cosign signature verification failed for $source_ref" >&2
    return 4
  }
  cosign verify-attestation --key "$COSIGN_PUBLIC_KEY" --type "$SPDX_ATTESTATION_TYPE" "$source_ref" >/dev/null || {
    echo "[ERROR] SPDX attestation verification failed for $source_ref" >&2
    return 4
  }

  if target_digest="$(inspect_digest "$target_ref")"; then
    [[ "$target_digest" == "$expected" ]] || {
      echo "[ERROR] existing $name target points to $target_digest, expected $expected; refusing replacement" >&2
      return 4
    }
    printf 'IMAGE_PROMOTION|PASS|%s|%s (existing digest)\n' "$name" "$target_digest"
    return 0
  else
    rc=$?
    [[ "$rc" -eq 2 ]] || {
      echo "[ERROR] unable to determine existing $name target state; refusing promotion" >&2
      return 4
    }
  fi

  # The only write is a digest-addressed OCI copy.  The version tag is created
  # as an idempotent alias and is never allowed to replace a different digest.
  docker buildx imagetools create --tag "$target_ref" "$source_ref" >/dev/null || {
    echo "[ERROR] immutable $name target creation failed" >&2
    return 4
  }
  target_digest="$(inspect_digest "$target_ref")" || {
    echo "[ERROR] unable to verify $name target after creation" >&2
    return 4
  }
  [[ "$target_digest" == "$expected" ]] || {
    echo "[ERROR] $name target digest mismatch after immutable promotion: $target_digest != $expected" >&2
    return 4
  }
  printf 'IMAGE_PROMOTION|PASS|%s|%s\n' "$name" "$target_digest"
}

REMOTE
)
        remote_script="COSIGN_PUBLIC_KEY=$(printf '%q' "$COSIGN_PUBLIC_KEY"); SPDX_ATTESTATION_TYPE=$(printf '%q' "$SPDX_ATTESTATION_TYPE"); REGISTRY_BACKEND=$(printf '%q' "$REGISTRY_BACKEND"); REGISTRY_FRONTEND=$(printf '%q' "$REGISTRY_FRONTEND"); ${remote_script}"
        remote_script+=$'\n'"promote_immutable backend $(printf '%q' "$GHCR_BACKEND_BASE") $(printf '%q' "$REGISTRY_BACKEND") $(printf '%q' "$IMAGE_BACKEND_DIGEST")"
        remote_script+=$'\n'"promote_immutable frontend $(printf '%q' "$GHCR_FRONTEND_BASE") $(printf '%q' "$REGISTRY_FRONTEND") $(printf '%q' "$IMAGE_FRONTEND_DIGEST")"
        log " Registry push target: ${REGISTRY_PUSH_TARGET}"
        if ! ssh -o BatchMode=yes -o ConnectTimeout=15 "${remote_host}" "bash -s" <<<"${remote_script}"; then
            echo "[ERROR] Immutable registry promotion FAILED; stable release remains unpublished." >&2
            exit 4
        fi
    else
        echo "[ERROR] UPDATE_REGISTRY_PUSH_TARGET must use the explicit 'ssh user@host' form" >&2
        exit 4
    fi
    log " Registry promotion complete — immutable digests verified at registry.neosecra.com"
fi

# ============================================================================
# [5/6] Sign and publish archive
# ============================================================================
log_step 5 6 "Signing and publishing archive via publish.sh"

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
# [6/6] Rsync to update server(s)
# ============================================================================
log_step 6 6 "Rsyncing published artifacts to update server(s)"

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
