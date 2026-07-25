#!/usr/bin/env bash
# neosecra upgrade — apply a target version upgrade
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
V1_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${V1_ROOT}/lib/common.sh"
source "${V1_ROOT}/lib/manifest.sh"
source "${V1_ROOT}/lib/docker.sh"
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
NEOSECRA_REQUIRE_SIGNATURE="${NEOSECRA_REQUIRE_SIGNATURE:-0}"

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
  curl -fsSL "$url" 2>/dev/null || return 1
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
        print(r.get('archive','') or r.get('url',''))
        break
" "$version" <<< "$json" 2>/dev/null
  elif command -v jq &>/dev/null; then
    jq -r --arg v "$version" '.releases[] | select(.version==$v) | .archive // .url // empty' <<< "$json" 2>/dev/null
  else
    printf '%s\n' "$json" | grep -A5 "\"version\":[[:space:]]*\"$version\"" | sed -nE 's/.*"(archive|url)"[[:space:]]*:[[:space:]]*"([^"]+)".*/\2/p' | head -n1
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
        print(r.get('sha256',''))
        break
" "$version" <<< "$json" 2>/dev/null
  elif command -v jq &>/dev/null; then
    jq -r --arg v "$version" '.releases[] | select(.version==$v) | .sha256 // empty' <<< "$json" 2>/dev/null
  else
    printf '%s\n' "$json" | grep -A8 "\"version\":[[:space:]]*\"$version\"" | sed -nE 's/.*"sha256"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' | head -n1
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
    if [[ "${NEOSECRA_REQUIRE_SIGNATURE:-0}" == "1" ]]; then
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

  # Fetch channel JSON to resolve artifact URLs
  CHANNEL_JSON="$(fetch_channel_json "$CHANNEL_URL")" || true

  # Resolve archive URL: prefer from channel JSON, fall back to template
  RESOLVED_ARCHIVE_URL="$(parse_channel_archive_url "${CHANNEL_JSON:-}" "$TARGET")"
  [[ -z "$RESOLVED_ARCHIVE_URL" ]] && \
    RESOLVED_ARCHIVE_URL="https://update.neosecra.com/releases/${TARGET}/distribution.tar.gz"
  RESOLVED_ARCHIVE_URL="${NEOSECRA_DISTRIBUTION_ARCHIVE_URL:-$RESOLVED_ARCHIVE_URL}"

  # Download and verify distribution archive before bootstrapping
  DL_DIR="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${DL_DIR}'" EXIT

  curl -fsSL -o "${DL_DIR}/distribution.tar.gz" "$RESOLVED_ARCHIVE_URL"

  # SHA256 verification — prefer hash from channel JSON, else external .sha256 file
  EXPECTED_SHA256="$(parse_channel_release_sha256 "${CHANNEL_JSON:-}" "$TARGET")"
  if [[ -n "$EXPECTED_SHA256" ]]; then
    verify_sha256 "${DL_DIR}/distribution.tar.gz" "$EXPECTED_SHA256" "distribution.tar.gz (from channel JSON)"
  else
    curl -fsSL -o "${DL_DIR}/distribution.tar.gz.sha256" "${RESOLVED_ARCHIVE_URL}.sha256" 2>/dev/null || true
    if [[ -f "${DL_DIR}/distribution.tar.gz.sha256" ]]; then
      (cd "${DL_DIR}" && sha256sum -c "distribution.tar.gz.sha256") || \
        die "SHA-256 verification failed for distribution.tar.gz (.sha256 file)" 4
      ok "SHA-256 verified for distribution.tar.gz (.sha256 file)"
    else
      warn "No SHA-256 hash available for distribution.tar.gz — skipping checksum verification"
    fi
  fi

  # Minisign verification
  if curl -fsSL -o "${DL_DIR}/distribution.tar.gz.minisig" "${RESOLVED_ARCHIVE_URL}.minisig" 2>/dev/null; then
    verify_minisign "${DL_DIR}/distribution.tar.gz" "${DL_DIR}/distribution.tar.gz.minisig" \
      "$SIGNATURE_PUBKEY" "distribution.tar.gz"
  else
    warn "No minisign signature file found at ${RESOLVED_ARCHIVE_URL}.minisig — skipping signature verification"
  fi

  log "Archive verified; running bootstrap.sh..."
  NEOSECRA_DISTRIBUTION_ARCHIVE_URL="file://${DL_DIR}/distribution.tar.gz" \
    bash <(curl -fsSL "$BOOTSTRAP_DL_URL")
  exit $?
fi

log "Upgrade: ${CURRENT} -> ${TARGET}"
if [[ "$TARGET" == "$CURRENT" ]]; then
  ok "Already on latest version: ${TARGET}"
  exit 0
fi

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

# --- Environment initialization ---
initialize_env_file
apply_release_image_refs "$TARGET"
validate_env_file || die ".env.v1 validation failed" 2

# --- Preflight ---
bash "${V1_ROOT}/install/preflight.sh" || die "Preflight failed" 10
ok "Preflight passed"

[[ $DRY -eq 1 ]] && { ok "Dry-run complete"; exit 0; }

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
run_compose up -d postgres redis
wait_service_healthy postgres 90
wait_service_healthy redis 90
reconcile_postgres_password

# --- Stop app services before schema change (DEP-08) ---
# Old code must not run against the new schema while migrations apply.
log "Stopping application services before migration..."
run_compose stop backend worker frontend beat || warn "Some services were not running"

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

# --- Verify ---
if bash "${V1_ROOT}/install/postflight.sh" --timeout 120; then
  ok "Health verification passed"
else
  err "Health verification failed"
  [[ $ROLLBACK -eq 1 ]] && bash "${V1_ROOT}/upgrade/rollback.sh" --to "$CURRENT" --from-backup "$BACKUP_TARGET"
  die "Upgrade failed at health check" 1
fi

# --- State ---
prepare_target_release "$TARGET"
write_installed_version "$TARGET"
switch_current "$TARGET"
write_journal "upgrade-${CURRENT}-to-${TARGET}-$(date -u +%Y%m%dT%H%M%SZ).json"

ok "Upgrade complete: ${CURRENT} -> ${TARGET}"
