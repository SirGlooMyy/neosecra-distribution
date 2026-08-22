#!/usr/bin/env bash
# State management helpers for the NeoSecra Assessment deployment.
# Source after common.sh
set -Euo pipefail

# Write installed version
write_installed_version() {
  local version="$1"
  mkdir -p "$STATE_DIR"
  echo "$version" > "${STATE_DIR}/installed-version"
  echo "$version" > "${STATE_DIR}/active-release"
}

# Read installed version
read_installed_version() {
  local stored=""
  if [[ -f "${STATE_DIR}/installed-version" ]]; then
    stored="$(tr -d '[:space:]' < "${STATE_DIR}/installed-version" 2>/dev/null || true)"
  fi
  if [[ -n "$stored" ]]; then
    echo "$stored"
  elif [[ -L "$(current_symlink)" ]]; then
    # Self-heal: installs done before the state file existed, an unreadable
    # (root-owned) state file, or a state wipe — derive from current symlink.
    local healed; healed="$(basename "$(readlink -f "$(current_symlink)")")"
    if [[ -n "$healed" ]]; then
      mkdir -p "$STATE_DIR" 2>/dev/null && echo "$healed" > "${STATE_DIR}/installed-version" 2>/dev/null || true
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

  # Save previous
  if [[ -L "$(current_symlink)" ]]; then
    local old; old=$(readlink "$(current_symlink)")
    ln -sfn "$old" "$(previous_symlink)"
  fi

  ln -sfn "$target" "$(current_symlink)"
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
  chmod 0700 "$CREDENTIAL_DIR" 2>/dev/null || true
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
  cat > "${JOURNAL_DIR}/${file}" << JOURNAL
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
  cat > "${STATE_DIR}/install-${version}.state" << STATE
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
