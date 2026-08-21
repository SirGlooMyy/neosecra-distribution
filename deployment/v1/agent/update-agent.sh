#!/usr/bin/env bash
# neosecra update-agent - host-side upgrade bridge daemon
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
V1_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${V1_ROOT}/lib/common.sh"
source "${V1_ROOT}/lib/manifest.sh"
source "${V1_ROOT}/lib/state.sh"

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

# --- Channel public key ---
# NOTE: the agent runs on the HOST, so UPGRADE_CHANNEL_PUBLIC_KEY from .env.v1
# (a container path, /etc/neosecra/ca/...) usually does not exist here; fall
# back to the copy shipped inside the release tree.
CHANNEL_PUBLIC_KEY="${UPGRADE_CHANNEL_PUBLIC_KEY:-/etc/neosecra/ca/update-neosecra-com.pub}"
[[ -f "${CHANNEL_PUBLIC_KEY}" ]] || CHANNEL_PUBLIC_KEY="${V1_ROOT}/ca/update-neosecra-com.pub"

# --- Strict semver ---
SEMVER_RE='^[0-9]+[.][0-9]+[.][0-9]+$'

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
  mkdir -p "${STATE_DIR}"
  if ! mkdir "${STATE_DIR}/.install.lock" 2>/dev/null; then
    agent_err "Lock already held"
    return 1
  fi
  trap 'rm -rf "${STATE_DIR}/.install.lock"' EXIT
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

# --- SHA256 verify ---
verify_sha256() {
  local file="$1" sha_file="${file}.sha256"
  [[ -f "${sha_file}" ]] || { agent_err "No SHA256 sidecar: ${sha_file}"; return 1; }
  (cd "$(dirname "${file}")" && sha256sum -c "$(basename "${sha_file}")" 2>/dev/null) || {
    agent_err "SHA256 MISMATCH: ${file}"
    return 1
  }
  agent_ok "SHA256 ok: ${file}"
  return 0
}

# --- Minisig verify ---
verify_minisig() {
  local file="$1" sig_file="${file}.minisig"
  [[ -f "${sig_file}" ]] || { agent_warn "No minisig: ${sig_file}"; return 1; }
  if command -v minisign >/dev/null 2>&1 && [[ -f "${CHANNEL_PUBLIC_KEY}" ]]; then
    minisign -V -p "${CHANNEL_PUBLIC_KEY}" -m "${file}" -x "${sig_file}" -q 2>/dev/null || {
      agent_err "Minisig FAILED: ${file}"
      return 1
    }
  else
    agent_warn "minisign tool/key missing; fallback SHA256"
    verify_sha256 "${file}" || return 1
  fi
  agent_ok "Signature ok: ${file}"
  return 0
}

# --- Download bundle + sidecars ---
download_bundle() {
  local url="$1" dest_dir="$2"
  local bundle_file="${dest_dir}/bundle.tar.gz"
  mkdir -p "${dest_dir}"
  agent_info "Downloading bundle: ${url}"
  curl -fsSL -H "User-Agent: NeoSecra-Agent/1.0" -o "${bundle_file}" "${url}" 2>/dev/null || {
    agent_err "Failed to download from ${url}"; return 1
  }
  agent_info "Downloading SHA256 sidecar"
  curl -fsSL -H "User-Agent: NeoSecra-Agent/1.0" -o "${bundle_file}.sha256" "${url}.sha256" 2>/dev/null ||     agent_warn "No SHA256 sidecar at ${url}.sha256"
  agent_info "Downloading minisig sidecar"
  curl -fsSL -H "User-Agent: NeoSecra-Agent/1.0" -o "${bundle_file}.minisig" "${url}.minisig" 2>/dev/null ||     agent_warn "No minisig sidecar at ${url}.minisig"
  if ! verify_minisig "${bundle_file}"; then
    if ! verify_sha256 "${bundle_file}"; then
      agent_err "Bundle verification FAILED (minisig+SHA256)"
      rm -rf "${dest_dir}"; return 1
    fi
  fi
  echo "${bundle_file}"
}

# --- Fetch channel manifest ---
fetch_channel() {
  local target_version="$1"
  local channel_url="${UPGRADE_CHANNEL_URL:-}"
  [[ -z "${channel_url}" ]] && { agent_warn "UPGRADE_CHANNEL_URL not set"; return 0; }
  local tmpdir; tmpdir=$(mktemp -d "/tmp/neosecra-channel-XXXXXXXXXX")
  local channel_file="${tmpdir}/channel.json"
  agent_info "Fetching channel: ${channel_url}"
  curl -fsSL -H "User-Agent: NeoSecra-Agent/1.0" -o "${channel_file}" "${channel_url}" 2>/dev/null || {
    agent_err "Channel fetch failed"; rm -rf "${tmpdir}"; return 1
  }
  curl -fsSL -H "User-Agent: NeoSecra-Agent/1.0" -o "${channel_file}.minisig" "${channel_url}.minisig" 2>/dev/null || true
  if [[ -f "${channel_file}.minisig" ]] && [[ -f "${CHANNEL_PUBLIC_KEY}" ]]; then
    minisign -V -p "${CHANNEL_PUBLIC_KEY}" -m "${channel_file}" -x "${channel_file}.minisig" -q 2>/dev/null || {
      agent_err "Channel minisig FAILED"; rm -rf "${tmpdir}"; return 1
    }
    agent_ok "Channel manifest signed & verified"
  fi
  if ! python3 -c "
import json,sys
with open('${channel_file}') as f:
    ch = json.load(f)
versions = [r.get('version','') for r in ch.get('releases',[])]
if '${target_version}' not in versions:
    sys.exit(1)
" 2>/dev/null; then
    agent_err "Target ${target_version} not in channel manifest"
    rm -rf "${tmpdir}"; return 1
  fi
  agent_ok "Target ${target_version} confirmed in channel"
  rm -rf "${tmpdir}"
}

# --- Process upgrade request ---
process_upgrade_request() {
  local trigger_file="$1"
  local target_version bundle_url channel_url

  target_version=$(python3 -c "
import json,sys
with open('${trigger_file}') as f:
    print(json.load(f).get('target_version',''))
" 2>/dev/null) || { agent_err "Parse trigger failed"; write_agent_status FAILED '' 1; rm -f "${trigger_file}"; return 1; }

  [[ -n "${target_version}" ]] || { agent_err "Missing target_version"; write_agent_status FAILED '' 1; rm -f "${trigger_file}"; return 1; }

  if [[ ! "${target_version}" =~ ${SEMVER_RE} ]]; then
    agent_err "REJECTED version='${target_version}'"
    write_agent_status REJECTED "${target_version}" 1
    rm -f "${trigger_file}"; return 1
  fi

  bundle_url=$(python3 -c "
import json,sys
with open('${trigger_file}') as f:
    print(json.load(f).get('bundle_url',''))
" 2>/dev/null || true)
  channel_url=$(python3 -c "
import json,sys
with open('${trigger_file}') as f:
    print(json.load(f).get('channel_url',''))
" 2>/dev/null || true)

  agent_info "Upgrade request: target=${target_version}"
  export UPGRADE_CHANNEL_URL="${UPGRADE_CHANNEL_URL:-${channel_url}}"
  write_agent_status STARTED "${target_version}" 0

  fetch_channel "${target_version}" || {
    write_agent_status CHANNEL_INVALID "${target_version}" 1
    rm -f "${trigger_file}"; return 1
  }

  agent_acquire_lock || {
    write_agent_status LOCK_FAILED "${target_version}" 5
    rm -f "${trigger_file}"; return 1
  }

  local bundle_path="" dl_dir=""
  if [[ -n "${bundle_url}" ]]; then
    dl_dir=$(mktemp -d "/tmp/neosecra-upgrade-XXXXXXXXXX")
    bundle_path=$(download_bundle "${bundle_url}" "${dl_dir}") || {
      rm -rf "${dl_dir}"
      write_agent_status DOWNLOAD_FAILED "${target_version}" 3
      rm -f "${trigger_file}"; return 1
    }
  fi

  local rc=0
  agent_info "Running upgrade.sh ${target_version}"
  if bash "${V1_ROOT}/upgrade/upgrade.sh" "${target_version}" ${bundle_path:+--bundle "${bundle_path}"} --rollback-on-failure; then
    agent_ok "Upgrade to ${target_version} complete"
    write_agent_status COMPLETED "${target_version}" 0
  else
    rc=$?
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
  local target_version backup_source

  target_version=$(python3 -c "
import json,sys
with open('${trigger_file}') as f:
    d = json.load(f)
    print(d.get('target_version',d.get('rollback_to','')))
" 2>/dev/null) || { agent_err "Parse rollback failed"; write_agent_status FAILED '' 1; rm -f "${trigger_file}"; return 1; }

  [[ -n "${target_version}" ]] || target_version=$(read_installed_version 2>/dev/null || echo '')
  if [[ ! "${target_version}" =~ ${SEMVER_RE} ]]; then
    agent_err "REJECTED rollback='${target_version}'"
    write_agent_status REJECTED "${target_version:-unknown}" 1
    rm -f "${trigger_file}"; return 1
  fi

  backup_source=$(python3 -c "
import json,sys
with open('${trigger_file}') as f:
    print(json.load(f).get('backup_path',''))
" 2>/dev/null || true)

  agent_info "Rollback request: target=${target_version}"
  write_agent_status ROLLBACK_STARTED "${target_version}" 0

  agent_acquire_lock || {
    write_agent_status LOCK_FAILED "${target_version}" 5
    rm -f "${trigger_file}"; return 1
  }

  local rollback_cmd=("${V1_ROOT}/upgrade/rollback.sh" "--to" "${target_version}")
  [[ -n "${backup_source}" ]] && rollback_cmd+=("--from-backup" "${backup_source}")

  local rc=0
  if bash "${rollback_cmd[@]}"; then
    agent_ok "Rollback to ${target_version} complete"
    write_agent_status ROLLBACK_COMPLETED "${target_version}" 0
  else
    rc=$?
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
