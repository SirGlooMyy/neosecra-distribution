#!/usr/bin/env bash
# neosecra update-agent - host-side upgrade bridge daemon
set -uo pipefail

AGENT_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The Hotspot installer keeps the agent's libraries beside this script.  A V1
# release keeps them in the parent tree, so support both layouts explicitly.
if [[ -d "${AGENT_SCRIPT_DIR}/lib" ]]; then
  V1_ROOT="${AGENT_SCRIPT_DIR}"
else
  V1_ROOT="$(cd "${AGENT_SCRIPT_DIR}/.." && pwd)"
fi

source "${V1_ROOT}/lib/common.sh"
source "${V1_ROOT}/lib/manifest.sh"
source "${V1_ROOT}/lib/state.sh"
source "${AGENT_SCRIPT_DIR}/artifact-verifier.sh"

# This repo's lib/*.sh enable `set -Ee` when sourced; the agent relies on
# explicit exit-code handling instead of errexit, so restore its own mode.
set -uo pipefail

# --- Identity ---
STATE_BRIDGE="${STATE_DIR}/upgrade-bridge"
TRIGGER_DIR="${STATE_BRIDGE}/trigger"
JOURNAL_DIR="${STATE_BRIDGE}/journal"
LOG_DIR="${STATE_DIR}/logs"
AGENT_LOG="${LOG_DIR}/update-agent.log"
HEARTBEAT_FILE="${STATE_BRIDGE}/agent-alive"

# Channel and artifact transport is strict TLS by default.  Internal installs
# may provide a pinned CA bundle; an offline install may use only file:// URLs
# rooted below NEOSECRA_OFFLINE_ROOT.  Trigger payloads never select transport
# URLs.
NEOSECRA_TLS_MODE="${NEOSECRA_TLS_MODE:-public}"
AGENT_CURL_OPTS=("-fsSL" "--proto" "=https" "--proto-redir" "=https" "-H" "User-Agent: NeoSecra-Agent/1.0")
if [[ "${NEOSECRA_TLS_MODE}" == "internal" ]]; then
  NEOSECRA_CHANNEL_CA_BUNDLE="${UPGRADE_CHANNEL_CA_BUNDLE:-${NEOSECRA_CA_CERT:-}}"
  [[ -n "${NEOSECRA_CHANNEL_CA_BUNDLE}" && -f "${NEOSECRA_CHANNEL_CA_BUNDLE}" ]] || {
    printf '%s\n' "ERROR: internal TLS mode requires UPGRADE_CHANNEL_CA_BUNDLE/NEOSECRA_CA_CERT" >&2
    exit 4
  }
  AGENT_CURL_OPTS+=("--cacert" "${NEOSECRA_CHANNEL_CA_BUNDLE}")
elif [[ -n "${UPGRADE_CHANNEL_CA_BUNDLE:-}" ]]; then
  [[ -f "${UPGRADE_CHANNEL_CA_BUNDLE}" ]] || {
    printf '%s\n' "ERROR: UPGRADE_CHANNEL_CA_BUNDLE is not a regular file" >&2
    exit 4
  }
  AGENT_CURL_OPTS+=("--cacert" "${UPGRADE_CHANNEL_CA_BUNDLE}")
fi
if [[ -n "${CURL_CA_BUNDLE:-}" ]]; then
  [[ -f "${CURL_CA_BUNDLE}" ]] || {
    printf '%s\n' "ERROR: CURL_CA_BUNDLE is not a regular file" >&2
    exit 4
  }
  AGENT_CURL_OPTS+=("--cacert" "${CURL_CA_BUNDLE}")
fi
OFFLINE_ROOT="${NEOSECRA_OFFLINE_ROOT:-${INSTALL_ROOT}/offline}"

agent_url_path() {
  python3 - "${1:-}" <<'PY'
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

validate_agent_url() {
  local url="${1:-}" path root_real path_real
  [[ -n "${url}" && "${url}" != *$'\n'* && "${url}" != *$'\r'* ]] || return 1
  case "${url}" in
    https://*)
      [[ "${url}" != *'@'* && "${url}" != *'#'* ]] || return 1
      ;;
    file:///*)
      [[ "${NEOSECRA_OFFLINE:-0}" == "1" ]] || return 1
      path="$(agent_url_path "${url}")" || return 1
      root_real="$(readlink -f "${OFFLINE_ROOT}" 2>/dev/null)" || return 1
      path_real="$(readlink -f "${path}" 2>/dev/null)" || return 1
      [[ -n "${path_real}" && ( "${path_real}" == "${root_real}" || "${path_real}" == "${root_real}"/* ) ]] || return 1
      ;;
    *) return 1 ;;
  esac
}

fetch_agent_url() {
  local url="$1" destination="$2" path
  validate_agent_url "${url}" || { agent_err "Rejected channel/artifact URL"; return 1; }
  mkdir -p "$(dirname "${destination}")"
  case "${url}" in
    file:///*)
      path="$(agent_url_path "${url}")" || return 1
      [[ -f "${path}" && ! -L "${path}" ]] || { agent_err "Offline source is missing or unsafe"; return 1; }
      cp -- "${path}" "${destination}" || return 1
      ;;
    https://*) curl "${AGENT_CURL_OPTS[@]}" -o "${destination}" "${url}" 2>/dev/null || return 1 ;;
  esac
  [[ -s "${destination}" ]]
}

# --- Channel public key ---
# NOTE: the agent runs on the HOST, so UPGRADE_CHANNEL_PUBLIC_KEY from .env.v1
# (a container path, /etc/neosecra/ca/...) usually does not exist here; fall
# back to the copy shipped inside the release tree.
CHANNEL_PUBLIC_KEY="${UPGRADE_CHANNEL_PUBLIC_KEY:-/etc/neosecra/ca/update-neosecra-com.pub}"
[[ -f "${CHANNEL_PUBLIC_KEY}" ]] || CHANNEL_PUBLIC_KEY="${V1_ROOT}/ca/update-neosecra-com.pub"

# --- Strict semver ---
SEMVER_RE='^[0-9]+[.][0-9]+[.][0-9]+$'

# Runtime installations historically used display-oriented product names
# (for example ``neosecra-hotspot``).  Channel manifests use the canonical
# product codes.  Resolve the runtime value once so every branch (signature
# checks, updater dispatch and journal metadata) applies the same identity
# policy.
canonical_product() {
  case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
    assessment|neosecra-security-health|security-health) printf 'assessment' ;;
    soc|neosecra-soc) printf 'soc' ;;
    pish|neosecra-pish|awareness-portal) printf 'pish' ;;
    hotspot|neosecra-hotspot) printf 'hotspot' ;;
    *) printf '%s' "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" ;;
  esac
}
RUNTIME_PRODUCT_CODE="$(canonical_product "${NEOSECRA_PRODUCT:-assessment}")"

# These identities are configuration, never trigger input.  A channel URL is
# required even for a locally supplied bundle so that the signed release entry
# binds product, edition, version, archive and bundle metadata together.
CHANNEL_URL="${UPGRADE_CHANNEL_URL:-${NEOSECRA_CHANNEL_URL:-}}"
EXPECTED_CHANNEL="${NEOSECRA_EXPECTED_CHANNEL:-${UPGRADE_RELEASE_CHANNEL:-}}"
if [[ -z "${EXPECTED_CHANNEL}" && -n "${CHANNEL_URL}" ]]; then
  EXPECTED_CHANNEL="$(basename "${CHANNEL_URL%%\?*}")"
  EXPECTED_CHANNEL="${EXPECTED_CHANNEL%.json}"
fi
EXPECTED_PRODUCT="${NEOSECRA_EXPECTED_PRODUCT:-${RUNTIME_PRODUCT_CODE}}"
EXPECTED_EDITION="${NEOSECRA_EXPECTED_EDITION:-${NEOSECRA_EDITION_ID:-standard}}"

# --- Dual logging ---
agent_log() {
  local level="$1" msg="$2"
  logger -t "neosecra-update-agent[$$]" "${level}: ${msg}"
  mkdir -p "$(dirname "${AGENT_LOG}")"
  printf '%s [%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${level}" "${msg}" >> "${AGENT_LOG}"
}
agent_info() { agent_log INFO "$*"; }
agent_ok()   { agent_log OK   "$*"; }
agent_warn() { agent_log WARN "$*"; }
agent_err()  { agent_log ERROR "$*"; }

# --- Lock ---
agent_acquire_lock() {
  acquire_lock || {
    agent_err "Lock already held"
    return 1
  }
  trap 'release_lock' EXIT
  export NEOSECRA_AGENT_LOCK_HELD=1
  return 0
}
agent_release_lock() { rm -rf "${STATE_DIR}/.install.lock" 2>/dev/null || true; }

# --- Status JSON ---
write_agent_status() {
  local state="$1" target="$2" rc="$3"
  mkdir -p "${JOURNAL_DIR}"
  cat > "${JOURNAL_DIR}/agent-status.json" <<- JSONEOF
{
  "agent": "update-agent",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "state": "${state}",
  "target_version": "${target}",
  "exit_code": ${rc}
}
JSONEOF
}

# --- Journal bridge sync ---
# upgrade.sh/rollback.sh write their journals to ${INSTALL_ROOT}/upgrade-journal/
# (host-side). The backend container reads journals through the bridge mount,
# so after each run copy the produced upgrade-*.json / rollback-*.json into
# the bridge journal dir. Idempotent: only newer/missing files are copied.
sync_upgrade_journals() {
  local src_dir="${INSTALL_ROOT}/upgrade-journal"
  [[ -d "${src_dir}" ]] || return 0
  mkdir -p "${JOURNAL_DIR}"
  local f base copied=0
  for f in "${src_dir}"/upgrade-*.json "${src_dir}"/rollback-*.json; do
    [[ -f "${f}" ]] || continue
    base="$(basename "${f}")"
    if [[ ! -f "${JOURNAL_DIR}/${base}" || "${f}" -nt "${JOURNAL_DIR}/${base}" ]]; then
      cp -p "${f}" "${JOURNAL_DIR}/${base}" && copied=$((copied+1))
    fi
  done
  [[ ${copied} -gt 0 ]] && agent_ok "Copied ${copied} journal(s) to bridge: ${JOURNAL_DIR}"
  return 0
}

# Hotspot uses the same signed trigger/journal protocol but has a different
# Compose stack. The updater is installed beside the agent by the dedicated
# Hotspot installer; the fixed path avoids executing trigger-controlled or
# arbitrary environment-provided commands as root.
run_hotspot_apply() {
  local target="$1" archive_path="${2:-}" rollback_auth="${3:-}" command_path="${INSTALL_ROOT}/update-agent/hotspot-updater.sh"
  [[ -f "$command_path" ]] || { agent_err "Hotspot updater missing: ${command_path}"; return 127; }
  [[ -n "$archive_path" ]] || { agent_err "Signed Hotspot archive is missing"; return 4; }
  local args=(--target "$target" --archive "$archive_path"
    --archive-sha256 "${CHANNEL_ARCHIVE_SHA256:-}"
    --archive-signature "${archive_path}.minisig"
    --signature-pubkey "${CHANNEL_PUBLIC_KEY}")
  if [[ -n "$rollback_auth" ]]; then
    [[ "$rollback_auth" == /* && "$rollback_auth" != *..* && -f "$rollback_auth" ]] || {
      agent_err "Hotspot rollback authorization path is unsafe"; return 4;
    }
    args+=(--rollback-auth "$rollback_auth")
  fi
  agent_info "Running Hotspot updater: ${command_path} ${args[*]}"
  bash "$command_path" "${args[@]}"
}

run_hotspot_rollback() {
  local target="$1" backup_source="${2:-}" auth_path="${3:-}" command_path="${INSTALL_ROOT}/update-agent/hotspot-updater.sh"
  [[ -f "$command_path" ]] || { agent_err "Hotspot updater missing: ${command_path}"; return 127; }
  [[ -n "$auth_path" && "$auth_path" == /* && "$auth_path" != *..* && -f "$auth_path" ]] || {
    agent_err "Hotspot rollback authorization file is missing or unsafe"; return 4;
  }
  local args=(--rollback --target "$target" --auth "$auth_path")
  [[ -n "$backup_source" ]] && args+=(--backup "$backup_source")
  agent_info "Running Hotspot rollback: ${command_path} ${args[*]}"
  bash "$command_path" "${args[@]}"
}

# --- SHA256 verify ---
verify_sha256() {
  local file="$1" expected="${2:-}" actual
  [[ -f "${file}" && -s "${file}" ]] || return 1
  if [[ -n "${expected}" ]]; then
    [[ "${expected}" =~ ^[0-9a-fA-F]{64}$ ]] || return 1
    actual="$(sha256sum "${file}" 2>/dev/null | awk '{print tolower($1)}')"
    [[ "${actual}" == "${expected,,}" ]] || {
      agent_err "SHA256 MISMATCH: ${file}"
      return 1
    }
  else
    verify_sha256_sidecar "${file}" "${file}.sha256" || {
      agent_err "SHA256 MISMATCH: ${file}"
      return 1
    }
  fi
  agent_ok "SHA256 ok: ${file}"
  return 0
}

# --- Minisig verify ---
verify_minisig() {
  local file="$1" sig_file="${2:-${1}.minisig}"
  verify_minisign_file "${file}" "${sig_file}" "${CHANNEL_PUBLIC_KEY}" || {
    agent_err "Minisig FAILED: ${file}"
    return 1
  }
  agent_ok "Signature ok: ${file}"
  return 0
}

# --- Download an artifact from verified channel metadata ---
download_signed_artifact() {
  local kind="$1" url="$2" expected_sha="$3" signature_url="$4" dest_dir="$5" name="$6"
  local artifact="${dest_dir}/${name}"
  [[ -n "${url}" && -n "${expected_sha}" && -n "${signature_url}" ]] || {
    agent_err "Signed ${kind} metadata is incomplete"; return 1;
  }
  mkdir -p "${dest_dir}"
  agent_info "Downloading signed ${kind}: ${url}"
  fetch_agent_url "${url}" "${artifact}" || { agent_err "Failed to download ${kind}"; return 1; }
  verify_sha256 "${artifact}" "${expected_sha}" || { agent_err "${kind} SHA256 verification FAILED"; rm -rf "${dest_dir}"; return 1; }
  fetch_agent_url "${signature_url}" "${artifact}.minisig" || { agent_err "${kind} signature download failed"; rm -rf "${dest_dir}"; return 1; }
  verify_minisig "${artifact}" "${artifact}.minisig" || { agent_err "${kind} minisign verification FAILED"; rm -rf "${dest_dir}"; return 1; }
  printf '%s\n' "${artifact}"
}

download_bundle() {
  download_signed_artifact "docker bundle" "$1" "$2" "$3" "$4" "bundle.tar.gz"
}

download_archive() {
  download_signed_artifact "Hotspot archive" "$1" "$2" "$3" "$4" "hotspot-release.tar.gz"
}

# --- Fetch channel manifest ---
fetch_channel() {
  local target_version="$1"
  local channel_url="${CHANNEL_URL:-}"
  # Every update, including an operator-supplied archive, must be authorized
  # by a signed channel manifest.  The URL is configured by the installed unit;
  # trigger JSON is deliberately not consulted.
  [[ -n "${channel_url}" ]] || { agent_err "UPGRADE_CHANNEL_URL is not configured; refusing unsigned channel metadata"; return 1; }
  validate_agent_url "${channel_url}" || { agent_err "Configured channel URL is unsafe"; return 1; }
  local tmpdir; tmpdir=$(mktemp -d "/tmp/neosecra-channel-XXXXXXXXXX")
  local channel_file="${tmpdir}/channel.json"
  agent_info "Fetching channel: ${channel_url}"
  fetch_agent_url "${channel_url}" "${channel_file}" || {
    agent_err "Channel fetch failed"; rm -rf "${tmpdir}"; return 1
  }
  fetch_agent_url "${channel_url}.minisig" "${channel_file}.minisig" || {
    agent_err "Channel signature download failed"; rm -rf "${tmpdir}"; return 1;
  }
  [[ -f "${CHANNEL_PUBLIC_KEY}" ]] || {
    agent_err "Channel public key missing: ${CHANNEL_PUBLIC_KEY}"; rm -rf "${tmpdir}"; return 1;
  }
  verify_minisign_file "${channel_file}" "${channel_file}.minisig" "${CHANNEL_PUBLIC_KEY}" || {
    agent_err "Channel minisig FAILED"; rm -rf "${tmpdir}"; return 1;
  }
  agent_ok "Channel manifest signed & verified"
  VERIFIED_CHANNEL_JSON="$(<"${channel_file}")"
  if ! CHANNEL_METADATA_JSON="$(NEOSECRA_EXPECTED_CHANNEL="${EXPECTED_CHANNEL}" \
      NEOSECRA_EXPECTED_PRODUCT="${EXPECTED_PRODUCT}" \
      NEOSECRA_EXPECTED_EDITION="${EXPECTED_EDITION}" \
      python3 - "${channel_file}" "${target_version}" <<'PY'
import json, os, re, sys

semver = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?$")
sha256 = re.compile(r"^[0-9a-f]{64}$")
safe = re.compile(r"^[a-z0-9][a-z0-9_-]{0,127}$")
with open(sys.argv[1], encoding="utf-8") as stream:
    channel = json.load(stream)
if not isinstance(channel, dict):
    raise SystemExit(1)
name = str(channel.get("channel") or "").strip().lower()
product = str(channel.get("product_code") or channel.get("product") or "").strip().lower()
edition = str(channel.get("edition") or "").strip().lower()
for value in (name, product, edition):
    if not safe.fullmatch(value):
        raise SystemExit(1)
for key, value in (("channel", name), ("product", product), ("edition", edition)):
    expected = str(os.environ.get("NEOSECRA_EXPECTED_" + key.upper()) or "").strip().lower()
    if expected and value != expected:
        raise SystemExit(2)
if str(channel.get("status") or "").strip().lower() not in {"available", "ready"}:
    raise SystemExit(3)
releases = channel.get("releases")
if not isinstance(releases, list) or not releases:
    raise SystemExit(4)
target = sys.argv[2].strip().lstrip("vV")
if not semver.fullmatch(target):
    raise SystemExit(5)
matches = []
seen = set()
for item in releases:
    if not isinstance(item, dict):
        raise SystemExit(6)
    version = str(item.get("version") or "").strip().lstrip("vV")
    if not semver.fullmatch(version) or version in seen:
        raise SystemExit(7)
    seen.add(version)
    if version == target:
        matches.append(item)
if len(matches) != 1:
    raise SystemExit(8)
release = matches[0]
archive = release.get("archive")
if not isinstance(archive, dict):
    raise SystemExit(9)
archive_url = str(archive.get("url") or release.get("archive_url") or "").strip()
archive_sha = str(archive.get("sha256") or release.get("sha256") or "").strip().lower()
archive_sig = str(archive.get("signature_url") or release.get("archive_signature_url") or "").strip()
if not archive_url or not sha256.fullmatch(archive_sha) or not archive_sig:
    raise SystemExit(10)
bundle = release.get("docker_bundle")
if not isinstance(bundle, dict):
    bundle = release.get("bundle") if isinstance(release.get("bundle"), dict) else None
bundle_url = str((bundle or {}).get("url") or release.get("bundle_url") or "").strip()
bundle_sha = str((bundle or {}).get("sha256") or release.get("bundle_sha256") or "").strip().lower()
bundle_sig = str((bundle or {}).get("signature_url") or release.get("bundle_signature_url") or "").strip()
if not bundle_url or bundle_url.rsplit("/", 1)[-1].lower() == "none":
    bundle_url = bundle_sha = bundle_sig = ""
elif not sha256.fullmatch(bundle_sha) or not bundle_sig:
    raise SystemExit(11)
print(json.dumps({
    "archive_url": archive_url,
    "archive_sha256": archive_sha,
    "archive_signature_url": archive_sig,
    "bundle_url": bundle_url,
    "bundle_sha256": bundle_sha,
    "bundle_signature_url": bundle_sig,
}, sort_keys=True, separators=(",", ":")))
PY
  )"; then
    agent_err "Target ${target_version} not in channel manifest or product identity mismatch"
    rm -rf "${tmpdir}"; return 1
  fi
  CHANNEL_ARCHIVE_URL="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["archive_url"])' "${CHANNEL_METADATA_JSON}")"
  CHANNEL_ARCHIVE_SHA256="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["archive_sha256"])' "${CHANNEL_METADATA_JSON}")"
  CHANNEL_ARCHIVE_SIGNATURE_URL="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["archive_signature_url"])' "${CHANNEL_METADATA_JSON}")"
  CHANNEL_BUNDLE_URL="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["bundle_url"])' "${CHANNEL_METADATA_JSON}")"
  CHANNEL_BUNDLE_SHA256="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["bundle_sha256"])' "${CHANNEL_METADATA_JSON}")"
  CHANNEL_BUNDLE_SIGNATURE_URL="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["bundle_signature_url"])' "${CHANNEL_METADATA_JSON}")"
  validate_agent_url "${CHANNEL_ARCHIVE_URL}" || { agent_err "Signed archive URL is unsafe"; rm -rf "${tmpdir}"; return 1; }
  validate_agent_url "${CHANNEL_ARCHIVE_SIGNATURE_URL}" || { agent_err "Signed archive signature URL is unsafe"; rm -rf "${tmpdir}"; return 1; }
  if [[ -n "${CHANNEL_BUNDLE_URL}" ]]; then
    validate_agent_url "${CHANNEL_BUNDLE_URL}" || { agent_err "Signed bundle URL is unsafe"; rm -rf "${tmpdir}"; return 1; }
    validate_agent_url "${CHANNEL_BUNDLE_SIGNATURE_URL}" || { agent_err "Signed bundle signature URL is unsafe"; rm -rf "${tmpdir}"; return 1; }
  fi
  agent_ok "Target ${target_version} confirmed in channel"
  rm -rf "${tmpdir}"
}

# --- Process upgrade request ---
process_upgrade_request() {
  local trigger_file="$1"
  local target_version

  target_version=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8")).get("target_version", ""))' "${trigger_file}" 2>/dev/null) || { agent_err "Parse trigger failed"; write_agent_status FAILED '' 1; rm -f "${trigger_file}"; return 1; }

  [[ -n "${target_version}" ]] || { agent_err "Missing target_version"; write_agent_status FAILED '' 1; rm -f "${trigger_file}"; return 1; }

  if [[ ! "${target_version}" =~ ${SEMVER_RE} ]]; then
    agent_err "REJECTED version='${target_version}'"
    write_agent_status REJECTED "${target_version}" 1
    rm -f "${trigger_file}"; return 1
  fi

  agent_info "Upgrade request: target=${target_version}"
  write_agent_status STARTED "${target_version}" 0

  fetch_channel "${target_version}" || {
    write_agent_status CHANNEL_INVALID "${target_version}" 1
    rm -f "${trigger_file}"; return 1
  }

  agent_acquire_lock || {
    write_agent_status LOCK_FAILED "${target_version}" 5
    rm -f "${trigger_file}"; return 1
  }

  local bundle_path="" archive_path="" dl_dir=""
  # Artifact URLs, hashes, and signatures come only from the verified channel
  # entry. Trigger JSON contains a target version and optional rollback auth;
  # it never selects a download or execution source.
  if [[ -n "${CHANNEL_BUNDLE_URL:-}" ]]; then
    dl_dir=$(mktemp -d "/tmp/neosecra-upgrade-XXXXXXXXXX")
    bundle_path=$(download_bundle "${CHANNEL_BUNDLE_URL}" "${CHANNEL_BUNDLE_SHA256}" \
      "${CHANNEL_BUNDLE_SIGNATURE_URL}" "${dl_dir}") || {
      rm -rf "${dl_dir}"
      write_agent_status DOWNLOAD_FAILED "${target_version}" 3
      rm -f "${trigger_file}"; return 1
    }
  elif [[ "${RUNTIME_PRODUCT_CODE}" == "hotspot" ]]; then
    # Hotspot consumes the signed source archive instead of a Docker bundle.
    dl_dir=$(mktemp -d "/tmp/neosecra-upgrade-XXXXXXXXXX")
    archive_path=$(download_archive "${CHANNEL_ARCHIVE_URL}" "${CHANNEL_ARCHIVE_SHA256}" \
      "${CHANNEL_ARCHIVE_SIGNATURE_URL}" "${dl_dir}") || {
      rm -rf "${dl_dir}"
      write_agent_status DOWNLOAD_FAILED "${target_version}" 3
      rm -f "${trigger_file}"; return 1
    }
  fi

  local rc=0
  # The unit's EnvironmentFile loaded the OLD .env.v1 pins into this process;
  # compose interpolation prefers process env over --env-file, which would
  # silently recreate containers with the OLD images. Drop the pins so the
  # env file updated by upgrade.sh wins.
  unset NEOSECRA_VERSION BACKEND_IMAGE WORKER_IMAGE FRONTEND_IMAGE POSTGRES_IMAGE REDIS_IMAGE OPENVAS_IMAGE
  agent_info "Running upgrade.sh ${target_version}"
  local upgrade_cmd=("${V1_ROOT}/upgrade/upgrade.sh" "${target_version}")
  [[ -n "${bundle_path}" ]] && upgrade_cmd+=(--bundle "${bundle_path}")
  # Automatic rollback is allowed only when the API supplied a signed,
  # scoped authorization document.  Without it the upgrade remains fail-safe
  # and leaves the previous release available for an operator decision.
  local rollback_auth
  rollback_auth=$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1], encoding="utf-8")); print(d.get("rollback_auth_path", d.get("auth_path", "")))' "${trigger_file}" 2>/dev/null || true)
  if [[ -n "${rollback_auth}" && "${rollback_auth}" == /* && "${rollback_auth}" != *..* && -f "${rollback_auth}" ]]; then
    upgrade_cmd+=(--rollback-on-failure --rollback-auth "${rollback_auth}")
  fi
  if [[ "${RUNTIME_PRODUCT_CODE}" == "hotspot" ]]; then
    run_hotspot_apply "${target_version}" "${archive_path}" "${rollback_auth}"
    rc=$?
  elif bash "${upgrade_cmd[@]}"; then
    rc=0
  else
    rc=$?
  fi
  if [[ $rc -eq 0 ]]; then
    agent_ok "Upgrade to ${target_version} complete"
    write_agent_status COMPLETED "${target_version}" 0
  else
    agent_err "Upgrade to ${target_version} failed (exit ${rc})"
    write_agent_status FAILED "${target_version}" "${rc}"
  fi

  sync_upgrade_journals || agent_warn "Journal bridge sync failed (upgrade-*.json)"
  rm -rf "${dl_dir:-}" 2>/dev/null || true
  rm -f "${trigger_file}"
  return "${rc}"
}

# --- Process rollback request ---
process_rollback_request() {
  local trigger_file="$1"
  local target_version backup_source auth_path rollback_nonce rollback_product rollback_channel rollback_edition

  target_version=$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1], encoding="utf-8")); print(d.get("target_version", d.get("rollback_to", "")))' "${trigger_file}" 2>/dev/null) || { agent_err "Parse rollback failed"; write_agent_status FAILED '' 1; rm -f "${trigger_file}"; return 1; }

  [[ -n "${target_version}" ]] || target_version=$(read_installed_version 2>/dev/null || echo '')
  if [[ ! "${target_version}" =~ ${SEMVER_RE} ]]; then
    agent_err "REJECTED rollback='${target_version}'"
    write_agent_status REJECTED "${target_version:-unknown}" 1
    rm -f "${trigger_file}"; return 1
  fi

  backup_source=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8")).get("backup_path", ""))' "${trigger_file}" 2>/dev/null || true)
  auth_path=$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1], encoding="utf-8")); print(d.get("auth_path", d.get("authorization_path", "")))' "${trigger_file}" 2>/dev/null || true)
  rollback_nonce=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8")).get("nonce", ""))' "${trigger_file}" 2>/dev/null || true)
  rollback_product=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8")).get("product", ""))' "${trigger_file}" 2>/dev/null || true)
  rollback_channel=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8")).get("channel", ""))' "${trigger_file}" 2>/dev/null || true)
  rollback_edition=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8")).get("edition", ""))' "${trigger_file}" 2>/dev/null || true)

  # Rollback is a privileged state transition.  The trigger must point to a
  # local authorization document; accepting a missing path would make the
  # update-agent's root process an unauthenticated rollback primitive.
  if [[ -z "${auth_path}" || "${auth_path}" != /* || "${auth_path}" == *..* || ! -f "${auth_path}" ]]; then
    agent_err "Rollback authorization file is missing or unsafe"
    write_agent_status AUTH_FAILED "${target_version}" 4
    rm -f "${trigger_file}"
    return 1
  fi

  agent_info "Rollback request: target=${target_version}"
  write_agent_status ROLLBACK_STARTED "${target_version}" 0

  agent_acquire_lock || {
    write_agent_status LOCK_FAILED "${target_version}" 5
    rm -f "${trigger_file}"; return 1
  }

  # Same stale-pin inheritance hazard as the upgrade path (see above).
  unset NEOSECRA_VERSION BACKEND_IMAGE WORKER_IMAGE FRONTEND_IMAGE POSTGRES_IMAGE REDIS_IMAGE OPENVAS_IMAGE
  export EXPECTED_ROLLBACK_PRODUCT="${rollback_product:-${RUNTIME_PRODUCT_CODE}}"
  export EXPECTED_ROLLBACK_CHANNEL="${rollback_channel:-${UPGRADE_RELEASE_CHANNEL:-}}"
  export EXPECTED_ROLLBACK_EDITION="${rollback_edition:-${NEOSECRA_EDITION_ID:-}}"
  export EXPECTED_ROLLBACK_NONCE="${rollback_nonce:-}"
  local rollback_cmd=("${V1_ROOT}/upgrade/rollback.sh" "--to" "${target_version}" "--auth" "${auth_path}")
  [[ -n "${backup_source}" ]] && rollback_cmd+=("--from-backup" "${backup_source}")

  local rc=0
  if [[ "${RUNTIME_PRODUCT_CODE}" == "hotspot" ]]; then
    run_hotspot_rollback "${target_version}" "${backup_source}" "${auth_path}"
    rc=$?
  elif bash "${rollback_cmd[@]}"; then
    rc=0
  else
    rc=$?
  fi
  if [[ $rc -eq 0 ]]; then
    agent_ok "Rollback to ${target_version} complete"
    write_agent_status ROLLBACK_COMPLETED "${target_version}" 0
  else
    agent_err "Rollback to ${target_version} failed (exit ${rc})"
    write_agent_status ROLLBACK_FAILED "${target_version}" "${rc}"
  fi

  sync_upgrade_journals || agent_warn "Journal bridge sync failed (rollback-*.json)"
  rm -f "${trigger_file}"
  return "${rc}"
}

# --- Main ---
main() {
  local upgrade_file="${TRIGGER_DIR}/upgrade-request.json"
  local rollback_file="${TRIGGER_DIR}/rollback-request.json"
  mkdir -p "${LOG_DIR}" "${JOURNAL_DIR}" "${TRIGGER_DIR}"
  agent_info "Update-agent started (V1_ROOT=${V1_ROOT})"
  [[ -f "${rollback_file}" ]] && { process_rollback_request "${rollback_file}"; exit $?; }
  [[ -f "${upgrade_file}" ]]  && { process_upgrade_request "${upgrade_file}"; exit $?; }
  agent_info "No trigger found; exiting"
  exit 0
}

main "$@"
