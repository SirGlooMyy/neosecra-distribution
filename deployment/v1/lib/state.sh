#!/usr/bin/env bash
# State management helpers for the NeoSecra Assessment deployment.
# Source after common.sh
set -Euo pipefail

# Write installed version
write_installed_version() {
  local version="$1"
  mkdir -p "$STATE_DIR"
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]] || die "Invalid installed release version: ${version}" 4
  atomic_write_text "${STATE_DIR}/installed-version" 0600 <<< "${version}" || die "Installed version state commit failed" 12
  atomic_write_text "${STATE_DIR}/active-release" 0600 <<< "${version}" || die "Active release state commit failed" 12
}

# Read installed version
read_installed_version() {
  local self_heal="${1:-1}"
  local stored=""
  if [[ -f "${STATE_DIR}/installed-version" ]]; then
    stored="$(tr -d '[:space:]' < "${STATE_DIR}/installed-version" 2>/dev/null || true)"
  fi
  if [[ -n "$stored" ]]; then
    echo "$stored"
  elif [[ "$self_heal" == "1" && -L "$(current_symlink)" ]]; then
    # Self-heal: installs done before the state file existed, an unreadable
    # (root-owned) state file, or a state wipe — derive from current symlink.
    local healed; healed="$(basename "$(readlink -f "$(current_symlink)")")"
    if [[ -n "$healed" ]]; then
      mkdir -p "$STATE_DIR" || return 1
      atomic_write_text "${STATE_DIR}/installed-version" 0600 <<< "$healed" || return 1
      echo "$healed"
      return 0
    fi
    echo "none"
  else
    echo "none"
  fi
}

# Create release directory
create_release_dir() {
  local version="$1"
  local dir; dir=$(release_dir "$version")
  mkdir -p "$dir"
  echo "$dir"
}

# Switch current symlink
switch_current() {
  local version="$1"
  local target; target=$(release_dir "$version")
  [[ -d "$target" && ! -L "$target" ]] || die "Release directory is missing or unsafe: ${target}" 4

  # Save previous
  if [[ -L "$(current_symlink)" ]]; then
    local old; old=$(readlink "$(current_symlink)")
    local previous_tmp="$(previous_symlink).new.$$"
    ln -s "$old" "$previous_tmp"
    mv -Tf "$previous_tmp" "$(previous_symlink)" || die "Previous release symlink update failed" 12
  fi

  # A same-directory rename makes the promotion atomic for readers.  Never
  # use ln -sfn here: it briefly removes the link and can expose a half-state.
  local current_tmp="$(current_symlink).new.$$"
  ln -s "$target" "$current_tmp"
  mv -Tf "$current_tmp" "$(current_symlink)" || die "Active release symlink switch failed" 12
  # Persist the directory entry update before returning from promotion.
  python3 - "$(dirname "$(current_symlink)")" <<'PY'
import os, sys
fd = os.open(sys.argv[1], os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
try:
    os.fsync(fd)
finally:
    os.close(fd)
PY
  ok "Active release switched to ${version}"
}

# Create install state directories
create_install_dirs() {
  mkdir -p \
    "${RELEASES_DIR}" \
    "${SHARED_DIR}/reports" \
    "${SHARED_DIR}/uploads" \
    "${SHARED_DIR}/certificates" \
    "${STATE_DIR}" \
    "${BACKUP_ROOT}" \
    "${JOURNAL_DIR}" \
    "${LOG_DIR}" \
    "${CREDENTIAL_DIR}"

  # Secure credential directory
  chmod 0700 "$CREDENTIAL_DIR" || die "Credential directory permissions could not be secured" 12
}

# Ensure a release dir satisfies the `current/v1/...` path contract.
# The release layout is flat (the v1 tree content lives at the release root —
# bootstrap rsyncs it into releases/<ver>/), while the systemd units reach the
# tree through the stable path `current/v1/...`. A `v1 -> .` symlink inside the
# release dir bridges the two without duplicating content. Idempotent: an
# existing real `v1/` directory (legacy bootstrap layout) is left untouched.
ensure_release_v1_link() {
  local dest="$1"
  if [[ -L "${dest}/v1" || ! -e "${dest}/v1" ]]; then
    ln -sfn . "${dest}/v1"
  fi
}

# Write upgrade journal
write_journal() {
  local file="$1" previous="${2:-}" status="${3:-completed}"
  mkdir -p "$JOURNAL_DIR"
  atomic_write_text "${JOURNAL_DIR}/${file}" 0600 << JOURNAL
{
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "product": "${PRODUCT}",
  "edition": "${EDITION}",
  "previous_version": "${previous}",
  "status": "${status}"
}
JOURNAL
  ok "Journal: ${JOURNAL_DIR}/${file}"
}

# Read most recent journal entry's previous_version
journal_previous_version() {
  local latest
  latest="$(ls -t "${JOURNAL_DIR}" 2>/dev/null | head -1)" || return 1
  [[ -n "$latest" ]] || return 1
  python3 -c "import json; d=json.load(open('${JOURNAL_DIR}/${latest}')); print(d.get('previous_version',''))" 2>/dev/null || \
    grep -o '"previous_version"[[:space:]]*:[[:space:]]*"\([^"]*\)"' "${JOURNAL_DIR}/${latest}" 2>/dev/null | sed -E 's/.*"([^"]+)".*/\1/' || return 1
}

write_install_state() {
  local version="$1" phase="$2" status="$3"
  mkdir -p "$STATE_DIR"
  atomic_write_text "${STATE_DIR}/install-${version}.state" 0600 << STATE
timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
product=${PRODUCT}
edition=${EDITION}
version=${version}
phase=${phase}
status=${status}
STATE
}

# Check if already installed
is_installed() {
  [[ -f "${STATE_DIR}/installed-version" ]] && [[ -d "$(current_symlink)" ]]
}
