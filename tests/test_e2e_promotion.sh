#!/usr/bin/env bash
# Real negative promotion test for the host update-agent.
#
# The test uses the production update-agent and its bounded file:// transport
# in an isolated install root. It deliberately omits the signed channel
# minisig, so the agent must stop before it can download, load, migrate, or
# promote anything. No Docker, cosign, tar, or network stubs are installed.
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
cleanup() { rm -rf -- "${TMP_DIR}"; }
trap cleanup EXIT

INSTALL_ROOT="${TMP_DIR}/install"
OFFLINE_ROOT="${INSTALL_ROOT}/offline"
CHANNEL_DIR="${OFFLINE_ROOT}/channels"
TRIGGER_DIR="${INSTALL_ROOT}/state/upgrade-bridge/trigger"
mkdir -p "${CHANNEL_DIR}" "${TRIGGER_DIR}" "${INSTALL_ROOT}/releases/1.0.0"

# Use the canonical channel payload, but intentionally do not copy its
# .minisig sidecar. This is the exact failure mode that must block promotion.
cp -- "${ROOT_DIR}/channels/assessment-stable.json" "${CHANNEL_DIR}/assessment-stable.json"

printf '1.0.0\n' > "${INSTALL_ROOT}/releases/1.0.0/VERSION"
ln -s "releases/1.0.0" "${INSTALL_ROOT}/current"
mkdir -p "${INSTALL_ROOT}/state"
printf '1.0.0\n' > "${INSTALL_ROOT}/state/installed-version"
printf '%s\n' '{"target_version":"1.3.25"}' > "${TRIGGER_DIR}/upgrade-request.json"

before_link="$(readlink "${INSTALL_ROOT}/current")"
before_version="$(<"${INSTALL_ROOT}/state/installed-version")"

set +e
NEOSECRA_INSTALL_ROOT="${INSTALL_ROOT}" \
NEOSECRA_OFFLINE_ROOT="${OFFLINE_ROOT}" \
NEOSECRA_OFFLINE=1 \
NEOSECRA_PRODUCT=assessment \
NEOSECRA_EDITION_ID=standard \
UPGRADE_RELEASE_CHANNEL=assessment-stable \
UPGRADE_CHANNEL_URL="file://${CHANNEL_DIR}/assessment-stable.json" \
UPGRADE_CHANNEL_PUBLIC_KEY="${ROOT_DIR}/public-keys/update-neosecra-com.pub" \
  bash "${ROOT_DIR}/deployment/v1/agent/update-agent.sh" > "${TMP_DIR}/agent.log" 2>&1
result=$?
set -e

if [[ ${result} -eq 0 ]]; then
  printf 'FAIL: missing channel minisig unexpectedly allowed promotion\n' >&2
  cat "${TMP_DIR}/agent.log" >&2
  exit 1
fi
if [[ "$(readlink "${INSTALL_ROOT}/current")" != "${before_link}" ]]; then
  printf 'FAIL: current symlink changed after channel signature failure\n' >&2
  exit 1
fi
if [[ "$(<"${INSTALL_ROOT}/state/installed-version")" != "${before_version}" ]]; then
  printf 'FAIL: installed-version state changed after channel signature failure\n' >&2
  exit 1
fi
if [[ -e "${INSTALL_ROOT}/releases/1.3.25" || -L "${INSTALL_ROOT}/releases/1.3.25" ]]; then
  printf 'FAIL: target release appeared after channel signature failure\n' >&2
  exit 1
fi
if ! grep -Eq 'Channel signature download failed|Channel minisig FAILED' "${INSTALL_ROOT}/state/logs/update-agent.log"; then
  printf 'FAIL: failure did not identify the missing or invalid channel minisig\n' >&2
  cat "${INSTALL_ROOT}/state/logs/update-agent.log" >&2
  exit 1
fi

printf 'PASS: missing signed-channel minisig failed closed with current and state unchanged\n'
