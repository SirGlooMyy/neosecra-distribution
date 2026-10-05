#!/usr/bin/env bash
# neosecra adopt-release — record the release that is REALLY running as the
# installed release, so the update agent starts from the truth.
#
# Why: an installation that was upgraded by hand (new images + "docker compose up"
# inside an old release directory) still carries the old version in its release
# tree and in state/installed-version.  The update agent would then upgrade "from"
# a version that is not running, take its pre-upgrade backup under that name, and
# roll back to images that no longer match the database.  Adoption fixes the
# record once, without touching a container or the database:
#
#   * the SIGNED package of the running version is verified (SHA-256 + Minisign)
#     and extracted into releases/<version> (its own scripts, compose, manifest),
#   * the installation's environment file, TLS material and image pins are carried
#     over (secret values are copied, never printed),
#   * state/installed-version, state/active-release and the current/previous
#     symlinks are switched; everything needed to undo this is recorded first.
#
# Usage (as root, on the installation host):
#   adopt-release.sh --archive <package.tar.gz> --version <X.Y.Z> [options]
#   adopt-release.sh --revert [--record <state/adopt/<stamp>.json>]
#
# Options:
#   --archive <file>        signed release package (its .minisig sits next to it)
#   --signature <file>      signature file (default: <archive>.minisig)
#   --sha256 <hex>          expected SHA-256 (from the signed channel record)
#   --pubkey <file|dir>     Minisign public key or keyring (default: ca/ of this tree)
#   --env-file <file>       environment file to carry over (default: current/.env.v1,
#                           then current/.env)
#   --channel <name>        follow assessment-stable | assessment-candidate | assessment-beta:
#                           sets UPGRADE_CHANNEL_URL and UPGRADE_RELEASE_CHANNEL
#   --enable-dast           add "dast" to COMPOSE_PROFILES (also done when a ZAP
#                           container is running); needs DAST_API_KEY_FILE outside /home
#   --mark-hooks-done <ids> comma separated post-upgrade hook ids that were already applied
#                           by hand (for example compliance-backfill)
#   --no-docker             do not look at running containers (no image pins, no schema check)
#   --dry-run               verify and report; change nothing
#   --revert                undo the latest adoption (the adopted tree is moved aside, not deleted)
#
# Environment: NEOSECRA_INSTALL_ROOT (default /opt/neosecra/assessment).
set -Eeuo pipefail

ADOPT_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
V1_ROOT="$(cd "${ADOPT_SCRIPT_DIR}/.." && pwd)"
source "${V1_ROOT}/lib/common.sh"
source "${V1_ROOT}/lib/state.sh"
source "${V1_ROOT}/agent/artifact-verifier.sh"
set -Eeuo pipefail

ADOPT_STATE_DIR="${STATE_DIR}/adopt"
PRODUCT_SERVICES=(postgres redis backend worker beat frontend openvas zap dast-egress)

usage() { sed -n '2,/^set -Eeuo/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'; }

ARCHIVE=""; SIGNATURE=""; SHA256=""; PUBKEY="${NEOSECRA_SIGNATURE_PUBKEY:-${V1_ROOT}/ca}"
VERSION_ARG=""; ENV_SOURCE=""; CHANNEL=""; ENABLE_DAST=0; MARK_HOOKS=""; USE_DOCKER=1
DRY=0; REVERT=0; RECORD=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --archive)    shift; ARCHIVE="${1:-}" ;;
    --signature)  shift; SIGNATURE="${1:-}" ;;
    --sha256)     shift; SHA256="${1:-}" ;;
    --pubkey)     shift; PUBKEY="${1:-}" ;;
    --version)    shift; VERSION_ARG="${1:-}" ;;
    --env-file)   shift; ENV_SOURCE="${1:-}" ;;
    --channel)    shift; CHANNEL="${1:-}" ;;
    --enable-dast) ENABLE_DAST=1 ;;
    --mark-hooks-done) shift; MARK_HOOKS="${1:-}" ;;
    --no-docker)  USE_DOCKER=0 ;;
    --dry-run)    DRY=1 ;;
    --revert)     REVERT=1 ;;
    --record)     shift; RECORD="${1:-}" ;;
    --help|-h)    usage; exit 0 ;;
    *) usage >&2; die "unknown option: $1" 2 ;;
  esac
  shift
done

if [[ "${NEOSECRA_ADOPT_ALLOW_NONROOT:-0}" != "1" ]]; then
  [[ $EUID -eq 0 ]] || die "adopt-release must run as root (sudo)" 1
fi
[[ -d "$INSTALL_ROOT" && -d "$RELEASES_DIR" ]] || die "No installation found at ${INSTALL_ROOT}" 1
[[ ! -e "${STATE_DIR}/.install.lock" ]] || die "An install/upgrade lock is held (${STATE_DIR}/.install.lock); try again when it is gone" 5

read_link_target() { readlink "$1" 2>/dev/null || true; }
fsync_dir() {
  python3 - "$1" <<'PY'
import os, sys
fd = os.open(sys.argv[1], os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
try:
    os.fsync(fd)
finally:
    os.close(fd)
PY
}
set_link() {  # atomic symlink replace: set_link <target> <link>
  local target="$1" link="$2" tmp="${2}.adopt.$$"
  ln -s "$target" "$tmp" && mv -Tf "$tmp" "$link"
}

# ---------------------------------------------------------------------------
# revert
# ---------------------------------------------------------------------------
if [[ $REVERT -eq 1 ]]; then
  [[ -n "$RECORD" ]] || RECORD="$(ls -t "${ADOPT_STATE_DIR}"/*.json 2>/dev/null | head -n1 || true)"
  [[ -n "$RECORD" && -f "$RECORD" ]] || die "No adoption record found in ${ADOPT_STATE_DIR}" 1
  log "Reverting adoption recorded in ${RECORD}"
  mapfile -t FIELDS < <(python3 - "$RECORD" <<'PY'
import json, sys
r = json.load(open(sys.argv[1], encoding="utf-8"))
for key in ("version", "adopted_dir", "previous_installed_version", "previous_active_release",
            "previous_current_target", "previous_previous_target", "applied"):
    print("" if r.get(key) is None else str(r[key]))
PY
  )
  CR=$'\r'
  FIELDS=("${FIELDS[@]%"$CR"}")  # tolerate a Windows-style interpreter in test environments
  R_VERSION="${FIELDS[0]}"; R_INSTALLED="${FIELDS[2]}"; R_ACTIVE="${FIELDS[3]}"
  R_CURRENT="${FIELDS[4]}"; R_PREVIOUS="${FIELDS[5]}"; R_APPLIED="${FIELDS[6]}"
  # The adopted directory is derived here (the spelling switch_current used), not read back from the record.
  R_DIR="$(release_dir "$R_VERSION")"
  [[ "$R_APPLIED" == "True" || "$R_APPLIED" == "true" ]] || die "The record was never applied; nothing to revert" 1
  [[ "$(read_link_target "$(current_symlink)")" == "$R_DIR" ]] || \
    die "current no longer points at the adopted tree (${R_DIR}); refusing to revert over a later change" 1
  [[ -n "$R_CURRENT" ]] || die "Record has no previous current target" 1
  set_link "$R_CURRENT" "$(current_symlink)"
  if [[ -n "$R_PREVIOUS" ]]; then set_link "$R_PREVIOUS" "$(previous_symlink)"; else rm -f -- "$(previous_symlink)"; fi
  if [[ -n "$R_INSTALLED" ]]; then atomic_write_text "${STATE_DIR}/installed-version" 0600 <<< "$R_INSTALLED"; else rm -f -- "${STATE_DIR}/installed-version"; fi
  if [[ -n "$R_ACTIVE" ]]; then atomic_write_text "${STATE_DIR}/active-release" 0600 <<< "$R_ACTIVE"; else rm -f -- "${STATE_DIR}/active-release"; fi
  fsync_dir "$INSTALL_ROOT"
  ASIDE="${RELEASES_DIR}/.adopt-reverted-${R_VERSION}-$(date -u +%Y%m%dT%H%M%SZ)"
  if [[ -d "$R_DIR" ]]; then mv -- "$R_DIR" "$ASIDE"; ok "Adopted tree moved aside: ${ASIDE}"; fi
  mv -- "$RECORD" "${RECORD}.reverted"
  ok "Adoption reverted: current -> ${R_CURRENT}, installed-version ${R_INSTALLED:-<none>}"
  exit 0
fi

# ---------------------------------------------------------------------------
# adopt
# ---------------------------------------------------------------------------
[[ "$VERSION_ARG" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { usage >&2; die "--version X.Y.Z is required" 2; }
[[ -n "$ARCHIVE" && -f "$ARCHIVE" && ! -L "$ARCHIVE" ]] || die "--archive must be a regular file" 2
[[ -n "$SIGNATURE" ]] || SIGNATURE="${ARCHIVE}.minisig"
if [[ -n "$CHANNEL" ]]; then
  case "$CHANNEL" in assessment-stable|assessment-candidate|assessment-beta) ;; *) die "--channel must be assessment-stable, assessment-candidate or assessment-beta" 2 ;; esac
fi
CURRENT_LINK="$(current_symlink)"
[[ -L "$CURRENT_LINK" ]] || die "${CURRENT_LINK} is not a symlink; adoption needs the release-tree layout (releases/<version> + current)" 1
CURRENT_TARGET="$(read_link_target "$CURRENT_LINK")"
[[ -d "$CURRENT_LINK" ]] || die "current points at a missing directory (${CURRENT_TARGET})" 1
DEST="$(release_dir "$VERSION_ARG")"
[[ ! -e "$DEST" ]] || die "releases/${VERSION_ARG} already exists; adoption never overwrites a release tree" 1

# --- 1. verify the signed package --------------------------------------------
log "Verifying package: ${ARCHIVE}"
if [[ -n "$SHA256" ]]; then
  [[ "$SHA256" =~ ^[0-9a-fA-F]{64}$ ]] || die "--sha256 is not a SHA-256" 2
  [[ "$(sha256sum "$ARCHIVE" | awk '{print tolower($1)}')" == "${SHA256,,}" ]] || die "SHA-256 mismatch for ${ARCHIVE}" 4
  ok "SHA-256 verified"
else
  warn "no --sha256 given: only the signature protects the package (take the SHA-256 from the signed channel record)"
fi
[[ -f "$SIGNATURE" ]] || die "signature not found: ${SIGNATURE}" 4
verify_minisign_file "$ARCHIVE" "$SIGNATURE" "$PUBKEY" || die "Minisign signature verification FAILED (pinned keys: ${PUBKEY})" 4
ok "Minisign signature verified"

WORK="$(mktemp -d)"
STAGING=""
cleanup() { rm -rf -- "$WORK" 2>/dev/null || true; [[ -z "$STAGING" ]] || rm -rf -- "$STAGING" 2>/dev/null || true; }
trap cleanup EXIT
python3 "${ADOPT_SCRIPT_DIR}/secure_extract.py" release "$ARCHIVE" "${WORK}/extract" "$VERSION_ARG" || die "Bounded extraction of the package failed" 4
TOP="$(find "${WORK}/extract" -mindepth 1 -maxdepth 1 -type d -name 'neosecra-distribution-*' -print -quit)"
PAYLOAD="${TOP}/deployment"
for marker in VERSION release-manifest.yaml docker-compose.v1.yml upgrade/upgrade.sh agent/update-agent.sh env.v1.example; do
  [[ -f "${PAYLOAD}/${marker}" ]] || die "Package lacks deployment/${marker}" 4
done
[[ "$(tr -d '[:space:]' < "${PAYLOAD}/VERSION")" == "$VERSION_ARG" ]] || die "Package VERSION is not ${VERSION_ARG}" 4
grep -Eq "^version:[[:space:]]*['\"]?${VERSION_ARG}['\"]?[[:space:]]*$" "${PAYLOAD}/release-manifest.yaml" || die "Package manifest version is not ${VERSION_ARG}" 4
grep -Eq '^trust_policy:[[:space:]]*"?minisign-package-v1"?' "${PAYLOAD}/release-manifest.yaml" || die "Package manifest does not state trust_policy" 4
PACKAGE_DB_REVISION="$(grep -E '^database_revision:' "${PAYLOAD}/release-manifest.yaml" | head -n1 | awk '{print $2}' | tr -d '"' || true)"

# --- 2. what is really running ------------------------------------------------
PROJECT_LABEL="com.docker.compose.project=${COMPOSE_PROJECT}"
container_of() {  # container id of a compose service of this project (running)
  docker ps -q --filter "label=${PROJECT_LABEL}" --filter "label=com.docker.compose.service=$1" 2>/dev/null | head -n1
}
declare -A RUNNING_REF=()
SOURCE_ENV="$ENV_SOURCE"
if [[ -z "$SOURCE_ENV" ]]; then
  # Compose reads env_file ".env.v1" for the containers and --env-file for interpolation; a
  # hand-managed installation may carry both, edited separately.  Never guess which one is true.
  if [[ -f "${CURRENT_LINK}/.env.v1" && -f "${CURRENT_LINK}/.env" ]] && ! cmp -s "${CURRENT_LINK}/.env.v1" "${CURRENT_LINK}/.env"; then
    die "current/ holds both .env.v1 and .env and they differ; pick the true one with --env-file <file>" 1
  fi
  for candidate in "${CURRENT_LINK}/.env.v1" "${CURRENT_LINK}/.env"; do
    [[ -f "$candidate" ]] && { SOURCE_ENV="$candidate"; break; }
  done
fi
[[ -n "$SOURCE_ENV" && -f "$SOURCE_ENV" && ! -L "$SOURCE_ENV" ]] || die "No environment file found to carry over (use --env-file)" 1
DB_REVISION=""
if [[ $USE_DOCKER -eq 1 ]]; then
  command -v docker >/dev/null 2>&1 || die "docker is not available (use --no-docker to skip the runtime checks)" 1
  backend_cid="$(container_of backend)"
  [[ -n "$backend_cid" ]] || die "No running backend container for project ${COMPOSE_PROJECT}; adopt a running installation or pass --no-docker" 1
  for service in "${PRODUCT_SERVICES[@]}"; do
    cid="$(container_of "$service")"
    [[ -n "$cid" ]] && RUNNING_REF[$service]="$(docker inspect --format '{{.Config.Image}}' "$cid" 2>/dev/null || true)"
  done
  running_ref="${RUNNING_REF[backend]%%@*}"
  running_tag="${running_ref##*:}"
  [[ "$running_tag" == "$VERSION_ARG" ]] || die "The running backend image is '${RUNNING_REF[backend]:-?}', not version ${VERSION_ARG}; adopt the version that is actually running" 1
  ok "Running backend image matches ${VERSION_ARG}"
  pg_cid="$(container_of postgres)"
  if [[ -n "$pg_cid" ]]; then
    pguser="$(env_file_value "$SOURCE_ENV" POSTGRES_USER neosecra)"; pgdb="$(env_file_value "$SOURCE_ENV" POSTGRES_DB neosecra_assessment)"
    DB_REVISION="$(docker exec "$pg_cid" psql -U "$pguser" -d "$pgdb" -At -c 'select version_num from alembic_version' 2>/dev/null < /dev/null | head -n1 | tr -d '[:space:]' || true)"
  fi
  if [[ -n "$DB_REVISION" && -n "$PACKAGE_DB_REVISION" ]]; then
    [[ "$DB_REVISION" == "$PACKAGE_DB_REVISION" ]] || die "Database schema is ${DB_REVISION} but the package ${VERSION_ARG} expects ${PACKAGE_DB_REVISION}; adopting would record a false state" 1
    ok "Database schema ${DB_REVISION} matches the package"
  else
    warn "database schema revision could not be read; the schema check was skipped"
  fi
fi

# --- 3. build the adopted release tree in staging -------------------------------
STAGING="${RELEASES_DIR}/.staging-adopt-${VERSION_ARG}.$$"
[[ $DRY -eq 1 ]] && STAGING="${WORK}/staging"
mkdir -p "$STAGING"
cp -a "${PAYLOAD}/." "${STAGING}/"
if [[ -f "${STAGING}/env.v1.example" && ! -e "${STAGING}/.env.v1.example" ]]; then
  mv -- "${STAGING}/env.v1.example" "${STAGING}/.env.v1.example"
fi
cp -a "$SOURCE_ENV" "${STAGING}/.env.v1"
chmod 0600 "${STAGING}/.env.v1"
if [[ -d "${CURRENT_LINK}/config/tls" ]]; then
  mkdir -p "${STAGING}/config"
  cp -a "${CURRENT_LINK}/config/tls" "${STAGING}/config/tls"
fi

# Edit the staged env file only (values are never printed).
ENV_FILE="${STAGING}/.env.v1"
set_env() { upsert_env_value "$1" "$2"; }
fill_env() { [[ -n "$(env_value "$1" "")" ]] || { set_env "$1" "$2"; log "  default added: $1"; }; }
set_env NEOSECRA_VERSION "$VERSION_ARG"
# Compose defaults, made explicit because validate_env_file requires them to be present.
fill_env POSTGRES_PORT 25433; fill_env REDIS_PORT 25639; fill_env BACKEND_PORT 25800; fill_env FRONTEND_PORT 25300
fill_env NEOSECRA_EDITION security_health; fill_env VITE_NEOSECRA_EDITION security-health
if [[ -n "$CHANNEL" ]]; then
  set_env UPGRADE_CHANNEL_URL "https://update.neosecra.com/channels/${CHANNEL}.json"
  set_env UPGRADE_RELEASE_CHANNEL "$CHANNEL"
  ok "Installation will follow ${CHANNEL}"
fi
# Image pins: what runs now (exact references, so a rollback target is real); the
# package lock supplies a pinned reference for services that are not running.
LOCK="${STAGING}/release/images.lock"
lock_ref() { [[ -f "$LOCK" ]] && grep -E "^${1}=" "$LOCK" | head -n1 | cut -d= -f2- || true; }
for service in "${PRODUCT_SERVICES[@]}"; do
  var="$(printf '%s' "$service" | LC_ALL=C tr 'a-z-' 'A-Z_')_IMAGE"
  ref="${RUNNING_REF[$service]:-}"
  [[ -n "$ref" ]] || ref="$(lock_ref "$service")"
  [[ -n "$ref" ]] || { [[ "$service" =~ ^(zap|dast-egress|openvas)$ ]] && continue; die "No image reference for ${service} (not running, not in the package lock)" 1; }
  set_env "$var" "$ref"
done
if [[ $ENABLE_DAST -eq 1 || -n "${RUNNING_REF[zap]:-}" ]]; then
  profiles="$(env_value COMPOSE_PROFILES "")"
  case ",${profiles}," in *,dast,*) ;; *) set_env COMPOSE_PROFILES "${profiles:+${profiles},}dast" ;; esac
  keyfile="$(env_value DAST_API_KEY_FILE "")"
  [[ -n "$keyfile" && -f "$keyfile" ]] || die "DAST is enabled but DAST_API_KEY_FILE (${keyfile:-unset}) is not an existing file; set it in ${SOURCE_ENV} first" 1
  case "$keyfile" in /home/*|/root/*) die "DAST_API_KEY_FILE must live outside /home (the update agent runs with ProtectHome=true): ${keyfile}" 1 ;; esac
  [[ -n "$(env_value DAST_ZAP_API_KEY "")" ]] || warn "DAST_ZAP_API_KEY is empty in the env file; the backend cannot talk to ZAP until it is set"
  ok "DAST profile enabled for this installation"
fi
if ! ( validate_env_file ); then
  die "The carried-over environment file does not satisfy the release contract (see the lines above); fix ${SOURCE_ENV} and retry. Nothing was changed." 1
fi

if [[ $DRY -eq 1 ]]; then
  ok "Dry-run complete. Would adopt ${VERSION_ARG}: releases/${VERSION_ARG}, current -> releases/${VERSION_ARG}, installed-version ${CURRENT_TARGET##*/} -> ${VERSION_ARG}"
  exit 0
fi

# --- 4. record, then switch ------------------------------------------------------
mkdir -p "$ADOPT_STATE_DIR"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
RECORD="${ADOPT_STATE_DIR}/${STAMP}-${VERSION_ARG}.json"
python3 - "$RECORD" "$VERSION_ARG" "$DEST" "$(read_installed_version 0 2>/dev/null || true)" \
  "$(tr -d '[:space:]' < "${STATE_DIR}/active-release" 2>/dev/null || true)" \
  "$CURRENT_TARGET" "$(read_link_target "$(previous_symlink)")" "$STAMP" <<'PY'
import json, os, sys
path, version, adopted, installed, active, current, previous, stamp = sys.argv[1:]
record = {"version": version, "adopted_dir": adopted, "previous_installed_version": installed or None,
          "previous_active_release": active or None, "previous_current_target": current or None,
          "previous_previous_target": previous or None, "recorded_at": stamp, "applied": False}
with open(path, "w", encoding="utf-8") as stream:
    json.dump(record, stream, indent=2)
    stream.write("\n")
    stream.flush()
    os.fsync(stream.fileno())
os.chmod(path, 0o600)
PY
mv -- "$STAGING" "$DEST"
STAGING=""
ensure_release_v1_link "$DEST"
write_installed_version "$VERSION_ARG"
switch_current "$VERSION_ARG"
python3 - "$RECORD" <<'PY'
import json, os, sys
path = sys.argv[1]
record = json.load(open(path, encoding="utf-8"))
record["applied"] = True
with open(path, "w", encoding="utf-8") as stream:
    json.dump(record, stream, indent=2)
    stream.write("\n")
    stream.flush()
    os.fsync(stream.fileno())
PY
fsync_dir "$INSTALL_ROOT"

if [[ -n "$MARK_HOOKS" ]]; then
  IFS=',' read -ra HOOK_IDS <<< "$MARK_HOOKS"
  for hook_id in "${HOOK_IDS[@]}"; do
    python3 "${DEST}/upgrade/post_upgrade.py" mark "$STATE_DIR" "$hook_id" "$VERSION_ARG" >/dev/null
    ok "Post-upgrade hook marked as already applied: ${hook_id}"
  done
fi

ok "Adopted ${VERSION_ARG}: ${DEST}"
log "Record: ${RECORD} (undo with: adopt-release.sh --revert)"
log "Next: re-run ${DEST}/agent/install-agent.sh (idempotent) so the systemd units follow the new tree, then verify the agent heartbeat."
