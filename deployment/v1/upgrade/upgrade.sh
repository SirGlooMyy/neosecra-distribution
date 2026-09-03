#!/usr/bin/env bash
# neosecra upgrade — apply a target version upgrade
set -Eeuo pipefail

UPGRADE_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
V1_ROOT="$(cd "${UPGRADE_SCRIPT_DIR}/.." && pwd)"
source "${V1_ROOT}/lib/common.sh"
source "${V1_ROOT}/lib/manifest.sh"
source "${V1_ROOT}/lib/docker.sh"
source "${V1_ROOT}/lib/state.sh"

# Sourced libraries intentionally derive their own helper paths.  Keep the
# canonical upgrade/recovery tree immutable when the runtime context later
# switches to releases/<target>.
ORIGINAL_V1_ROOT="${V1_ROOT}"

# A channel timestamp is staged as ``.channel_updated.new`` and committed only
# after the release has passed every promotion gate.  Any early error must
# remove that staged marker so a failed transaction cannot advertise a release
# that was never activated.
_clear_staged_channel_marker() {
  rm -f -- "${ORIGINAL_V1_ROOT}/.channel_updated.new" 2>/dev/null || true
}

_early_exit_cleanup() {
  local ec=$?
  trap - EXIT
  if [[ -n "${BOOTSTRAP_TMP:-}" ]]; then
    rm -rf -- "${BOOTSTRAP_TMP}" 2>/dev/null || true
  fi
  if [[ "$ec" -ne 0 ]]; then
    _clear_staged_channel_marker
  fi
  exit "$ec"
}

trap _early_exit_cleanup EXIT

# ---------------------------------------------------------------------------
# TLS for channel/payload fetches (mirrors deployment/upgrade/upgrade.sh):
#   NEOSECRA_TLS_MODE=public   (default) — Let's Encrypt, system trust store
#   NEOSECRA_TLS_MODE=internal — custom CA via NEOSECRA_CA_CERT
# An explicit CURL_CA_BUNDLE from the environment is honored either way.
# ---------------------------------------------------------------------------
NEOSECRA_TLS_MODE="${NEOSECRA_TLS_MODE:-public}"
CURL_OPTS=("-fsSL" "--proto" "=https" "--proto-redir" "=https" "-H" "User-Agent: NeoSecra-Upgrader/1.0")
if [[ "${NEOSECRA_TLS_MODE}" == "internal" ]]; then
  NEOSECRA_CA_CERT="${NEOSECRA_CA_CERT:-${V1_ROOT}/ca/update-neosecra-com-root.crt}"
  [[ -f "$NEOSECRA_CA_CERT" ]] || die "Internal TLS mode requires a trusted CA certificate: ${NEOSECRA_CA_CERT}" 4
  CURL_OPTS+=("--cacert" "$NEOSECRA_CA_CERT")
fi
if [[ -n "${CURL_CA_BUNDLE:-}" ]]; then
  [[ -f "${CURL_CA_BUNDLE}" ]] || die "CURL_CA_BUNDLE is not a regular file" 4
  CURL_OPTS+=("--cacert" "$CURL_CA_BUNDLE")
fi

# A file:// artifact is an explicitly offline operation, never an arbitrary
# URL override.  Paths must resolve below the operator-selected offline root;
# the running install tree is not accepted as a hidden fallback source.
OFFLINE_ROOT="${NEOSECRA_OFFLINE_ROOT:-${INSTALL_ROOT}/offline}"
_url_path() {
  local url="$1"
  python3 - "$url" <<'PY'
import sys
from pathlib import Path
from urllib.parse import unquote, urlparse

parsed = urlparse(sys.argv[1])
if parsed.scheme != "file" or parsed.netloc not in ("", "localhost"):
    raise SystemExit(1)
path = unquote(parsed.path)
if not path.startswith("/") or any(part in {"", ".", ".."} for part in Path(path).parts[1:]):
    raise SystemExit(1)
print(path)
PY
}

validate_fetch_url() {
  local url="$1" path root_real path_real
  [[ -n "$url" && "$url" != *$'\n'* && "$url" != *$'\r'* ]] || die "Artifact URL is empty or contains control characters" 4
  case "$url" in
    https://*)
      # No credentials or fragments in release URLs.  TLS verification remains
      # enabled in CURL_OPTS; redirects are followed only by curl after the
      # initial HTTPS request and are separately constrained below.
      [[ "$url" != *'@'* && "$url" != *'#'* ]] || die "Artifact URL contains unsafe userinfo/fragment" 4
      ;;
    file:///*)
      [[ "${NEOSECRA_OFFLINE:-0}" == "1" ]] || die "file:// artifacts require NEOSECRA_OFFLINE=1" 4
      path="$(_url_path "$url")" || die "Offline artifact URL is invalid" 4
      root_real="$(readlink -f "$OFFLINE_ROOT" 2>/dev/null || true)"
      path_real="$(readlink -f "$path" 2>/dev/null || true)"
      [[ -n "$root_real" && -n "$path_real" && ( "$path_real" == "$root_real" || "$path_real" == "$root_real"/* ) ]] || \
        die "Offline artifact is outside NEOSECRA_OFFLINE_ROOT" 4
      ;;
    *)
      die "Only HTTPS or explicitly bounded offline file:// URLs are accepted" 4
      ;;
  esac
}

fetch_url_to_file() {
  local url="$1" destination="$2" path
  validate_fetch_url "$url"
  mkdir -p "$(dirname "$destination")"
  case "$url" in
    file:///*)
      path="$(_url_path "$url")" || die "Offline artifact URL is invalid" 4
      [[ -f "$path" && ! -L "$path" ]] || die "Offline artifact is missing or not a regular file" 4
      cp -- "$path" "$destination" || die "Offline artifact copy failed" 4
      ;;
    https://*)
      curl "${CURL_OPTS[@]}" -o "$destination" "$url" || die "HTTPS artifact download failed: ${url}" 4
      ;;
  esac
  [[ -s "$destination" ]] || die "Downloaded artifact is empty: ${url}" 4
}

usage() { cat <<EOF
neosecra upgrade — upgrade to a target version
Usage: neosecra upgrade [version] [--bundle <path>] [--rollback-on-failure --rollback-auth <auth.json>] [--dry-run] [--help]

Without a version, the assessment stable channel is used.
EOF
}

TARGET=""; BUNDLE=""; ROLLBACK=0; ROLLBACK_AUTH=""; DRY=0; TARGET_FROM_ARG=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h)          usage; exit 0 ;;
    --bundle)           shift; BUNDLE="$1" ;;
    --rollback-on-failure) ROLLBACK=1 ;;
    --rollback-auth)    shift; ROLLBACK_AUTH="${1:-}" ;;
    --dry-run)          DRY=1 ;;
    -*)                 usage; die "unknown option: $1" 2 ;;
    *)                  TARGET="$1"; TARGET_FROM_ARG=1 ;;
  esac
  shift
done

if [[ $ROLLBACK -eq 1 ]]; then
  [[ -n "$ROLLBACK_AUTH" && "$ROLLBACK_AUTH" == /* && "$ROLLBACK_AUTH" != *..* && -f "$ROLLBACK_AUTH" ]] || \
    die "--rollback-on-failure requires a local signed --rollback-auth file" 4
fi

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
if [[ "${NEOSECRA_IGNORE_SIGNATURES:-0}" == "1" ]]; then
  die "NEOSECRA_IGNORE_SIGNATURES is unsupported; signature and attestation verification cannot be bypassed" 4
fi

# ---------------------------------------------------------------------------
# Channel fetch + release entry parsers (python3 > jq > grep/sed fallbacks)
# ---------------------------------------------------------------------------
fetch_channel_json() {
  local url="${1:-$CHANNEL_URL}"
  validate_fetch_url "$url"
  case "$url" in
    file:///*)
      local path
      path="$(_url_path "$url")" || return 1
      [[ -f "$path" && ! -L "$path" ]] || return 1
      cat -- "$path"
      ;;
    https://*) curl "${CURL_OPTS[@]}" "$url" 2>/dev/null || return 1 ;;
  esac
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

load_channel_release_metadata() {
  local json="$1" target="$2"
  CHANNEL_RELEASE_JSON="$(python3 - "$json" "$target" <<'PY'
import json, re, sys

data = json.loads(sys.argv[1])
target = sys.argv[2].strip().lstrip("vV")
semver = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?$")
sha256 = re.compile(r"^[0-9a-f]{64}$")
if not isinstance(data, dict):
    raise SystemExit(1)
channel_name = str(data.get("channel") or "").strip().lower()
product = str(data.get("product_code") or data.get("product") or "").strip().lower()
edition = str(data.get("edition") or "").strip().lower()
safe_name = re.compile(r"^[a-z0-9][a-z0-9_-]{0,127}$")
if not safe_name.fullmatch(channel_name) or not safe_name.fullmatch(product) or not safe_name.fullmatch(edition):
    raise SystemExit(1)
expected_channel = str(__import__("os").environ.get("NEOSECRA_EXPECTED_CHANNEL") or "").strip().lower()
expected_product = str(__import__("os").environ.get("NEOSECRA_EXPECTED_PRODUCT") or "").strip().lower()
expected_edition = str(__import__("os").environ.get("NEOSECRA_EXPECTED_EDITION") or "").strip().lower()
if expected_channel and channel_name != expected_channel:
    raise SystemExit(1)
if expected_product and product != expected_product:
    raise SystemExit(1)
if expected_edition and edition != expected_edition:
    raise SystemExit(1)
status = str(data.get("status") or "").strip().lower()
if status not in {"available", "ready"}:
    raise SystemExit(2)
releases = data.get("releases")
if not isinstance(releases, list) or not releases:
    raise SystemExit(3)
seen = {}
matches = []
for release in releases:
    if not isinstance(release, dict):
        raise SystemExit(4)
    version = str(release.get("version") or "").strip().lstrip("vV")
    if not semver.fullmatch(version) or version in seen:
        raise SystemExit(5)
    seen.add(version)
    if version == target:
        matches.append(release)
if len(matches) != 1:
    raise SystemExit(6)
release = matches[0]
archive = release.get("archive")
if not isinstance(archive, dict):
    raise SystemExit(7)
archive_url = str(archive.get("url") or release.get("archive_url") or "").strip()
archive_sha = str(archive.get("sha256") or release.get("sha256") or "").strip().lower()
archive_sig = str(archive.get("signature_url") or release.get("archive_signature_url") or "").strip()
if not archive_url or not sha256.fullmatch(archive_sha) or not archive_sig:
    raise SystemExit(8)

bundle = release.get("docker_bundle")
if not isinstance(bundle, dict):
    bundle = release.get("bundle") if isinstance(release.get("bundle"), dict) else None
bundle_url = str((bundle or {}).get("url") or release.get("bundle_url") or "").strip()
bundle_sha = str((bundle or {}).get("sha256") or release.get("bundle_sha256") or "").strip().lower()
bundle_sig = str((bundle or {}).get("signature_url") or release.get("bundle_signature_url") or "").strip()
none_bundle = not bundle_url or (bundle_url.rsplit("/", 1)[-1].lower() == "none" and bundle_sha in {"", "0"})
if none_bundle:
    bundle_url = bundle_sha = bundle_sig = ""
elif not sha256.fullmatch(bundle_sha) or not bundle_sig:
    raise SystemExit(9)

minimum = str(release.get("minimum_current_version") or "").strip().lstrip("vV")
if minimum and not semver.fullmatch(minimum):
    raise SystemExit(10)
current = data.get("current_version")
if status in {"available", "ready"}:
    if not isinstance(current, str) or not semver.fullmatch(current.lstrip("vV")) or current.lstrip("vV") not in seen:
        raise SystemExit(11)
result = {
    "channel": channel_name,
    "product": product,
    "edition": edition,
    "status": status,
    "version": target,
    "archive_url": archive_url,
    "archive_sha256": archive_sha,
    "archive_signature_url": archive_sig,
    "bundle_url": bundle_url,
    "bundle_sha256": bundle_sha,
    "bundle_signature_url": bundle_sig,
    "minimum_current_version": minimum,
}
print(json.dumps(result, sort_keys=True, separators=(",", ":")))
PY
  )" || die "Signed channel release metadata is invalid or unavailable for ${target}" 4
  CHANNEL_ARCHIVE_URL="$(python3 - "$CHANNEL_RELEASE_JSON" <<'PY'
import json,sys; print(json.loads(sys.argv[1])["archive_url"])
PY
  )"
  CHANNEL_ARCHIVE_SHA256="$(python3 - "$CHANNEL_RELEASE_JSON" <<'PY'
import json,sys; print(json.loads(sys.argv[1])["archive_sha256"])
PY
  )"
  CHANNEL_ARCHIVE_SIGNATURE_URL="$(python3 - "$CHANNEL_RELEASE_JSON" <<'PY'
import json,sys; print(json.loads(sys.argv[1])["archive_signature_url"])
PY
  )"
  CHANNEL_BUNDLE_URL="$(python3 - "$CHANNEL_RELEASE_JSON" <<'PY'
import json,sys; print(json.loads(sys.argv[1])["bundle_url"])
PY
  )"
  CHANNEL_BUNDLE_SHA256="$(python3 - "$CHANNEL_RELEASE_JSON" <<'PY'
import json,sys; print(json.loads(sys.argv[1])["bundle_sha256"])
PY
  )"
  CHANNEL_BUNDLE_SIGNATURE_URL="$(python3 - "$CHANNEL_RELEASE_JSON" <<'PY'
import json,sys; print(json.loads(sys.argv[1])["bundle_signature_url"])
PY
  )"
  CHANNEL_RELEASE_MINIMUM="$(python3 - "$CHANNEL_RELEASE_JSON" <<'PY'
import json,sys; print(json.loads(sys.argv[1])["minimum_current_version"])
PY
  )"
  validate_fetch_url "$CHANNEL_ARCHIVE_URL"
  validate_fetch_url "$CHANNEL_ARCHIVE_SIGNATURE_URL"
  if [[ -n "$CHANNEL_BUNDLE_URL" ]]; then
    validate_fetch_url "$CHANNEL_BUNDLE_URL"
    validate_fetch_url "$CHANNEL_BUNDLE_SIGNATURE_URL"
  fi
  EXPECTED_SHA256="$CHANNEL_ARCHIVE_SHA256"
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


verify_anti_rollback() {
  local json="$1" stage_state="${2:-1}"
  [[ "$stage_state" == "0" || "$stage_state" == "1" ]] || \
    die "SECURITY VIOLATION: Invalid anti-rollback state mode" 4
  local state_root="${ORIGINAL_V1_ROOT:-${V1_ROOT}}"
  local state_file="${state_root}/.channel_updated"

  # ``updated`` is part of the signed channel envelope.  Treating a missing
  # or malformed value as "not applicable" lets an attacker replay an old
  # channel with the field removed, so validation is deliberately fail-closed.
  local new_updated
  new_updated="$(python3 - "$json" <<'PY'
import json
import sys
from datetime import datetime

try:
    value = json.loads(sys.argv[1]).get("updated")
    text = str(value or "").strip()
    parsed = datetime.fromisoformat(text.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        raise ValueError("timezone is required")
except (TypeError, ValueError, json.JSONDecodeError):
    raise SystemExit(1)
print(text)
PY
  )" || die "SECURITY VIOLATION: Channel manifest has an invalid updated timestamp" 4

  if [[ -f "$state_file" ]]; then
    local old_updated old_epoch new_epoch
    old_updated="$(<"$state_file")"
    new_epoch="$(python3 - "$new_updated" <<'PY'
import sys
from datetime import datetime
try:
    parsed = datetime.fromisoformat(sys.argv[1].replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        raise ValueError
except ValueError:
    raise SystemExit(1)
print(parsed.timestamp())
PY
    )" || die "SECURITY VIOLATION: Stored channel timestamp is invalid" 4
    old_epoch="$(python3 - "$old_updated" <<'PY'
import sys
from datetime import datetime
try:
    parsed = datetime.fromisoformat(sys.argv[1].replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        raise ValueError
except ValueError:
    raise SystemExit(1)
print(parsed.timestamp())
PY
    )" || die "SECURITY VIOLATION: Stored channel timestamp is invalid" 4
    if python3 - "$new_epoch" "$old_epoch" <<'PY'
import sys
raise SystemExit(0 if float(sys.argv[1]) < float(sys.argv[2]) else 1)
PY
    then
      die "SECURITY VIOLATION: Anti-Rollback! Downloaded manifest (${new_updated}) is older than currently applied manifest (${old_updated}). Refusing update." 4
    fi
  fi

  if [[ "$stage_state" == "1" ]]; then
    atomic_write_text "${state_file}.new" 0600 <<< "${new_updated}" || \
      die "SECURITY VIOLATION: Channel timestamp state could not be staged" 12
  fi
}

verify_channel_manifest() {
  local url="$1" json="$2" tmpdir
  [[ -n "$json" ]] || die "Empty channel manifest — refusing unsigned update metadata" 4
  validate_fetch_url "$url"
  tmpdir="$(mktemp -d)"
  # curl/command substitution strips the transport newline; channel files are
  # signed as canonical JSON bytes with a trailing LF.
  printf '%s\n' "$json" > "${tmpdir}/channel.json"
  case "$url" in
    file:///*)
      local sig_path
      sig_path="$(_url_path "${url}.minisig")" || { rm -rf "$tmpdir"; die "Offline channel signature URL is invalid" 4; }
      [[ -f "$sig_path" && ! -L "$sig_path" ]] || { rm -rf "$tmpdir"; die "Offline channel signature is missing" 4; }
      cp -- "$sig_path" "${tmpdir}/channel.json.minisig" || { rm -rf "$tmpdir"; die "Offline channel signature copy failed" 4; }
      ;;
    https://*)
      curl "${CURL_OPTS[@]}" -o "${tmpdir}/channel.json.minisig" "${url}.minisig" 2>/dev/null || {
        rm -rf "$tmpdir"
        die "Channel signature not downloadable (${url}.minisig) — refusing update" 4
      }
      ;;
  esac
  verify_minisign "${tmpdir}/channel.json" "${tmpdir}/channel.json.minisig" \
    "$SIGNATURE_PUBKEY" "channel manifest"
  rm -rf "$tmpdir"
}

resolve_channel_target() {
  local json target state_mode=1
  [[ $DRY -eq 1 ]] && state_mode=0
  json="$(fetch_channel_json "$CHANNEL_URL")" || \
    die "Channel unreachable (${CHANNEL_URL}) — refusing to guess a release target" 4
  [[ -n "$json" ]] || die "Empty channel manifest (${CHANNEL_URL}) — refusing to guess a release target" 4
  verify_channel_manifest "$CHANNEL_URL" "$json" >&2
  verify_anti_rollback "$json" "$state_mode"
  load_channel_release_metadata "$json" "$(python3 - "$json" <<'PY'
import json,sys; print(str(json.loads(sys.argv[1]).get("current_version") or "").strip())
PY
  )"
  target="$(printf '%s\n' "$json" | sed -nE 's/.*"current_version"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' | head -n1)"
  [[ -n "$target" ]] || die "Channel manifest has no current_version" 4
  printf '%s' "$target"
}

  if [[ -z "$TARGET" ]]; then
  TARGET="$(resolve_channel_target)"
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

  local channel_json archive_url archive_sig_url expected_sha256 archive_source sig_source
  if [[ -z "${CHANNEL_JSON:-}" ]]; then
    CHANNEL_JSON="$(fetch_channel_json "$CHANNEL_URL")" || \
      die "Channel unreachable (${CHANNEL_URL}) — cannot resolve the release payload for ${target}; refusing to copy the current tree" 4
  fi
  channel_json="${CHANNEL_JSON}"
  verify_channel_manifest "$CHANNEL_URL" "$channel_json"
  # Explicit targets must pass the same monotonic channel gate as channel
  # resolution; otherwise a caller could bypass anti-rollback by naming an
  # older version directly.
  verify_anti_rollback "$channel_json"
  load_channel_release_metadata "$channel_json" "$target"
  archive_url="$CHANNEL_ARCHIVE_URL"
  archive_sig_url="$CHANNEL_ARCHIVE_SIGNATURE_URL"
  expected_sha256="$CHANNEL_ARCHIVE_SHA256"
  archive_source="$archive_url"
  sig_source="$archive_sig_url"
  if [[ -n "${NEOSECRA_DISTRIBUTION_ARCHIVE_URL:-}" ]]; then
    [[ "${NEOSECRA_DISTRIBUTION_ARCHIVE_URL}" == file:///* && "${NEOSECRA_OFFLINE:-0}" == "1" ]] || \
      die "NEOSECRA_DISTRIBUTION_ARCHIVE_URL may only override a signed URL with a bounded offline file:// artifact" 4
    validate_fetch_url "${NEOSECRA_DISTRIBUTION_ARCHIVE_URL}"
    archive_source="${NEOSECRA_DISTRIBUTION_ARCHIVE_URL}"
    sig_source="${NEOSECRA_DISTRIBUTION_ARCHIVE_URL}.minisig"
  fi
  [[ -n "$archive_url" ]] || \
    die "Channel has no archive URL for release ${target} — refusing to fall back to copying the current tree" 4

  # Target dir IS the running tree (same resolved path): nothing to stage,
  # but only after the signed metadata and anti-rollback checks above.
  if [[ "$(readlink -f "$dest" 2>/dev/null || true)" == "$(readlink -f "$V1_ROOT" 2>/dev/null || true)" ]]; then
    return 0
  fi

  # Drop staging leftovers from a previous failed attempt (idempotent re-run).
  rm -rf "${RELEASES_DIR}"/.staging-"${target}".* 2>/dev/null || true

  local dl_dir staging
  dl_dir="$(mktemp -d)"
  staging="${RELEASES_DIR}/.staging-${target}.$$"
  mkdir -p "$staging"
  _PTR_CLEANUP+=("$dl_dir" "$staging")

  log "Downloading release payload for ${target}: ${archive_source}"
  fetch_url_to_file "$archive_source" "${dl_dir}/distribution.tar.gz"
  verify_sha256 "${dl_dir}/distribution.tar.gz" "$expected_sha256" "distribution archive ${target} (signed channel entry)"
  fetch_url_to_file "$sig_source" "${dl_dir}/distribution.tar.gz.minisig"
  verify_minisign "${dl_dir}/distribution.tar.gz" "${dl_dir}/distribution.tar.gz.minisig" \
    "$SIGNATURE_PUBKEY" "distribution archive ${target}"

  # Extract and validate the expected payload layout:
  #   neosecra-distribution-<ver>/deployment/{VERSION,lib/common.sh,
  #   upgrade/upgrade.sh,docker-compose.v1.yml,...}
  mkdir -p "${dl_dir}/extract"
  python3 "${UPGRADE_SCRIPT_DIR}/secure_extract.py" release "${dl_dir}/distribution.tar.gz" "${dl_dir}/extract" "$target" || \
    die "Failed bounded extraction of release payload for ${target}" 4
  local top payload marker
  top="$(find "${dl_dir}/extract" -mindepth 1 -maxdepth 1 -type d -name 'neosecra-distribution-*' -print -quit)"
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

  # The archive is already covered by the signed SHA-256 and minisig.  Never
  # rewrite its metadata after verification; validate it instead so an offline
  # override cannot smuggle a version lie into the target tree.
  [[ "$(tr -d '[:space:]' < "${staging}/VERSION")" == "$target" ]] || \
    die "Signed release VERSION metadata does not match ${target}" 4
  if [[ -d "${staging}/v1" && ! -L "${staging}/v1" && -f "${staging}/v1/VERSION" ]]; then
    [[ "$(tr -d '[:space:]' < "${staging}/v1/VERSION")" == "$target" ]] || \
      die "Signed release v1/VERSION metadata does not match ${target}" 4
  fi
  local manifest_path
  for manifest_path in "${staging}/release-manifest.yaml" "${staging}/v1/release-manifest.yaml"; do
    [[ -f "$manifest_path" ]] || continue
    grep -Eq "^[[:space:]]*version:[[:space:]]*['\"]?${target}['\"]?[[:space:]]*$" "$manifest_path" || \
      die "Signed release manifest version does not match ${target}" 4
  done

  # Atomically swap into place (staging lives in RELEASES_DIR, so mv is a
  # same-filesystem rename). An existing target dir — e.g. one left by the
  # old copy-based implementation — is backed up first.
  if [[ -e "$dest" ]]; then
    backup_path="${BACKUP_ROOT}/preupgrade-release-${target}-$(date -u +%Y%m%dT%H%M%SZ)"
    mkdir -p "$backup_path"
    mv -- "$dest" "${backup_path}/release-${target}" || \
      die "Existing target release could not be moved to a rollback backup" 12
    warn "Existing target release backed up: ${backup_path}/release-${target}"
  fi
  mv -- "$staging" "$dest" || die "Prepared release could not be atomically installed" 12
  rm -rf -- "$dl_dir" || die "Release staging cleanup failed" 12
  _PTR_CLEANUP=()

  # The systemd units address the tree through the stable `current/v1/...`
  # path; make sure the freshly prepared release satisfies that layout.
  ensure_release_v1_link "$dest"

  ok "Target release ${target} prepared from signed channel payload: ${dest}"
}

if [[ $DRY -eq 1 ]]; then
  # Avoid state.sh's legacy self-heal write during a read-only dry-run.
  CURRENT=$(read_installed_version 0 2>/dev/null || true)
else
  CURRENT=$(read_installed_version 2>/dev/null || true)
fi
[[ -n "$CURRENT" && "$CURRENT" != "none" ]] || CURRENT=$(read_version)
if [[ $DRY -eq 0 && $TARGET_FROM_ARG -eq 0 && "$TARGET" != "$(read_version)" && "${NEOSECRA_UPGRADE_BOOTSTRAP:-1}" == "1" ]]; then
  log "Channel target ${TARGET} requires newer installer metadata; refreshing from the signed update channel..."
  CHANNEL_JSON="$(fetch_channel_json "$CHANNEL_URL")" || \
    die "Channel unreachable (${CHANNEL_URL}) — refusing bootstrap of unverified installer metadata" 4
  verify_channel_manifest "$CHANNEL_URL" "$CHANNEL_JSON"
  verify_anti_rollback "$CHANNEL_JSON"
  RESOLVED_ARCHIVE_URL="$(parse_channel_archive_url "$CHANNEL_JSON" "$TARGET")"
  [[ -n "$RESOLVED_ARCHIVE_URL" ]] || \
    die "Channel has no archive URL for release ${TARGET} — refusing bootstrap" 4
  RESOLVED_ARCHIVE_URL="${NEOSECRA_DISTRIBUTION_ARCHIVE_URL:-$RESOLVED_ARCHIVE_URL}"
  BOOTSTRAP_URL="${NEOSECRA_BOOTSTRAP_URL:-https://update.neosecra.com/releases/${TARGET}/bootstrap.sh}"
  BOOTSTRAP_TMP="$(mktemp -d)"
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

# Dry-run is deliberately read-only.  Validate the signed channel, monotonic
# timestamp, release metadata, and host preflight before any lock, backup,
# staging directory, environment rewrite, image pull, or state promotion.
if [[ $DRY -eq 1 ]]; then
  if [[ -z "${CHANNEL_JSON:-}" ]]; then
    CHANNEL_JSON="$(fetch_channel_json "$CHANNEL_URL")" || \
      die "Channel unreachable (${CHANNEL_URL}) — refusing dry-run without signed metadata" 4
  fi
  verify_channel_manifest "$CHANNEL_URL" "$CHANNEL_JSON"
  verify_anti_rollback "$CHANNEL_JSON" 0
  load_channel_release_metadata "$CHANNEL_JSON" "$TARGET"
  bash "${ORIGINAL_V1_ROOT}/install/preflight.sh" || die "Preflight failed" 10
  ok "Dry-run complete"
  exit 0
fi

if [[ "$TARGET" == "$CURRENT" ]]; then
  # A channel check may have staged a newer timestamp while discovering that
  # this installation is already current.  Commit that monotonic marker only
  # after the signed channel was accepted; never leave a misleading .new file.
  if [[ -f "${ORIGINAL_V1_ROOT}/.channel_updated.new" ]]; then
    mv -f "${ORIGINAL_V1_ROOT}/.channel_updated.new" "${ORIGINAL_V1_ROOT}/.channel_updated"
  fi
  ok "Already on latest version: ${TARGET}"
  exit 0
fi

# Lock already held by the calling update-agent (NEOSECRA_AGENT_LOCK_HELD=1);
# taking the same lock path again would die with exit 5 (lock conflict).
RECOVERY_ROOT="${ORIGINAL_V1_ROOT}"
[[ "${NEOSECRA_AGENT_LOCK_HELD:-0}" == "1" ]] || acquire_lock

POST_BACKUP=0
ROLLBACK_ATTEMPTED=0

attempt_signed_rollback() {
  [[ "${ROLLBACK:-0}" -eq 1 ]] || return 0
  ROLLBACK_ATTEMPTED=1
  [[ "${POST_BACKUP:-0}" -eq 1 && -n "${BACKUP_TARGET:-}" ]] || {
    err "Signed rollback requested before a complete pre-upgrade backup existed"
    return 1
  }
  [[ -n "${ROLLBACK_AUTH:-}" && "$ROLLBACK_AUTH" == /* && "$ROLLBACK_AUTH" != *..* && -f "$ROLLBACK_AUTH" ]] || {
    err "Signed rollback was requested but its authorization file is missing or unsafe"
    return 1
  }
  if ! bash "${RECOVERY_ROOT}/upgrade/rollback.sh" --to "$CURRENT" --auth "$ROLLBACK_AUTH" --from-backup "$BACKUP_TARGET"; then
    err "Signed rollback attempt failed; manual intervention is required"
    return 1
  fi
  ok "Signed rollback completed after failed upgrade step"
}

# Always release the state lock, clean release staging, and remove a staged
# channel marker on failure.  When --rollback-on-failure was explicitly
# requested, failures after a durable backup automatically invoke the signed
# rollback path exactly once.  The original exit status is preserved.
on_upgrade_exit() {
  local ec=$?
  trap - EXIT
  if [[ "$ec" -ne 0 ]]; then
    python3 "${RECOVERY_ROOT}/upgrade/recovery.py" journal_step "${RECOVERY_ROOT}" "CRASH" "FAILED_SAFE" "${EXEC_ID:-none}" "$TARGET" || true
    if [[ "${POST_BACKUP:-0}" -eq 1 && "${ROLLBACK:-0}" -eq 1 && "${ROLLBACK_ATTEMPTED:-0}" -eq 0 ]]; then
      attempt_signed_rollback || true
    fi
    _clear_staged_channel_marker
  fi
  release_lock || true
  _prepare_release_cleanup
  exit "$ec"
}

trap on_upgrade_exit EXIT


# --- Recovery & Preflight Checks ---
python3 "${RECOVERY_ROOT}/upgrade/recovery.py" check_double_promotion "${RECOVERY_ROOT}" "$TARGET"
python3 "${RECOVERY_ROOT}/upgrade/recovery.py" check_resume_policy "${RECOVERY_ROOT}" "$TARGET"
python3 "${RECOVERY_ROOT}/upgrade/recovery.py" check_disk_space "${RECOVERY_ROOT}" 1024
python3 "${RECOVERY_ROOT}/upgrade/recovery.py" journal_step "${RECOVERY_ROOT}" "START" "STARTED" "${EXEC_ID:-none}" "$TARGET"

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
POST_BACKUP=1

# The target tree is now both downloaded and cryptographically verified, and
# the current database/config snapshot is durable.  Switch every runtime path
# together only after those gates pass.  Recovery/journal/lock state remains
# anchored to RECOVERY_ROOT, while Compose and release metadata use TARGET.
TARGET_V1_ROOT="$(release_dir "$TARGET")"
[[ -d "$TARGET_V1_ROOT" && ! -L "$TARGET_V1_ROOT" ]] || die "Prepared target release is missing or unsafe" 4
CURRENT_V1_ROOT="$V1_ROOT"
V1_ROOT="$TARGET_V1_ROOT"
COMPOSE_FILE="${V1_ROOT}/docker-compose.v1.yml"
ENV_FILE="${V1_ROOT}/.env.v1"
VERSION_FILE="${V1_ROOT}/VERSION"
MANIFEST_FILE="${V1_ROOT}/release-manifest.yaml"
[[ -f "$COMPOSE_FILE" && -f "$ENV_FILE" && -f "$VERSION_FILE" ]] || die "Prepared target release context is incomplete" 4

# --- Environment validation in the target context ---
apply_release_image_refs "$TARGET"
validate_env_file || die ".env.v1 validation failed" 2

# --- Preflight in the target context ---
bash "${V1_ROOT}/install/preflight.sh" || die "Preflight failed" 10
ok "Preflight passed"

# --- Security Enforcement Integration ---


# --- Security Enforcement Integration ---
upsert_env_value_atomic() {
  local key="$1" val="$2" file="${3:-$ENV_FILE}"
  local tmp dir
  if ! (LC_ALL=C; [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]); then
    die "Invalid environment key" 4
  fi
  [[ "$val" != *$'\n'* && "$val" != *$'\r'* ]] || die "Environment value contains a newline" 4
  dir="$(dirname "$file")"
  mkdir -p "$dir" || die "Environment directory could not be created" 12
  tmp="$(mktemp "${dir}/.${key}.tmp.XXXXXX")" || die "Environment temporary file could not be created" 12
  if ! python3 - "$key" "$val" "$file" "$tmp" <<'PY'
import os
import sys

key, value, source, temporary = sys.argv[1:]
lines = []
found = False
try:
    with open(source, "r", encoding="utf-8") as stream:
        for line in stream:
            if line.startswith(key + "="):
                lines.append(f"{key}={value}\n")
                found = True
            else:
                lines.append(line)
except FileNotFoundError:
    pass
if not found:
    lines.append(f"{key}={value}\n")
with open(temporary, "w", encoding="utf-8") as stream:
    stream.writelines(lines)
    stream.flush()
    os.fsync(stream.fileno())
os.chmod(temporary, 0o600)
os.replace(temporary, source)
fd = os.open(os.path.dirname(source), os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
try:
    os.fsync(fd)
finally:
    os.close(fd)
PY
  then
    rm -f -- "$tmp"
    die "Env update failed" 12
  fi
}

# Pin every Compose image to the exact digest from the already verified,
# signed channel entry before Docker is asked to pull or load anything.  This
# prevents a mutable tag from being used as the pre-verification transport.
pin_channel_image_refs() {
  local output service ref digest env_prefix
  output="$(python3 - "${CHANNEL_JSON:-}" "$TARGET" "${NEOSECRA_PRODUCT:-assessment}" <<'PY'
import json
import re
import sys

raw, target, product = sys.argv[1:]
data = json.loads(raw)
target = target.lstrip("vV")
product = product.strip().lower()
release = next((item for item in data.get("releases", [])
                if str(item.get("version", "")).lstrip("vV") == target), None)
if release is None:
    raise SystemExit(1)
images = release.get("images")
dependencies = release.get("dependencies")
if images is None and dependencies is None and isinstance(release.get("components"), dict):
    component = release["components"].get(product)
    if isinstance(component, dict):
        images = component.get("images")
        dependencies = component.get("dependencies")
images = {} if images is None else images
dependencies = {} if dependencies is None else dependencies
if not isinstance(images, dict) or not isinstance(dependencies, dict):
    raise SystemExit(1)
digest_re = re.compile(r"^sha256:[0-9a-f]{64}$")
name_re = re.compile(r"^[a-z0-9][a-z0-9_-]{0,127}$")
seen = {}
for section, label in ((images, "ENFORCE"), (dependencies, "DEPENDENCY")):
    for name in sorted(section):
        if not name_re.fullmatch(str(name)):
            raise SystemExit(1)
        meta = section[name]
        if not isinstance(meta, dict):
            raise SystemExit(1)
        ref = meta.get("reference")
        digest = str(meta.get("digest") or "").strip().lower()
        if not isinstance(ref, str) or not ref or "@" in ref or ref != ref.strip() or ref.lower() != ref:
            raise SystemExit(1)
        if not digest_re.fullmatch(digest):
            raise SystemExit(1)
        if label == "ENFORCE":
            if digest in seen:
                previous_name, previous_ref = seen[digest]
                if not ({previous_name, name} <= {"backend", "worker", "beat"}) or previous_ref != ref:
                    raise SystemExit(1)
            else:
                seen[digest] = (name, ref)
        print(f"{label}\t{name}\t{ref}\t{digest}")
PY
  )" || die "SECURITY VIOLATION: Signed channel image mapping is invalid" 4
  while IFS=$'\t' read -r _ service ref digest; do
    [[ -n "$service" ]] || continue
    env_prefix="$(printf '%s' "$service" | LC_ALL=C tr 'a-z-' 'A-Z_')"
    upsert_env_value_atomic "${env_prefix}_IMAGE" "${ref}@${digest}"
  done <<< "$output"
}

enforce_image_security() {
  local require_local_digest="${1:-1}"
  local pubkey="${NEOSECRA_COSIGN_PUBKEY:-/etc/neosecra/certs/cosign.pub}"

  if [[ ! -f "${V1_ROOT}/agent/artifact-verifier.sh" ]]; then
    die "SECURITY VIOLATION: artifact-verifier.sh missing" 4
  fi
  source "${V1_ROOT}/agent/artifact-verifier.sh"

  local services_json
  services_json="$(run_compose config --format json 2>/dev/null)" || die "SECURITY VIOLATION: Compose config failure" 4
  [[ -n "$services_json" ]] || die "SECURITY VIOLATION: Service enumeration failure" 4


  local mapping_output
  local expected_channel expected_product
  expected_channel="${NEOSECRA_EXPECTED_CHANNEL:-}"
  if [[ -z "$expected_channel" && -n "${CHANNEL_URL:-}" ]]; then
    expected_channel="$(basename "${CHANNEL_URL%%\?*}")"
    expected_channel="${expected_channel%.json}"
  fi
  if [[ -z "$expected_channel" && -n "${CHANNEL_JSON:-}" ]]; then
    expected_channel="$(python3 - "${CHANNEL_JSON}" <<'PY'
import json, sys
print(str(json.loads(sys.argv[1]).get("channel") or "").strip())
PY
    )"
  fi
  expected_product="${NEOSECRA_PRODUCT:-}"
  if [[ -z "$expected_product" && -z "${CHANNEL_URL:-}" && -n "${CHANNEL_JSON:-}" ]]; then
    expected_product="$(python3 - "${CHANNEL_JSON}" <<'PY'
import json, sys
data = json.loads(sys.argv[1])
print(str(data.get("product_code") or data.get("product") or "").strip())
PY
    )"
  fi
  expected_product="${expected_product:-assessment}"
  case "${expected_product,,}" in
    assessment|neosecra-security-health|security-health) expected_product="assessment" ;;
    soc|neosecra-soc) expected_product="soc" ;;
    pish|neosecra-pish|awareness-portal) expected_product="pish" ;;
    hotspot|neosecra-hotspot) expected_product="hotspot" ;;
    license|neosecra-license) expected_product="license" ;;
    distribution|neosecra-distribution) expected_product="distribution" ;;
    *) die "SECURITY VIOLATION: Invalid runtime product identity" 4 ;;
  esac
  mapping_output="$(echo "$services_json" | CHANNEL_JSON="${CHANNEL_JSON:-}" TARGET="$TARGET" EXPECTED_CHANNEL="$expected_channel" EXPECTED_PRODUCT="$expected_product" ARCHIVE_SHA256="${EXPECTED_SHA256:-}" LEGACY_ALLOWLIST="${RECOVERY_ROOT}/upgrade/legacy_allowlist.json" python3 "${V1_ROOT}/upgrade/verify_mapping.py")" || die "SECURITY VIOLATION: Image mapping failure\nOutput: $mapping_output" 4

  # Platform manifests are for the multi-product promotion path.  A
  # product-specific release is authorized by its signed channel entry and
  # the strict compose image/dependency mapping above.  When a platform
  # manifest is supplied (or explicitly required by the orchestrator), verify
  # it; never silently accept a present-but-invalid manifest.
  local platform_manifest="${NEOSECRA_PLATFORM_MANIFEST:-${V1_ROOT}/platform-manifest.json}"
  if [[ "${NEOSECRA_REQUIRE_PLATFORM_MANIFEST:-0}" == "1" || -e "$platform_manifest" ]]; then
    [[ -f "$platform_manifest" ]] || die "SECURITY VIOLATION: platform-manifest.json is not a regular file" 4
    log "Verifying platform release manifest..."
    if ! V1_ROOT="${V1_ROOT}" EXPECTED_CHANNEL="${expected_channel}" EXPECTED_PLATFORM_VERSION="${TARGET}" \
      python3 "${V1_ROOT}/upgrade/verify_platform_manifest.py" --verify "$platform_manifest"; then
      die "SECURITY VIOLATION: Platform manifest verification failed" 4
    fi
  fi

  # Backup env file for atomic rollback if verification fails mid-way
  cp -a "$ENV_FILE" "${ENV_FILE}.bak"

  local success=1
  while read -r action arg1 arg2 arg3 arg4 arg5; do
     if [[ -z "$action" ]]; then continue; fi
     if [[ "$action" == "AUDIT_LOG" ]]; then
         log "$action $arg1 $arg2 $arg3 $arg4 $arg5"
     elif [[ "$action" == "ENFORCE" ]]; then
         local service="$arg1" image_ref="$arg2" expected_digest="$arg3"
         if [[ ! -f "$pubkey" && ! -d "$pubkey" ]]; then
           success=0; break
         fi
         if ! command -v cosign >/dev/null 2>&1; then
           success=0; break
         fi
         if ! verify_image_signature "$image_ref" "$expected_digest" "$pubkey"; then
             success=0; break
         fi
         if ! verify_image_attestation "$image_ref" "$expected_digest" "$pubkey"; then
             success=0; break
         fi
         
         # local digest check
         local local_digest
         if [[ "$require_local_digest" == "1" ]]; then
           local_digest="$(docker inspect --format '{{range .RepoDigests}}{{.}}{{println}}{{end}}' "$image_ref" 2>/dev/null | grep -oE 'sha256:[0-9a-f]{64}' | head -n1 || true)"
           if [[ -z "$local_digest" || "$local_digest" != "$expected_digest" ]]; then
             echo 'F: DIGEST_MISMATCH ' "$local_digest" "$expected_digest"; success=0; break
           fi
         fi
         
         # Pin
         local env_prefix
         env_prefix="$(echo "$service" | LC_ALL=C tr 'a-z-' 'A-Z_')"
         upsert_env_value_atomic "${env_prefix}_IMAGE" "${image_ref}@${expected_digest}"
         
     elif [[ "$action" == "DEPENDENCY" ]]; then
         local service="$arg1" image_ref="$arg2" expected_digest="$arg3"
         if [[ ! -f "$pubkey" && ! -d "$pubkey" ]]; then
           success=0; break
         fi
         if ! command -v cosign >/dev/null 2>&1; then
           success=0; break
         fi
         if ! verify_image_signature "$image_ref" "$expected_digest" "$pubkey"; then
             success=0; break
         fi
         if ! verify_image_attestation "$image_ref" "$expected_digest" "$pubkey"; then
             success=0; break
         fi
         local local_digest
         if [[ "$require_local_digest" == "1" ]]; then
           local_digest="$(docker inspect --format '{{range .RepoDigests}}{{.}}{{println}}{{end}}' "$image_ref" 2>/dev/null | grep -oE 'sha256:[0-9a-f]{64}' | head -n1 || true)"
           if [[ -z "$local_digest" || "$local_digest" != "$expected_digest" ]]; then
             echo 'F: DIGEST_MISMATCH ' "$local_digest" "$expected_digest"; success=0; break
           fi
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

# Every Compose service must carry the exact digest from the verified channel
# entry before Docker is contacted.  This is deliberately separate from the
# post-load local digest check in enforce_image_security: tags never become a
# transport or promotion source.
pin_channel_image_refs

# --- Pull/load images only after signed target preparation and backup. ---
python3 "${RECOVERY_ROOT}/upgrade/recovery.py" journal_step "${RECOVERY_ROOT}" "PULL_LOAD" "STARTED" "${EXEC_ID:-none}" "$TARGET"

verify_signed_bundle() {
  [[ -n "${CHANNEL_BUNDLE_URL:-}" && -n "${CHANNEL_BUNDLE_SHA256:-}" && -n "${CHANNEL_BUNDLE_SIGNATURE_URL:-}" ]] || \
    die "SECURITY VIOLATION: --bundle was supplied but the signed channel has no bundle metadata" 4
  [[ -f "$BUNDLE" && ! -L "$BUNDLE" ]] || die "Offline bundle is missing or unsafe" 4
  verify_sha256 "$BUNDLE" "$CHANNEL_BUNDLE_SHA256" "docker bundle ${TARGET} (signed channel entry)"
  local signature_file="$BUNDLE.minisig" signature_tmp=""
  if [[ ! -f "$signature_file" || -L "$signature_file" ]]; then
    signature_tmp="$(mktemp)"
    fetch_url_to_file "$CHANNEL_BUNDLE_SIGNATURE_URL" "$signature_tmp"
    signature_file="$signature_tmp"
  fi
  verify_minisign "$BUNDLE" "$signature_file" "$SIGNATURE_PUBKEY" "docker bundle ${TARGET}"
  [[ -z "$signature_tmp" ]] || rm -f -- "$signature_tmp"
}

if [[ -n "$BUNDLE" ]]; then
  verify_signed_bundle
  BUNDLE_TMP_DIR="$(mktemp -d)"
  python3 "${UPGRADE_SCRIPT_DIR}/secure_extract.py" bundle "$BUNDLE" "$BUNDLE_TMP_DIR" || \
    die "SECURITY VIOLATION: Docker bundle extraction failed" 4
  shopt -s nullglob
  bundle_images=("${BUNDLE_TMP_DIR}/images/"*.tar)
  ((${#bundle_images[@]} > 0)) || die "SECURITY VIOLATION: Docker bundle contains no images" 4
  for img in "${bundle_images[@]}"; do
    docker load --input "$img" || die "Docker image load failed: ${img}" 13
  done
  rm -rf -- "$BUNDLE_TMP_DIR" || die "Docker bundle cleanup failed" 12
else
  ghcr_login
  services="$(run_compose config --services 2>/dev/null)" || die "Compose service enumeration failed" 4
  [[ -n "$services" ]] || die "Compose service enumeration returned no services" 4
  for service in $services; do
    pull_service_image "$service"
  done
fi

enforce_image_security 1


# --- Dependencies ---
log "Ensuring PostgreSQL and Redis are running..."
ensure_frontend_tls

run_compose up -d postgres redis
wait_service_healthy postgres 90
wait_service_healthy redis 90
reconcile_postgres_password

# --- Migrate ---
python3 "${RECOVERY_ROOT}/upgrade/recovery.py" journal_step "${RECOVERY_ROOT}" "MIGRATE" "STARTED" "${EXEC_ID:-none}" "$TARGET"
log "Running migrations..."
MIGRATE_OK=0
for _ in 1 2 3; do
  run_compose run --rm backend alembic upgrade head && { MIGRATE_OK=1; break; }
  sleep 3
done
if [[ $MIGRATE_OK -eq 0 ]]; then
  err "Migration failed"
  attempt_signed_rollback
  die "Upgrade failed at migration" 13
fi
ok "Migrations applied"
ensure_assessment_schema_compatibility || die "Assessment schema compatibility repair failed" 11
sync_initial_admin_credentials || die "Initial admin credential synchronization failed" 11

# --- Restart ---
python3 "${RECOVERY_ROOT}/upgrade/recovery.py" journal_step "${RECOVERY_ROOT}" "PROMOTE" "STARTED" "${EXEC_ID:-none}" "$TARGET"
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
if ! bash "${V1_ROOT}/install/postflight.sh" --timeout 120; then
  err "Health verification failed"
  print_service_diagnostics frontend backend worker
  attempt_signed_rollback
  die "Upgrade failed at health verification" 13
fi
ok "Health verification passed"

# --- State ---

# Atomic state commit on health success.  Product releases use the channel
# timestamp; platform releases additionally commit their verified manifest.
if [[ -n "${NEOSECRA_PLATFORM_MANIFEST:-}" || -f "${V1_ROOT}/platform-manifest.json" ]]; then
  log "Committing monotonic platform release state..."
  platform_manifest="${NEOSECRA_PLATFORM_MANIFEST:-${V1_ROOT}/platform-manifest.json}"
  V1_ROOT="${ORIGINAL_V1_ROOT}" python3 "${ORIGINAL_V1_ROOT}/upgrade/verify_platform_manifest.py" --commit "$platform_manifest" || \
    die "SECURITY VIOLATION: Monotonic release state commit failed" 4
fi
if [[ -f "${ORIGINAL_V1_ROOT}/.channel_updated.new" ]]; then
  mv -f "${ORIGINAL_V1_ROOT}/.channel_updated.new" "${ORIGINAL_V1_ROOT}/.channel_updated"
fi
python3 "${RECOVERY_ROOT}/upgrade/recovery.py" journal_step "${RECOVERY_ROOT}" "PROMOTE" "COMPLETED" "${EXEC_ID:-none}" "$TARGET"
write_installed_version "$TARGET"

switch_current "$TARGET"
write_journal "upgrade-${CURRENT}-to-${TARGET}-$(date -u +%Y%m%dT%H%M%SZ).json"

ok "Upgrade complete: ${CURRENT} -> ${TARGET}"
