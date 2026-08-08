#!/usr/bin/env bash
# neosecra upgrade — apply a target version upgrade
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
V1_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${V1_ROOT}/lib/common.sh"
source "${V1_ROOT}/lib/manifest.sh"
source "${V1_ROOT}/lib/docker.sh"
source "${V1_ROOT}/lib/logging.sh"

# ---------------------------------------------------------------------------
# T4 TLS: CA certificate for update.neosecra.com
# The CA root cert is bundled with the distribution archive so upgrade.sh
# can verify the update server TLS without relying on system trust store.
# Override via NEOSECRA_CA_CERT env var.
#
# TLS mode selection:
#   NEOSECRA_TLS_MODE=public   (default) — Let's Encrypt, no CA cert needed
#   NEOSECRA_TLS_MODE=internal — Custom CA, uses --cacert
# ---------------------------------------------------------------------------
NEOSECRA_TLS_MODE="${NEOSECRA_TLS_MODE:-public}"
CURL_OPTS=("-fsSL" "-H" "User-Agent: NeoSecra-Upgrader/1.0")
if [[ "${NEOSECRA_TLS_MODE}" == "internal" ]]; then
  NEOSECRA_CA_CERT="${NEOSECRA_CA_CERT:-${SCRIPT_DIR}/../ca/update-neosecra-com-root.crt}"
  if [[ -f "$NEOSECRA_CA_CERT" ]]; then
    CURL_OPTS+=("--cacert" "$NEOSECRA_CA_CERT")
  fi
fi


source "${V1_ROOT}/lib/state.sh"

usage() { cat <<EOF
neosecra upgrade — upgrade to a target version
Usage: neosecra upgrade [version] [--bundle <path>] [--rollback-on-failure] [--dry-run] [--help]

Without a version, the assessment stable channel is used.
EOF
}

TARGET=""; BUNDLE=""; ROLLBACK=0; DRY=0; TARGET_FROM_ARG=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h)          usage; exit 0 ;;
    --bundle)           shift; BUNDLE="$1" ;;
    --rollback-on-failure) ROLLBACK=1 ;;
    --dry-run)          DRY=1 ;;
    -*)                 usage; die "unknown option: $1" 2 ;;
    *)                  TARGET="$1"; TARGET_FROM_ARG=1 ;;
  esac
  shift
done

CHANNEL_URL="${NEOSECRA_CHANNEL_URL:-https://update.neosecra.com/channels/assessment-stable.json}"
ARCHIVE_URL="${NEOSECRA_DISTRIBUTION_ARCHIVE_URL:-}"
SIGNATURE_PUBKEY="${NEOSECRA_SIGNATURE_PUBKEY:-${SCRIPT_DIR}/update-neosecra-com.pub}"
NEOSECRA_REQUIRE_SIGNATURE="${NEOSECRA_REQUIRE_SIGNATURE:-1}"

# ---------------------------------------------------------------------------
# U1: State tracking for fail recovery
# ---------------------------------------------------------------------------
_SERVICES_STOPPED=0
_COMMITTED=0
_PREVIOUS_VERSION=""

_upgrade_cleanup() {
  local rc=$?
  release_lock
  if [[ $rc -ne 0 && $_SERVICES_STOPPED -eq 1 && $_COMMITTED -eq 0 ]]; then
    err "Upgrade failed — attempting to restore previous release services"
    recover_previous_release || err "Automatic recovery failed — services may be down"
  fi
}

# ---------------------------------------------------------------------------
# Version comparison (semver-aware, returns 0 if a >= b)
# ---------------------------------------------------------------------------
ver_ge() {
  local a="$1" b="$2"
  local apad bpad
  apad=$(printf '%s' "$a" | awk -F. '{printf "%010d_%010d_%010d\n", $1, $2, $3}' 2>/dev/null || echo "$a")
  bpad=$(printf '%s' "$b" | awk -F. '{printf "%010d_%010d_%010d\n", $1, $2, $3}' 2>/dev/null || echo "$b")
  [[ "$apad" < "$bpad" ]] && return 1
  return 0
}

# ---------------------------------------------------------------------------
# Fetch channel JSON with parser detection (python3 > jq > grep/sed)
# ---------------------------------------------------------------------------
fetch_channel_json() {
  local url="${1:-$CHANNEL_URL}"
  curl "${CURL_OPTS[@]}" "$url" 2>/dev/null || return 1
}

parse_channel_current_version() {
  local json="$1"
  if command -v python3 &>/dev/null; then
    python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('current_version',''))" <<< "$json" 2>/dev/null
  elif command -v jq &>/dev/null; then
    jq -r '.current_version // empty' <<< "$json" 2>/dev/null
  else
    printf '%s\n' "$json" | sed -nE 's/.*"current_version"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' | head -n1
  fi
}

parse_channel_archive_url() {
  local json="$1" version="$2"
  if command -v python3 &>/dev/null; then
    python3 -c "
import json,sys
d=json.loads(sys.stdin.read())
for r in d.get('releases',[]):
    if r.get('version')==sys.argv[1]:
        a = r.get('archive',{})
        if isinstance(a, dict):
            print(a.get('url','') or '')
        else:
            print(a or r.get('url','') or '')
        break
" "$version" <<< "$json" 2>/dev/null
  elif command -v jq &>/dev/null; then
    jq -r --arg v "$version" '.releases[] | select(.version==$v) | ((.archive | if type=="object" then .url else . end) // .url // empty)' <<< "$json" 2>/dev/null
  else
    local url
    local version_block
    version_block=$(printf '%s\n' "$json" | grep -A10 "\"version\":[[:space:]]*\"$version\"" 2>/dev/null)
    if [[ -n "$version_block" ]]; then
      url=$(printf '%s\n' "$version_block" | grep -A6 '"archive":[[:space:]]*{' | grep '"url"' | sed -nE 's/.*"url"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' | head -n1)
    fi
    if [[ -z "$url" ]]; then
      url=$(printf '%s\n' "$json" | grep -A5 "\"version\":[[:space:]]*\"$version\"" | sed -nE 's/.*"(archive|url)"[[:space:]]*:[[:space:]]*"([^"]+)".*/\2/p' | head -n1)
    fi
    printf '%s' "$url"
  fi
}

parse_channel_release_sha256() {
  local json="$1" version="$2"
  if command -v python3 &>/dev/null; then
    python3 -c "
import json,sys
d=json.loads(sys.stdin.read())
for r in d.get('releases',[]):
    if r.get('version')==sys.argv[1]:
        a = r.get('archive',{})
        if isinstance(a, dict):
            print(a.get('sha256','') or '')
        else:
            print(r.get('sha256','') or '')
        break
" "$version" <<< "$json" 2>/dev/null
  elif command -v jq &>/dev/null; then
    jq -r --arg v "$version" '.releases[] | select(.version==$v) | ((.archive | if type=="object" then .sha256 else empty end) // .sha256 // empty)' <<< "$json" 2>/dev/null
  else
    local sha
    local version_block
    version_block=$(printf '%s\n' "$json" | grep -A10 "\"version\":[[:space:]]*\"$version\"" 2>/dev/null)
    if [[ -n "$version_block" ]]; then
      sha=$(printf '%s\n' "$version_block" | grep -A6 '"archive":[[:space:]]*{' | grep '"sha256"' | sed -nE 's/.*"sha256"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' | head -n1)
    fi
    if [[ -z "$sha" ]]; then
      sha=$(printf '%s\n' "$json" | grep -A8 "\"version\":[[:space:]]*\"$version\"" | sed -nE 's/.*"sha256"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' | head -n1)
    fi
    printf '%s' "$sha"
  fi
}

# ---------------------------------------------------------------------------
# Download and verify artifacts
# ---------------------------------------------------------------------------
verify_sha256() {
  local file="$1" expected_hash="$2" label="${3:-artifact}"
  [[ -n "$expected_hash" ]] || die "SHA-256 hash not provided for verification" 4
  local actual
  actual=$(sha256sum "$file" | cut -d' ' -f1)
  if [[ "$actual" != "$expected_hash" ]]; then
    die "SHA-256 mismatch for ${label}: expected ${expected_hash}, got ${actual}" 4
  fi
  ok "SHA-256 verified for ${label}"
}

verify_minisign() {
  local file="$1" sig_file="$2" pubkey="$3" label="${4:-artifact}"
  if ! command -v minisign &>/dev/null; then
    if [[ "${NEOSECRA_REQUIRE_SIGNATURE:-1}" == "1" ]]; then
      die "Minisign binary required (NEOSECRA_REQUIRE_SIGNATURE=1) but not found" 4
    fi
    warn "minisign not found — signature verification SKIPPED for ${label} (checksum+TLS still enforced)"
    return 0
  fi
  [[ -f "$pubkey" ]] || die "Minisign public key not found: ${pubkey}" 4
  [[ -f "$sig_file" ]] || die "Minisign signature file not found: ${sig_file}" 4
  minisign -Vm "$file" -P "$(cat "$pubkey")" -x "$sig_file" 2>/dev/null || \
    die "Minisign signature verification FAILED for ${label}" 4
  ok "Minisign signature verified for ${label}"
}

resolve_channel_target() {
  local json target
  json="$(fetch_channel_json "$CHANNEL_URL")" || {
    warn "Channel unreachable: ${CHANNEL_URL}"
    return 1
  }
  target="$(parse_channel_current_version "$json")"
  printf '%s' "$target"
}

if [[ -z "$TARGET" ]]; then
  TARGET="$(resolve_channel_target)"
  [[ -n "$TARGET" ]] || TARGET="$(read_version)"
fi

# ---------------------------------------------------------------------------
# U6: Script checksum divergence check
# Compare own script checksums against the release-artifact manifest.
# Warn-only (backward compat), logs divergence to journal.
# ---------------------------------------------------------------------------
check_script_divergence() {
  local manifest_checksums
  manifest_checksums="$(manifest_field script_checksums 2>/dev/null || true)"
  [[ -z "$manifest_checksums" ]] && return 0  # No checksums in manifest (pre-U7 artifact)
  local divergence=0
  for script in upgrade.sh install/preflight.sh install/postflight.sh lib/common.sh lib/manifest.sh lib/state.sh lib/docker.sh lib/logging.sh; do
    local expected actual
    expected=$(echo "$manifest_checksums" | grep -o "${script}=[^, }]*" | cut -d= -f2 || true)
    [[ -z "$expected" ]] && continue
    actual=$(sha256sum "${V1_ROOT}/${script}" 2>/dev/null | cut -d' ' -f1 || true)
    if [[ -n "$actual" && "$actual" != "$expected" ]]; then
      warn "Script divergence: ${script} checksum ${actual} != manifest ${expected}"
      divergence=1
    fi
  done
  if [[ $divergence -eq 1 ]]; then
    warn "Script checksum divergence detected — live skeleton may have been edited outside release process"
    write_journal "divergence-$(date -u +%Y%m%dT%H%M%SZ).json" "$CURRENT" "divergence-warn"
  fi
}

prepare_target_release() {
  local target="$1" dest backup_path tmp_manifest
  dest="$(release_dir "$target")"

  if [[ "$(readlink -f "$dest" 2>/dev/null || true)" != "$(readlink -f "$V1_ROOT" 2>/dev/null || true)" ]]; then
    if [[ -e "$dest" ]]; then
      backup_path="${BACKUP_ROOT}/preupgrade-release-${target}-$(date -u +%Y%m%dT%H%M%SZ)"
      mkdir -p "$backup_path"
      cp -a "$dest" "${backup_path}/release-${target}"
      warn "Existing target release backed up: ${backup_path}/release-${target}"
    fi
    mkdir -p "$dest"
    cp -a "$V1_ROOT/." "$dest/"
  fi

  printf '%s\n' "$target" > "${dest}/VERSION"
  if [[ -f "${dest}/release-manifest.yaml" ]]; then
    tmp_manifest="$(mktemp)"
    awk -v target="$target" '
      /^version:/ { print "version: " target; next }
      { print }
    ' "${dest}/release-manifest.yaml" > "$tmp_manifest"
    mv "$tmp_manifest" "${dest}/release-manifest.yaml"
  fi
}

CURRENT=$(read_installed_version 2>/dev/null || true)
[[ -n "$CURRENT" && "$CURRENT" != "none" ]] || CURRENT=$(read_version)

# ---------------------------------------------------------------------------
# Bootstrap: when channel target differs from installed release metadata,
# download distribution archive from update server, verify, then re-invoke.
# ---------------------------------------------------------------------------
if [[ $TARGET_FROM_ARG -eq 0 && "$TARGET" != "$(read_version)" && "${NEOSECRA_UPGRADE_BOOTSTRAP:-1}" == "1" ]]; then
  log "Channel target ${TARGET} requires newer installer metadata; refreshing from update server..."

  BOOTSTRAP_DL_URL="https://update.neosecra.com/releases/${TARGET}/bootstrap.sh"

  CHANNEL_JSON="$(fetch_channel_json "$CHANNEL_URL")" || true

  RESOLVED_ARCHIVE_URL="$(parse_channel_archive_url "${CHANNEL_JSON:-}" "$TARGET")"
  [[ -z "$RESOLVED_ARCHIVE_URL" ]] && \
    RESOLVED_ARCHIVE_URL="https://update.neosecra.com/releases/${TARGET}/distribution-${TARGET}.tar.gz"
  RESOLVED_ARCHIVE_URL="${NEOSECRA_DISTRIBUTION_ARCHIVE_URL:-$RESOLVED_ARCHIVE_URL}"

  DL_DIR="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${DL_DIR}'" EXIT

  curl "${CURL_OPTS[@]}" -o "${DL_DIR}/distribution.tar.gz" "$RESOLVED_ARCHIVE_URL"

  EXPECTED_SHA256="$(parse_channel_release_sha256 "${CHANNEL_JSON:-}" "$TARGET")"
  if [[ -n "$EXPECTED_SHA256" ]]; then
    verify_sha256 "${DL_DIR}/distribution.tar.gz" "$EXPECTED_SHA256" "distribution.tar.gz (from channel JSON)"
  else
    curl "${CURL_OPTS[@]}" -o "${DL_DIR}/distribution.tar.gz.sha256" "${RESOLVED_ARCHIVE_URL}.sha256" 2>/dev/null || true
    if [[ -f "${DL_DIR}/distribution.tar.gz.sha256" ]]; then
      (cd "${DL_DIR}" && sha256sum -c "distribution.tar.gz.sha256") || \
        die "SHA-256 verification failed for distribution.tar.gz (.sha256 file)" 4
      ok "SHA-256 verified for distribution.tar.gz (.sha256 file)"
    else
      warn "No SHA-256 hash available for distribution.tar.gz — skipping checksum verification"
    fi
  fi

  if curl "${CURL_OPTS[@]}" -o "${DL_DIR}/distribution.tar.gz.minisig" "${RESOLVED_ARCHIVE_URL}.minisig" 2>/dev/null; then
    verify_minisign "${DL_DIR}/distribution.tar.gz" "${DL_DIR}/distribution.tar.gz.minisig" \
      "$SIGNATURE_PUBKEY" "distribution.tar.gz"
  else
    warn "No minisign signature file found at ${RESOLVED_ARCHIVE_URL}.minisig — skipping signature verification"
  fi

  log "Archive verified; downloading and verifying bootstrap.sh..."
  curl "${CURL_OPTS[@]}" -o "${DL_DIR}/bootstrap.sh" "$BOOTSTRAP_DL_URL"
  curl "${CURL_OPTS[@]}" -o "${DL_DIR}/bootstrap.sh.sha256" "${BOOTSTRAP_DL_URL}.sha256" 2>/dev/null || true
  if [[ -f "${DL_DIR}/bootstrap.sh.sha256" ]]; then
    (cd "${DL_DIR}" && sha256sum -c "bootstrap.sh.sha256") || \
      die "SHA-256 verification failed for bootstrap.sh" 4
    ok "SHA-256 verified for bootstrap.sh"
  else
    die "No SHA-256 hash available for bootstrap.sh — refusing to execute unverified script" 4
  fi

  chmod +x "${DL_DIR}/bootstrap.sh"
  NEOSECRA_DISTRIBUTION_ARCHIVE_URL="file://${DL_DIR}/distribution.tar.gz" \
    bash "${DL_DIR}/bootstrap.sh"
  exit $?
fi

# ---------------------------------------------------------------------------
# U8 fix: target == current → no-op, don't touch services
# ---------------------------------------------------------------------------
if [[ "$TARGET" == "$CURRENT" ]]; then
  ok "Already on target version: ${TARGET} — no upgrade needed"
  exit 0
fi

log "Upgrade: ${CURRENT} -> ${TARGET}"

# ---------------------------------------------------------------------------
# Downgrade protection
# ---------------------------------------------------------------------------
if ver_ge "$CURRENT" "$TARGET"; then
  if [[ "${NEOSECRA_ALLOW_DOWNGRADE:-0}" != "1" ]]; then
    die "Downgrade from ${CURRENT} to ${TARGET} refused. Set NEOSECRA_ALLOW_DOWNGRADE=1 to force" 5
  fi
  warn "Downgrade ${CURRENT} → ${TARGET} (NEOSECRA_ALLOW_DOWNGRADE=1)"
fi

acquire_lock
trap _upgrade_cleanup EXIT

_PREVIOUS_VERSION="$CURRENT"

# --- Environment initialization ---
initialize_env_file
apply_release_image_refs "$TARGET"
validate_env_file || die ".env.v1 validation failed" 2

# --- Preflight ---
bash "${V1_ROOT}/install/preflight.sh" || die "Preflight failed" 10
ok "Preflight passed"

[[ $DRY -eq 1 ]] && { ok "Dry-run complete"; exit 0; }

# --- Script divergence check (U6) ---
check_script_divergence

# --- Prepare target release dir early (U1: needed for postflight target manifest) ---
prepare_target_release "$TARGET"
TARGET_MANIFEST="$(release_dir "$TARGET")/release-manifest.yaml"
TARGET_DB_REV=""
[[ -f "$TARGET_MANIFEST" ]] && TARGET_DB_REV="$(manifest_field database_revision "$TARGET_MANIFEST" 2>/dev/null || true)"

# --- Backup ---
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
BACKUP_TARGET="${BACKUP_ROOT}/${STAMP}-${CURRENT}"
mkdir -p "$BACKUP_TARGET"
bash "${V1_ROOT}/backup/backup.sh" --target "$BACKUP_TARGET"
ok "Pre-upgrade backup: ${BACKUP_TARGET}"

# --- Pull images ---
if [[ -n "$BUNDLE" ]]; then
  TMP_DIR=$(mktemp -d)
  tar xzf "$BUNDLE" -C "$TMP_DIR"
  for img in "$TMP_DIR"/images/*.tar; do
    [[ -f "$img" ]] && docker load -i "$img"
  done
  warn "Temporary bundle extraction left for audit: ${TMP_DIR}"
else
  ghcr_login
  for service in backend worker frontend; do
    pull_service_image "$service"
  done
fi

# --- Dependencies ---
log "Ensuring PostgreSQL and Redis are running..."
ensure_frontend_tls

run_compose up -d postgres redis
wait_service_healthy postgres 90
wait_service_healthy redis 90
reconcile_postgres_password

# --- Stop app services before schema change (DEP-08) ---
log "Stopping application services before migration..."
run_compose stop backend worker frontend beat || warn "Some services were not running"
_SERVICES_STOPPED=1

# --- Migrate ---
log "Running migrations..."
MIGRATE_OK=0
for _ in 1 2 3; do
  run_compose run --rm backend alembic upgrade head && { MIGRATE_OK=1; break; }
  sleep 3
done
if [[ $MIGRATE_OK -eq 0 ]]; then
  err "Migration failed"
  [[ $ROLLBACK -eq 1 ]] && bash "${V1_ROOT}/upgrade/rollback.sh" --to "$CURRENT" --from-backup "$BACKUP_TARGET"
  die "Upgrade failed at migration" 1
fi
ok "Migrations applied"
ensure_assessment_schema_compatibility || die "Assessment schema compatibility repair failed" 11
sync_initial_admin_credentials || die "Initial admin credential synchronization failed" 11

# --- Restart ---
if ! run_compose up -d --force-recreate backend worker beat frontend; then
  print_service_diagnostics backend worker frontend
  die "Application services failed to start after upgrade" 13
fi
wait_service_healthy backend 120
wait_service_running worker 60
wait_service_running frontend 60
wait_frontend_http 120 || { print_service_diagnostics frontend; die "Frontend HTTP not reachable within 120s" 13; }
wait_frontend_api_proxy 120 || { print_service_diagnostics frontend backend; die "Frontend API proxy not reachable within 120s" 13; }
verify_initial_admin_login_via_frontend || { print_service_diagnostics frontend backend; die "Initial admin login verification failed" 13; }

# --- U2: Postflight reads TARGET manifest (pass --target and expected db revision) ---
POSTFLIGHT_ARGS=(--timeout 120 --target "$TARGET")
[[ -n "$TARGET_DB_REV" ]] && POSTFLIGHT_ARGS+=(--expected-revision "$TARGET_DB_REV")

if bash "${V1_ROOT}/install/postflight.sh" "${POSTFLIGHT_ARGS[@]}"; then
  ok "Health verification passed"
else
  err "Health verification failed"
  [[ $ROLLBACK -eq 1 ]] && bash "${V1_ROOT}/upgrade/rollback.sh" --to "$CURRENT" --from-backup "$BACKUP_TARGET"
  die "Upgrade failed at health check" 1
fi

# --- State (commit) ---
write_installed_version "$TARGET"
switch_current "$TARGET"
write_journal "upgrade-${CURRENT}-to-${TARGET}-$(date -u +%Y%m%dT%H%M%SZ).json" "$CURRENT" "completed"
_COMMITTED=1

ok "Upgrade complete: ${CURRENT} -> ${TARGET}"
