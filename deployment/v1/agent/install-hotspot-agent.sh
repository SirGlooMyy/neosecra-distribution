#!/usr/bin/env bash
# Install the Hotspot flavour of the signed distribution update-agent.
# This deliberately uses separate unit names and paths so it cannot interfere
# with an Assessment installation on the same host.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
V1_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ROOT="/opt/neosecra/hotspot"
AGENT_ROOT=""
BACKUP_ROOT=""
BACKEND_UID="1000:1000"
CHANNEL_URL="https://update.neosecra.com/channels/hotspot-stable.json"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --hotspot-root) shift; ROOT="${1:-}" ;;
    --agent-root) shift; AGENT_ROOT="${1:-}" ;;
    --backup-root) shift; BACKUP_ROOT="${1:-}" ;;
    --backend-uid) shift; BACKEND_UID="${1:-}" ;;
    --channel-url) shift; CHANNEL_URL="${1:-}" ;;
    --help|-h)
      cat <<'EOF'
Usage: sudo install-hotspot-agent.sh [options]
  --hotspot-root PATH   Hotspot installation root (default /opt/neosecra/hotspot)
  --agent-root PATH     Agent runtime path (default <root>/update-agent)
  --backup-root PATH    Persistent backup path (default <root>/backups)
  --backend-uid UID:GID  Host ownership for the API trigger directory (default 1000:1000)
  --channel-url URL     Signed Hotspot channel URL
EOF
      exit 0
      ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

[[ "$ROOT" = /* && "$ROOT" != / && "$ROOT" != */.. ]] || { echo "Unsafe Hotspot root" >&2; exit 2; }
[[ "$BACKEND_UID" =~ ^[0-9]+:[0-9]+$ ]] || { echo "--backend-uid must be UID:GID" >&2; exit 2; }
[[ $EUID -eq 0 ]] || { echo "Run as root (sudo)" >&2; exit 1; }
AGENT_ROOT="${AGENT_ROOT:-${ROOT}/update-agent}"
[[ "$AGENT_ROOT" = /* && "$AGENT_ROOT" != / && "$AGENT_ROOT" != */.. ]] || { echo "Unsafe agent root" >&2; exit 2; }
BACKUP_ROOT="${BACKUP_ROOT:-${ROOT}/backups}"
[[ "$BACKUP_ROOT" = /* && "$BACKUP_ROOT" != / && "$BACKUP_ROOT" != */.. && "$BACKUP_ROOT" != *$'\n'* && "$BACKUP_ROOT" != *$'\r'* && "$BACKUP_ROOT" != *'/../'* ]] || { echo "Unsafe backup root" >&2; exit 2; }

[[ -f "${SCRIPT_DIR}/artifact-verifier.sh" ]] || { echo "Missing artifact verifier: ${SCRIPT_DIR}/artifact-verifier.sh" >&2; exit 1; }
[[ -f "${V1_ROOT}/upgrade/secure_extract.py" ]] || { echo "Missing bounded extractor: ${V1_ROOT}/upgrade/secure_extract.py" >&2; exit 1; }
[[ -f "${V1_ROOT}/upgrade/verify_rollback_auth.py" ]] || { echo "Missing rollback verifier: ${V1_ROOT}/upgrade/verify_rollback_auth.py" >&2; exit 1; }

STATE_BRIDGE="${ROOT}/state/upgrade-bridge"
TRIGGER_DIR="${STATE_BRIDGE}/trigger"
JOURNAL_DIR="${STATE_BRIDGE}/journal"
HEARTBEAT_FILE="${STATE_BRIDGE}/agent-alive"
AGENT_STATE="${ROOT}/state/update-agent"
UNITS_DIR="/etc/systemd/system"
ENV_FILE="/etc/neosecra/hotspot-update-agent.env"
mkdir -p "$AGENT_ROOT/lib" "$AGENT_ROOT/ca" "$AGENT_ROOT/upgrade" "$TRIGGER_DIR" "$JOURNAL_DIR" "${ROOT}/state" "${ROOT}/upgrade-journal" "$AGENT_STATE/home" "$AGENT_STATE/docker-config" "$AGENT_STATE/buildx"
install -d -m 0700 -o root -g root "$AGENT_STATE/home" "$AGENT_STATE/docker-config" "$AGENT_STATE/buildx"
install -m 0755 "${SCRIPT_DIR}/update-agent.sh" "$AGENT_ROOT/update-agent.sh"
install -m 0644 "${SCRIPT_DIR}/artifact-verifier.sh" "$AGENT_ROOT/artifact-verifier.sh"
install -m 0755 "${SCRIPT_DIR}/hotspot-updater.sh" "$AGENT_ROOT/hotspot-updater.sh"
install -m 0755 "${V1_ROOT}/upgrade/secure_extract.py" "$AGENT_ROOT/secure_extract.py"
install -m 0755 "${V1_ROOT}/upgrade/verify_rollback_auth.py" "$AGENT_ROOT/verify_rollback_auth.py"
install -m 0755 "${V1_ROOT}/upgrade/recovery.py" "$AGENT_ROOT/upgrade/recovery.py"
for lib in common.sh manifest.sh state.sh; do install -m 0644 "${V1_ROOT}/lib/${lib}" "$AGENT_ROOT/lib/${lib}"; done
for pubkey in "${V1_ROOT}/ca/"*.pub; do
  [[ -f "${pubkey}" && ! -L "${pubkey}" ]] || continue
  install -m 0644 "${pubkey}" "$AGENT_ROOT/ca/$(basename "${pubkey}")"
done
[[ -s "$AGENT_ROOT/ca/update-neosecra-com.pub" ]] || {
  echo "Trusted update public key is missing from the distribution payload" >&2
  exit 1
}
install -d -m 0755 -o root -g root "$STATE_BRIDGE" "$JOURNAL_DIR"
install -d -m 0770 -o "${BACKEND_UID%%:*}" -g "${BACKEND_UID##*:}" "$TRIGGER_DIR"

# A prior defective install may have created this heartbeat path as an empty
# directory. `touch` reports success for directories, so repair only that
# harmless legacy shape and fail closed for anything that could hide a file.
if [[ -L "$HEARTBEAT_FILE" ]]; then
  echo "Unsafe update-agent heartbeat symlink: $HEARTBEAT_FILE" >&2
  exit 1
fi
if [[ -d "$HEARTBEAT_FILE" ]]; then
  rmdir -- "$HEARTBEAT_FILE" || {
    echo "Update-agent heartbeat directory is not empty: $HEARTBEAT_FILE" >&2
    exit 1
  }
elif [[ -e "$HEARTBEAT_FILE" && ! -f "$HEARTBEAT_FILE" ]]; then
  echo "Unsafe update-agent heartbeat path type: $HEARTBEAT_FILE" >&2
  exit 1
fi
touch -- "$HEARTBEAT_FILE"
chown root:root "$HEARTBEAT_FILE"
chmod 0644 "$HEARTBEAT_FILE"
[[ -f "$HEARTBEAT_FILE" && ! -L "$HEARTBEAT_FILE" ]] || {
  echo "Update-agent heartbeat must be a regular file: $HEARTBEAT_FILE" >&2
  exit 1
}

install -d -m 0755 /etc/neosecra
cat > "$ENV_FILE" <<EOF
NEOSECRA_INSTALL_ROOT=${ROOT}
NEOSECRA_PRODUCT=neosecra-hotspot
# Editions are license/catalog values, not product names.  Keep the shipped
# installer aligned with the canonical channel schema.
NEOSECRA_EDITION_ID=standard
NEOSECRA_PROJECT=neosecra-hotspot
NEOSECRA_COMPOSE_PROJECT=neosecra-hotspot
NEOSECRA_BACKUP_ROOT=${BACKUP_ROOT}
# Routine Hotspot updates never create a full database/log/volume copy. The
# legacy switch is retained only as an explicit fail-closed compatibility key.
NEOSECRA_UPDATE_DB_BACKUP=off
UPGRADE_CHANNEL_URL=${CHANNEL_URL}
UPGRADE_RELEASE_CHANNEL=hotspot-stable
UPGRADE_CHANNEL_PUBLIC_KEY=${AGENT_ROOT}/ca
NEOSECRA_SECURE_EXTRACT=${AGENT_ROOT}/secure_extract.py
NEOSECRA_ROLLBACK_VERIFIER=${AGENT_ROOT}/verify_rollback_auth.py
EOF
chmod 0644 "$ENV_FILE"

cat > "${UNITS_DIR}/neosecra-hotspot-update-agent.service" <<EOF
[Unit]
Description=NeoSecra Hotspot signed update agent
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
EnvironmentFile=${ENV_FILE}
Environment=HOME=${AGENT_STATE}/home
Environment=XDG_CONFIG_HOME=${AGENT_STATE}/docker-config
Environment=DOCKER_CONFIG=${AGENT_STATE}/docker-config
Environment=BUILDX_CONFIG=${AGENT_STATE}/buildx
ExecStart=${AGENT_ROOT}/update-agent.sh
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
NoNewPrivileges=false
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX

[Install]
WantedBy=multi-user.target
EOF

cat > "${UNITS_DIR}/neosecra-hotspot-update-agent.path" <<EOF
[Unit]
Description=NeoSecra Hotspot update trigger watcher

[Path]
PathChanged=${TRIGGER_DIR}/upgrade-request.json
PathChanged=${TRIGGER_DIR}/rollback-request.json
Unit=neosecra-hotspot-update-agent.service

[Install]
WantedBy=multi-user.target
EOF

cat > "${UNITS_DIR}/neosecra-hotspot-update-agent-heartbeat.service" <<EOF
[Unit]
Description=NeoSecra Hotspot update-agent heartbeat

[Service]
Type=oneshot
ExecStartPre=/usr/bin/test -f ${HEARTBEAT_FILE}
ExecStartPre=/usr/bin/test ! -L ${HEARTBEAT_FILE}
ExecStart=/usr/bin/touch -- ${HEARTBEAT_FILE}
EOF

cat > "${UNITS_DIR}/neosecra-hotspot-update-agent-heartbeat.timer" <<'EOF'
[Unit]
Description=NeoSecra Hotspot update-agent heartbeat timer

[Timer]
OnBootSec=60
OnUnitActiveSec=60
AccuracySec=5

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now neosecra-hotspot-update-agent.path
systemctl enable --now neosecra-hotspot-update-agent-heartbeat.timer
systemctl is-active --quiet neosecra-hotspot-update-agent.path
systemctl is-active --quiet neosecra-hotspot-update-agent-heartbeat.timer
echo "Hotspot update-agent installed"
echo "  root: ${ROOT}"
echo "  bridge: ${STATE_BRIDGE}"
echo "  channel: ${CHANNEL_URL}"
