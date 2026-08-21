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

# shellcheck source=../lib/common.sh
source "${V1_ROOT}/lib/common.sh"

# This repo's lib/common.sh enables `set -Ee` when sourced; restore the
# installer's own mode (explicit exit-code handling).
set -uo pipefail

# --- Target paths ---
AGENT_DIR="${SCRIPT_DIR}"
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

# --- Root check ---
[[ $EUID -eq 0 ]] || { warn "Must be run as root (sudo)"; exit 1; }

# --- Create state dirs ---
log "Creating state directories under ${STATE_BRIDGE}..."
install -d -m 0750 -o root -g root "${STATE_BRIDGE}"
install -d -m 0770 -o "${BACKEND_UID%%:*}" -g "${BACKEND_UID##*:}" "${TRIGGER_DIR}"
install -d -m 0750 -o root -g root "${JOURNAL_DIR}"
touch "${HEARTBEAT_FILE}"
chmod 0644 "${HEARTBEAT_FILE}"
ok "State directories ready"

# --- Install systemd units ---
log "Installing systemd units..."
install -m 0644 "${AGENT_DIR}/neosecra-update-agent.path"       "${INSTALL_UNITS_DIR}/"
install -m 0644 "${AGENT_DIR}/neosecra-update-agent.service"    "${INSTALL_UNITS_DIR}/"
install -m 0644 "${AGENT_DIR}/neosecra-update-agent-heartbeat.timer"   "${INSTALL_UNITS_DIR}/"
install -m 0644 "${AGENT_DIR}/neosecra-update-agent-heartbeat.service" "${INSTALL_UNITS_DIR}/"
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
