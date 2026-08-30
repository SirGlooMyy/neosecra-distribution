#!/usr/bin/env bash
# neosecra upgrade — apply a target version upgrade
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
V1_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${V1_ROOT}/lib/common.sh"
source "${V1_ROOT}/lib/manifest.sh"
source "${V1_ROOT}/lib/docker.sh"
source "${V1_ROOT}/lib/state.sh"

# ---------------------------------------------------------------------------
# TLS for channel/payload fetches (mirrors deployment/upgrade/upgrade.sh):
#   NEOSECRA_TLS_MODE=public   (default) — Let's Encrypt, system trust store
#   NEOSECRA_TLS_MODE=internal — custom CA via NEOSECRA_CA_CERT
# An explicit CURL_CA_BUNDLE from the environment is honored either way.
# ---------------------------------------------------------------------------
NEOSECRA_TLS_MODE="${NEOSECRA_TLS_MODE:-public}"
CURL_OPTS=("-fsSL" "-H" "User-Agent: NeoSecra-Upgrader/1.0")
if [[ "${NEOSECRA_TLS_MODE}" == "internal" ]]; then
  NEOSECRA_CA_CERT="${NEOSECRA_CA_CERT:-${V1_ROOT}/ca/update-neosecra-com-root.crt}"
  if [[ -f "$NEOSECRA_CA_CERT" ]]; then
    CURL_OPTS+=("--cacert" "$NEOSECRA_CA_CERT")
  fi
fi
if [[ -n "${CURL_CA_BUNDLE:-}" && -f "${CURL_CA_BUNDLE}" ]]; then
  CURL_OPTS+=("--cacert" "$CURL_CA_BUNDLE")
fi

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

CHANNEL_URL="${NEOSECRA_CHANNEL_URL:-${UPGRADE_CHANNEL_URL:-https://update.neosecra.com/channels/assessment-stable.json}}"
BOOTSTRAP_URL="${NEOSECRA_BOOTSTRAP_URL:-https://raw.githubusercontent.com/SirGlooMyy/neosecra-distribution/fix/assessment-live-installer/bootstrap.sh}"
ARCHIVE_URL="${NEOSECRA_DISTRIBUTION_ARCHIVE_URL:-https://github.com/SirGlooMyy/neosecra-distribution/archive/refs/heads/fix/assessment-live-installer.tar.gz}"
SIGNATURE_PUBKEY="${NEOSECRA_SIGNATURE_PUBKEY:-${V1_ROOT}/ca/update-neosecra-com.pub}"
# Release signatures are mandatory; an environment override must not permit
# an untrusted payload to reach the installation path.
if [[ "${NEOSECRA_REQUIRE_SIGNATURE:-1}" != "1" ]]; then
  die "NEOSECRA_REQUIRE_SIGNATURE=0 is unsupported; signed releases are mandatory" 4
fi
NEOSECRA_REQUIRE_SIGNATURE=1

# ---------------------------------------------------------------------------
# Channel fetch + release entry parsers (python3 > jq > grep/sed fallbacks)
# ---------------------------------------------------------------------------
fetch_channel_json() {
  local url="${1:-$CHANNEL_URL}"
  curl "${CURL_OPTS[@]}" "$url" 2>/dev/null || return 1
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
# Download verification (fail closed)
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
  command -v minisign &>/dev/null || die "Minisign binary required for ${label} but not found" 4
  [[ -f "$pubkey" ]] || die "Minisign public key not found: ${pubkey}" 4
  [[ -f "$sig_file" ]] || die "Minisign signature file not found: ${sig_file}" 4
  # Prefer the key FILE form (-p): shipped .pub files carry an "untrusted
  # comment" first line, which the -P string form cannot parse.
  if ! minisign -Vm "$file" -p "$pubkey" -x "$sig_file" 2>/dev/null; then
    local key_line
    key_line="$(grep -m1 '^RW' "$pubkey" 2>/dev/null || true)"
    if [[ -z "$key_line" ]] || ! minisign -Vm "$file" -P "$key_line" -x "$sig_file" 2>/dev/null; then
      die "Minisign signature verification FAILED for ${label}" 4
    fi
  fi
  ok "Minisign signature verified for ${label}"
}

verify_channel_manifest() {
  local url="$1" json="$2" tmpdir
  [[ -n "$json" ]] || die "Empty channel manifest — refusing unsigned update metadata" 4
  tmpdir="$(mktemp -d)"
  # curl/command substitution strips the transport newline; channel files are
  # signed as canonical JSON bytes with a trailing LF.
  printf '%s\n' "$json" > "${tmpdir}/channel.json"
  if ! curl "${CURL_OPTS[@]}" -o "${tmpdir}/channel.json.minisig" "${url}.minisig" 2>/dev/null; then
    rm -rf "$tmpdir"
    die "Channel signature not downloadable (${url}.minisig) — refusing update" 4
  fi
  verify_minisign "${tmpdir}/channel.json" "${tmpdir}/channel.json.minisig" \
    "$SIGNATURE_PUBKEY" "channel manifest"
  rm -rf "$tmpdir"
}

resolve_channel_target() {
  local json target
  json="$(fetch_channel_json "$CHANNEL_URL" || true)"
  [[ -n "$json" ]] && verify_channel_manifest "$CHANNEL_URL" "$json"
  target="$(printf '%s\n' "$json" | sed -nE 's/.*"current_version"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' | head -n1)"
  printf '%s' "$target"
}

if [[ -z "$TARGET" ]]; then
  TARGET="$(resolve_channel_target)"
  [[ -n "$TARGET" ]] || TARGET="$(read_version)"
fi

# Scratch dirs created by prepare_target_release (download dir + staging dir);
# cleaned on any exit so a failed preparation never leaves half-extracted
# release content behind.
_PTR_CLEANUP=()
_prepare_release_cleanup() {
  ((${#_PTR_CLEANUP[@]})) || return 0
  rm -rf "${_PTR_CLEANUP[@]}" 2>/dev/null || true
  _PTR_CLEANUP=()
}

# ---------------------------------------------------------------------------
# Bug #21: build releases/<target> from the SIGNED CHANNEL PAYLOAD, not from
# the current tree. The old implementation copied "$V1_ROOT/." into the
# target release, so script fixes shipped with a new release never reached
# the host and every one-click upgrade ran with stale tooling.
#
# Flow: resolve the distribution archive URL + sha256 from the channel JSON
# (the update-agent verifies the channel minisig before invoking us) ->
# download over verified TLS -> verify sha256 AND minisig against the channel
# pubkey -> extract to a staging dir inside RELEASES_DIR -> validate the
# expected layout -> carry local config (.env.v1 / config/tls) -> atomic mv
# into releases/<target>. Any download/verify/layout failure aborts BEFORE
# the current symlink or containers are touched (fail closed).
# ---------------------------------------------------------------------------
prepare_target_release() {
  local target="$1" dest backup_path
  dest="$(release_dir "$target")"

  # Target dir IS the running tree (same resolved path): nothing to stage.
  if [[ "$(readlink -f "$dest" 2>/dev/null || true)" == "$(readlink -f "$V1_ROOT" 2>/dev/null || true)" ]]; then
    return 0
  fi

  # Drop staging leftovers from a previous failed attempt (idempotent re-run).
  rm -rf "${RELEASES_DIR}"/.staging-"${target}".* 2>/dev/null || true

  local channel_json archive_url expected_sha256
  channel_json="${CHANNEL_JSON:-}"
  if [[ -z "$channel_json" ]]; then
    channel_json="$(fetch_channel_json "$CHANNEL_URL")" || \
      die "Channel unreachable (${CHANNEL_URL}) — cannot resolve the release payload for ${target}; refusing to copy the current tree" 4
  fi
  verify_channel_manifest "$CHANNEL_URL" "$channel_json"
  archive_url="${NEOSECRA_DISTRIBUTION_ARCHIVE_URL:-$(parse_channel_archive_url "$channel_json" "$target")}"
  [[ -n "$archive_url" ]] || \
    die "Channel has no archive URL for release ${target} — refusing to fall back to copying the current tree" 4
  expected_sha256="$(parse_channel_release_sha256 "$channel_json" "$target")"

  local dl_dir staging
  dl_dir="$(mktemp -d)"
  staging="${RELEASES_DIR}/.staging-${target}.$$"
  mkdir -p "$staging"
  _PTR_CLEANUP+=("$dl_dir" "$staging")

  log "Downloading release payload for ${target}: ${archive_url}"
  curl "${CURL_OPTS[@]}" -o "${dl_dir}/distribution.tar.gz" "$archive_url" || \
    die "Download failed: ${archive_url}" 4

  if [[ -n "$expected_sha256" ]]; then
    verify_sha256 "${dl_dir}/distribution.tar.gz" "$expected_sha256" "distribution archive ${target} (channel JSON)"
  else
    curl "${CURL_OPTS[@]}" -o "${dl_dir}/distribution.tar.gz.sha256" "${archive_url}.sha256" 2>/dev/null || true
    if [[ -f "${dl_dir}/distribution.tar.gz.sha256" ]]; then
      (cd "$dl_dir" && sha256sum -c distribution.tar.gz.sha256 >/dev/null) || \
        die "SHA-256 verification failed for distribution archive ${target} (.sha256 sidecar)" 4
      ok "SHA-256 verified for distribution archive ${target} (.sha256 sidecar)"
    else
      die "No SHA-256 available for release ${target} (channel entry nor .sha256 sidecar) — refusing unverified payload" 4
    fi
  fi

  if curl "${CURL_OPTS[@]}" -o "${dl_dir}/distribution.tar.gz.minisig" "${archive_url}.minisig" 2>/dev/null; then
    verify_minisign "${dl_dir}/distribution.tar.gz" "${dl_dir}/distribution.tar.gz.minisig" \
      "$SIGNATURE_PUBKEY" "distribution archive ${target}"
  else
    die "Minisign signature not downloadable (${archive_url}.minisig) — refusing unsigned release" 4
  fi

  # Extract and validate the expected payload layout:
  #   neosecra-distribution-<ver>/deployment/{VERSION,lib/common.sh,
  #   upgrade/upgrade.sh,docker-compose.v1.yml,...}
  mkdir -p "${dl_dir}/extract"
  tar -xzf "${dl_dir}/distribution.tar.gz" -C "${dl_dir}/extract" || \
    die "Failed to extract release payload for ${target}" 4
  local top payload marker
  top="$(find "${dl_dir}/extract" -mindepth 1 -maxdepth 1 -type d -name 'neosecra-distribution-*' | head -n1)"
  payload="${top}/deployment"
  for marker in VERSION lib/common.sh upgrade/upgrade.sh docker-compose.v1.yml; do
    [[ -e "${payload}/${marker}" ]] || \
      die "Release payload for ${target} lacks the expected layout (missing deployment/${marker}) — aborting" 4
  done
  cp -a "${payload}/." "${staging}/"

  # Carry local config from the running tree (the payload ships templates
  # only). The env file (.env.v1) holds the install secrets; config/tls holds
  # the per-install frontend certificate. When the agent runs us from the v1
  # subtree, the files may live one level up at the release root.
  local env_name env_src tls_src="${V1_ROOT}/config/tls"
  env_name="$(basename "$ENV_FILE")"
  env_src="${V1_ROOT}/${env_name}"
  if [[ ! -f "$env_src" && "$(basename "$V1_ROOT")" == "v1" && -f "${V1_ROOT}/../${env_name}" ]]; then
    env_src="${V1_ROOT}/../${env_name}"
  fi
  if [[ ! -d "$tls_src" && "$(basename "$V1_ROOT")" == "v1" && -d "${V1_ROOT}/../config/tls" ]]; then
    tls_src="${V1_ROOT}/../config/tls"
  fi
  if [[ -f "$env_src" ]]; then
    cp -a "$env_src" "${staging}/${env_name}"
    chmod 0600 "${staging}/${env_name}" 2>/dev/null || true
  fi
  if [[ -d "$tls_src" ]]; then
    mkdir -p "${staging}/config"
    cp -a "$tls_src" "${staging}/config/tls"
  fi
  # Payloads shipping a real v1/ subtree (not the v1 -> . bridge symlink)
  # need the same local config mirrored under v1/ for current/v1/... consumers.
  if [[ -d "${staging}/v1" && ! -L "${staging}/v1" ]]; then
    if [[ -f "${staging}/${env_name}" ]]; then
      cp -a "${staging}/${env_name}" "${staging}/v1/${env_name}"
      chmod 0600 "${staging}/v1/${env_name}" 2>/dev/null || true
    fi
    if [[ -d "${staging}/config/tls" ]]; then
      mkdir -p "${staging}/v1/config"
      rm -rf "${staging}/v1/config/tls"
      cp -a "${staging}/config/tls" "${staging}/v1/config/tls"
    fi
  fi

  # Stamp VERSION + manifest (build-release already stamps them; re-stamp so
  # a NEOSECRA_DISTRIBUTION_ARCHIVE_URL override cannot smuggle a version lie).
  printf '%s\n' "$target" > "${staging}/VERSION"
  if [[ -d "${staging}/v1" && ! -L "${staging}/v1" ]]; then
    printf '%s\n' "$target" > "${staging}/v1/VERSION"
  fi
  local manifest_path
  for manifest_path in "${staging}/release-manifest.yaml" "${staging}/v1/release-manifest.yaml"; do
    [[ -f "$manifest_path" ]] || continue
    awk -v target="$target" '
      /^version:/ { print "version: " target; next }
      { print }
    ' "$manifest_path" > "${manifest_path}.tmp"
    mv "${manifest_path}.tmp" "$manifest_path"
  done

  # Atomically swap into place (staging lives in RELEASES_DIR, so mv is a
  # same-filesystem rename). An existing target dir — e.g. one left by the
  # old copy-based implementation — is backed up first.
  if [[ -e "$dest" ]]; then
    backup_path="${BACKUP_ROOT}/preupgrade-release-${target}-$(date -u +%Y%m%dT%H%M%SZ)"
    mkdir -p "$backup_path"
    cp -a "$dest" "${backup_path}/release-${target}"
    warn "Existing target release backed up: ${backup_path}/release-${target}"
    rm -rf "$dest"
  fi
  mv "$staging" "$dest"
  rm -rf "$dl_dir"
  _PTR_CLEANUP=()

  # The systemd units address the tree through the stable `current/v1/...`
  # path; make sure the freshly prepared release satisfies that layout.
  ensure_release_v1_link "$dest"

  ok "Target release ${target} prepared from signed channel payload: ${dest}"
}

CURRENT=$(read_installed_version 2>/dev/null || true)
[[ -n "$CURRENT" && "$CURRENT" != "none" ]] || CURRENT=$(read_version)
if [[ $TARGET_FROM_ARG -eq 0 && "$TARGET" != "$(read_version)" && "${NEOSECRA_UPGRADE_BOOTSTRAP:-1}" == "1" ]]; then
  log "Channel target ${TARGET} requires newer installer metadata; refreshing from the signed update channel..."
  CHANNEL_JSON="$(fetch_channel_json "$CHANNEL_URL")" || \
    die "Channel unreachable (${CHANNEL_URL}) — refusing bootstrap of unverified installer metadata" 4
  verify_channel_manifest "$CHANNEL_URL" "$CHANNEL_JSON"
  RESOLVED_ARCHIVE_URL="$(parse_channel_archive_url "$CHANNEL_JSON" "$TARGET")"
  [[ -n "$RESOLVED_ARCHIVE_URL" ]] || \
    die "Channel has no archive URL for release ${TARGET} — refusing bootstrap" 4
  RESOLVED_ARCHIVE_URL="${NEOSECRA_DISTRIBUTION_ARCHIVE_URL:-$RESOLVED_ARCHIVE_URL}"
  BOOTSTRAP_URL="${NEOSECRA_BOOTSTRAP_URL:-https://update.neosecra.com/releases/${TARGET}/bootstrap.sh}"
  BOOTSTRAP_TMP="$(mktemp -d)"
  trap 'rm -rf "${BOOTSTRAP_TMP}"' EXIT
  curl "${CURL_OPTS[@]}" -o "${BOOTSTRAP_TMP}/bootstrap.sh" "$BOOTSTRAP_URL" || \
    die "Bootstrap download failed: ${BOOTSTRAP_URL}" 4
  curl "${CURL_OPTS[@]}" -o "${BOOTSTRAP_TMP}/bootstrap.sh.sha256" "${BOOTSTRAP_URL}.sha256" 2>/dev/null || \
    die "Bootstrap SHA-256 sidecar unavailable: ${BOOTSTRAP_URL}.sha256" 4
  (cd "$BOOTSTRAP_TMP" && sha256sum -c bootstrap.sh.sha256 >/dev/null) || \
    die "Bootstrap SHA-256 verification failed" 4
  curl "${CURL_OPTS[@]}" -o "${BOOTSTRAP_TMP}/bootstrap.sh.minisig" "${BOOTSTRAP_URL}.minisig" 2>/dev/null || \
    die "Bootstrap minisig unavailable: ${BOOTSTRAP_URL}.minisig" 4
  verify_minisign "${BOOTSTRAP_TMP}/bootstrap.sh" "${BOOTSTRAP_TMP}/bootstrap.sh.minisig" "$SIGNATURE_PUBKEY" "bootstrap.sh"
  chmod +x "${BOOTSTRAP_TMP}/bootstrap.sh"
  NEOSECRA_DISTRIBUTION_ARCHIVE_URL="$RESOLVED_ARCHIVE_URL" bash "${BOOTSTRAP_TMP}/bootstrap.sh"
  exit $?
fi

log "Upgrade: ${CURRENT} -> ${TARGET}"
if [[ "$TARGET" == "$CURRENT" ]]; then
  ok "Already on latest version: ${TARGET}"
  exit 0
fi

# Lock already held by the calling update-agent (NEOSECRA_AGENT_LOCK_HELD=1);
# taking the same lock path again would die with exit 5 (lock conflict).
[[ "${NEOSECRA_AGENT_LOCK_HELD:-0}" == "1" ]] || acquire_lock
# Always release the state lock, on success AND failure — otherwise every run
# leaves state/.install.lock behind and the next agent-driven upgrade dies
# with LOCK_FAILED. Also drop any prepare_target_release scratch dirs.
trap 'release_lock; _prepare_release_cleanup' EXIT

# --- Environment initialization ---
initialize_env_file
apply_release_image_refs "$TARGET"
validate_env_file || die ".env.v1 validation failed" 2

# --- Preflight ---
bash "${V1_ROOT}/install/preflight.sh" || die "Preflight failed" 10
ok "Preflight passed"

[[ $DRY -eq 1 ]] && { ok "Dry-run complete"; exit 0; }

# --- Prepare target release from the signed channel payload (bug #21) ---
# Must happen BEFORE backup/container changes: any download/verify/layout
# failure aborts here with the current symlink and containers untouched.
prepare_target_release "$TARGET"

# --- Backup ---
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
BACKUP_TARGET="${BACKUP_ROOT}/${STAMP}-${CURRENT}"
mkdir -p "$BACKUP_TARGET"
bash "${V1_ROOT}/backup/backup.sh" --target "$BACKUP_TARGET"
ok "Pre-upgrade backup: ${BACKUP_TARGET}"




# --- Security Enforcement Integration ---


# --- Security Enforcement Integration ---
upsert_env_value_atomic() {
  local key="$1" val="$2" file="${3:-$ENV_FILE}"
  local tmp
  tmp="${file}.tmp.$$"
  python3 -c "
import sys
key, val, file, tmp = sys.argv[1:5]
out = []
found = False
try:
    with open(file, 'r') as f:
        for line in f:
            if line.startswith(key + '='):
                out.append(f'{key}={val}\n')
                found = True
            else:
                out.append(line)
except FileNotFoundError:
    pass
if not found:
    out.append(f'{key}={val}\n')
with open(tmp, 'w') as f:
    f.writelines(out)
" "$key" "$val" "$file" "$tmp" || die "Env update failed" 4
  mv -f "$tmp" "$file"
}

enforce_image_security() {
  local pubkey="${NEOSECRA_COSIGN_PUBKEY:-/etc/neosecra/certs/cosign.pub}"

  if [[ ! -f "${V1_ROOT}/agent/artifact-verifier.sh" ]]; then
    die "SECURITY VIOLATION: artifact-verifier.sh missing" 4
  fi
  source "${V1_ROOT}/agent/artifact-verifier.sh"

  local services_json
  services_json="$(run_compose config --format json 2>/dev/null)" || die "SECURITY VIOLATION: Compose config failure" 4
  [[ -n "$services_json" ]] || die "SECURITY VIOLATION: Service enumeration failure" 4

  local mapping_output
  mapping_output="$(echo "$services_json" | ARCHIVE_SHA256="$EXPECTED_SHA256" LEGACY_ALLOWLIST="${V1_ROOT}/upgrade/legacy_allowlist.json" python3 "${V1_ROOT}/upgrade/verify_mapping.py")" || die "SECURITY VIOLATION: Image mapping failure" 4

  # Backup env file for atomic rollback if verification fails mid-way
  cp -a "$ENV_FILE" "${ENV_FILE}.bak"

  local success=1
  while read -r action arg1 arg2 arg3 arg4 arg5; do
     if [[ -z "$action" ]]; then continue; fi
     if [[ "$action" == "AUDIT_LOG" ]]; then
         log "$action $arg1 $arg2 $arg3 $arg4 $arg5"
     elif [[ "$action" == "ENFORCE" ]]; then
         local service="$arg1" image_ref="$arg2" expected_digest="$arg3"
         echo 'F: PUBKEY'; if [[ ! -f "$pubkey" || ! -s "$pubkey" ]]; then
           success=0; break
         fi
         echo 'F: COSIGN'; if ! command -v cosign >/dev/null 2>&1; then
           success=0; break
         fi
         
         # local digest check
         local local_digest
         local_digest="$(docker inspect --format '{{range .RepoDigests}}{{.}}{{println}}{{end}}' "$image_ref" 2>/dev/null | grep -oP 'sha256:\w+' | head -n1 || true)"
         if [[ "$local_digest" != "$expected_digest" ]]; then
             echo 'F: DIGEST_MISMATCH ' "$local_digest" "$expected_digest"; success=0; break
         fi
         
         echo 'F: SIG'; if ! verify_image_signature "$image_ref" "$expected_digest" "$pubkey"; then
             success=0; break
         fi
         echo 'F: ATT'; if ! verify_image_attestation "$image_ref" "$expected_digest" "$pubkey"; then
             success=0; break
         fi
         
         # Pin
         local env_prefix
         env_prefix="$(echo "$service" | LC_ALL=C tr 'a-z-' 'A-Z_')"
         upsert_env_value_atomic "${env_prefix}_IMAGE" "${image_ref}@${expected_digest}"
         
     elif [[ "$action" == "DEPENDENCY" ]]; then
         local service="$arg1" image_ref="$arg2" expected_digest="$arg3"
         local local_digest
         local_digest="$(docker inspect --format '{{range .RepoDigests}}{{.}}{{println}}{{end}}' "$image_ref" 2>/dev/null | grep -oP 'sha256:\w+' | head -n1 || true)"
         if [[ "$local_digest" != "$expected_digest" ]]; then
             echo 'F: DIGEST_MISMATCH ' "$local_digest" "$expected_digest"; success=0; break
         fi
         local env_prefix
         env_prefix="$(echo "$service" | LC_ALL=C tr 'a-z-' 'A-Z_')"
         upsert_env_value_atomic "${env_prefix}_IMAGE" "${image_ref}@${expected_digest}"
     fi
  done <<< "$mapping_output"

  if [[ $success -eq 0 ]]; then
      # Atomic restore
      mv -f "${ENV_FILE}.bak" "$ENV_FILE"
      die "SECURITY VIOLATION: Enforcement checks failed" 4
  fi
  rm -f "${ENV_FILE}.bak"
  ok "All images enforced and pinned"
}

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
  services="$(run_compose config --services 2>/dev/null || true)"
  for service in $services; do
    pull_service_image "$service"
  done
fi

enforce_image_security


# --- Dependencies ---
log "Ensuring PostgreSQL and Redis are running..."
ensure_frontend_tls

run_compose up -d postgres redis
wait_service_healthy postgres 90
wait_service_healthy redis 90
reconcile_postgres_password

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
if ! run_compose up -d --force-recreate backend worker frontend; then
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
write_installed_version "$TARGET"
switch_current "$TARGET"
write_journal "upgrade-${CURRENT}-to-${TARGET}-$(date -u +%Y%m%dT%H%M%SZ).json"

ok "Upgrade complete: ${CURRENT} -> ${TARGET}"
