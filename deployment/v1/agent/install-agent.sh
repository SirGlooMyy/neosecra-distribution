#!/usr/bin/env bash
# neosecra update-agent installer — idempotent
#
# Creates state/upgrade-bridge directories with correct ownership,
# installs systemd unit files, enables + starts the path and timer units.
#
# Run once per host after deployment/v1 is installed at V1_ROOT.
# The shipped docker-compose.v1.yml already contains the required bridge
# volume mounts and AGENT environment block — this script only prepares the
# host side. Re-running is safe: unit files are refreshed in place and
# existing state (trigger/journal contents) is preserved.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
V1_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Capture the agent dir BEFORE sourcing libs: lib/common.sh reassigns
# SCRIPT_DIR to its own location (v1/lib), which made the unit installs below
# silently read from v1/lib and still print OK (no set -e here).
AGENT_DIR="${SCRIPT_DIR}"

# shellcheck source=../lib/common.sh
source "${V1_ROOT}/lib/common.sh"
# The verifier is loaded by update-agent.sh at runtime.  Keep the source-side
# check explicit so a partial distribution payload cannot install a daemon
# that will fail only when the first upgrade trigger arrives.
[[ -f "${AGENT_DIR}/artifact-verifier.sh" ]] || {
  warn "Missing artifact verifier: ${AGENT_DIR}/artifact-verifier.sh"
  exit 1
}
if [[ "${PRODUCT}" == "neosecra-hotspot" ]]; then
  AGENT_SCRIPT="${INSTALL_ROOT}/update-agent/update-agent.sh"
else
  AGENT_SCRIPT="${INSTALL_ROOT}/current/v1/agent/update-agent.sh"
fi
AGENT_RUNTIME_DIR="$(dirname "${AGENT_SCRIPT}")"

# This repo's lib/common.sh enables `set -Ee` when sourced; restore the
# installer's own mode (explicit exit-code handling).
set -uo pipefail

# --- Target paths ---
INSTALL_UNITS_DIR="/etc/systemd/system"
STATE_BRIDGE="${STATE_DIR}/upgrade-bridge"
TRIGGER_DIR="${STATE_BRIDGE}/trigger"
JOURNAL_DIR="${STATE_BRIDGE}/journal"
HEARTBEAT_FILE="${STATE_BRIDGE}/agent-alive"

# --- Color helpers (from common.sh pattern) ---
log()  { printf '%s\n' "$*" >&2; }
ok()   { printf '  OK: %s\n' "$*"; }
warn() { printf '  WARN: %s\n' "$*"; }

usage() { cat <<EOF
neosecra update-agent installer

Usage: sudo ${0##*/} [--backend-uid UID:GID]

Options:
  --backend-uid UID:GID   UID:GID that the backend container runs as
                          (default: 1001:1001 — appuser in the
                          security-health-backend image; change if your
                          compose overrides the user)
  --help                  Show this help

Installs:
  - ${STATE_BRIDGE}/{trigger,journal} directories
  - /etc/systemd/system/neosecra-update-agent.{path,service}
  - /etc/systemd/system/neosecra-update-agent-heartbeat.{timer,service}
EOF
}

# --- Parse args ---
BACKEND_UID="1001:1001"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --backend-uid) shift; BACKEND_UID="$1" ;;
    --help|-h) usage; exit 0 ;;
    *) warn "Unknown option: $1"; usage; exit 2 ;;
  esac
  shift
done

# install(1) accepts NUMERIC ids only portably — a uid like 1001 typically has
# no passwd entry on the host and name lookup fails with "invalid user".
[[ "$BACKEND_UID" =~ ^[0-9]+:[0-9]+$ ]] || { warn "--backend-uid must be numeric UID:GID (got: ${BACKEND_UID})"; exit 2; }

# --- Root check ---
[[ $EUID -eq 0 ]] || { warn "Must be run as root (sudo)"; exit 1; }

# --- Fail loudly if the shipped unit files are missing ---
MISSING_UNITS=0
for unit in neosecra-update-agent.path neosecra-update-agent.service \
            neosecra-update-agent-heartbeat.timer neosecra-update-agent-heartbeat.service; do
  [[ -f "${AGENT_DIR}/${unit}" ]] || { warn "Missing unit file: ${AGENT_DIR}/${unit}"; MISSING_UNITS=1; }
done
[[ $MISSING_UNITS -eq 0 ]] || { warn "Unit files not found in ${AGENT_DIR} — aborting (run from deployment/v1/agent/)"; exit 1; }

# --- Create state dirs ---
# Bridge root + journal are world-readable (0755) because the backend
# container runs as uid 1001 and must READ the journal and the agent-alive
# heartbeat via :ro bind mounts — 0750 root:root locked it out. Only the
# trigger dir is backend-writable (0770 ${BACKEND_UID}).
log "Creating state directories under ${STATE_BRIDGE}..."
install -d -m 0755 -o root -g root "${STATE_BRIDGE}"
install -d -m 0770 -o "${BACKEND_UID%%:*}" -g "${BACKEND_UID##*:}" "${TRIGGER_DIR}"
install -d -m 0755 -o root -g root "${JOURNAL_DIR}"
touch "${HEARTBEAT_FILE}"
chmod 0644 "${HEARTBEAT_FILE}"
ok "State directories ready"

# Existing Assessment installs may predate artifact-verifier.sh.  Refresh the
# adjacent helper when the stable current tree already exists; on a fresh
# install the signed release payload supplies it before current is switched.
if [[ "${PRODUCT}" != "neosecra-hotspot" && -d "${AGENT_RUNTIME_DIR}" ]]; then
  install -m 0644 "${AGENT_DIR}/artifact-verifier.sh" "${AGENT_RUNTIME_DIR}/artifact-verifier.sh"
  ok "Artifact verifier installed: ${AGENT_RUNTIME_DIR}/artifact-verifier.sh"
fi

# Render the checked-in unit templates with the selected product paths. The
# assessment installer keeps its historical defaults; other products can use
# the same script without inheriting `/opt/neosecra/assessment`.
render_unit() {
  local src="$1" dest="$2" line tmp
  tmp="$(mktemp)"
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line//@INSTALL_ROOT@/${INSTALL_ROOT}}"
    line="${line//@ENV_FILE@/${ENV_FILE}}"
    line="${line//@PROJECT@/${PROJECT_NAME}}"
    line="${line//@PRODUCT@/${PRODUCT}}"
    line="${line//@EDITION@/${EDITION}}"
    line="${line//@AGENT_SCRIPT@/${AGENT_SCRIPT}}"
    printf '%s\n' "$line"
  done < "$src" > "$tmp"
  install -m 0644 "$tmp" "$dest"
  rm -f "$tmp"
}

# --- Install systemd units ---
log "Installing systemd units..."
render_unit "${AGENT_DIR}/neosecra-update-agent.path" "${INSTALL_UNITS_DIR}/neosecra-update-agent.path"
render_unit "${AGENT_DIR}/neosecra-update-agent.service" "${INSTALL_UNITS_DIR}/neosecra-update-agent.service"
render_unit "${AGENT_DIR}/neosecra-update-agent-heartbeat.timer" "${INSTALL_UNITS_DIR}/neosecra-update-agent-heartbeat.timer"
render_unit "${AGENT_DIR}/neosecra-update-agent-heartbeat.service" "${INSTALL_UNITS_DIR}/neosecra-update-agent-heartbeat.service"
ok "Unit files installed"

# --- Daemon-reload, enable, start ---
systemctl daemon-reload
systemctl enable --now neosecra-update-agent.path
systemctl enable --now neosecra-update-agent-heartbeat.timer
systemctl is-active --quiet neosecra-update-agent.path && ok "Path unit active" || warn "Path unit NOT active (check journalctl -u neosecra-update-agent.path)"
systemctl is-active --quiet neosecra-update-agent-heartbeat.timer && ok "Heartbeat timer active" || warn "Heartbeat timer NOT active"
ok "Systemd units enabled and started"

# --- Verify compose integration ---
cat <<MOUNTS

======================================================================
 Compose integration (already shipped in docker-compose.v1.yml)
======================================================================

The backend service in deployment/v1/docker-compose.v1.yml already carries
the bridge mounts and AGENT environment block. Verify they resolve to this
host's paths:

  volumes:
    - ${TRIGGER_DIR}:/upgrade-bridge/trigger:rw
    - ${JOURNAL_DIR}:/upgrade-bridge/journal:ro
    - ${STATE_BRIDGE}:/upgrade-bridge:ro

  environment:
    UPGRADE_EXECUTION_PROVIDER=AGENT
    UPGRADE_EXECUTION_ENABLED=true
    UPGRADE_TRIGGER_DIR=/upgrade-bridge/trigger
    UPGRADE_JOURNAL_DIR=/upgrade-bridge/journal
    UPGRADE_AGENT_HEARTBEAT=/upgrade-bridge/agent-alive

The trigger directory MUST be writable by the backend container's UID.
Current backend-uid setting: ${BACKEND_UID}
To change: re-run with --backend-uid <UID:GID>

Journal contract: after each upgrade/rollback the agent copies the produced
upgrade-*.json / rollback-*.json from ${INSTALL_ROOT}/upgrade-journal/ into
${JOURNAL_DIR} so the backend can read them via the bridge mount.

======================================================================
Installation complete.
======================================================================
MOUNTS
