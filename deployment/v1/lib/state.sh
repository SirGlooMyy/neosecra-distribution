#!/usr/bin/env bash
# State management helpers for the NeoSecra Assessment deployment.
# Source after common.sh

# Write installed version
write_installed_version() {
  local version="$1"
  mkdir -p "$STATE_DIR"
  echo "$version" > "${STATE_DIR}/installed-version"
  echo "$version" > "${STATE_DIR}/active-release"
}

# Read installed version
read_installed_version() {
  if [[ -f "${STATE_DIR}/installed-version" ]]; then
    cat "${STATE_DIR}/installed-version"
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

# Write upgrade journal
write_journal() {
  local file="$1"
  mkdir -p "$JOURNAL_DIR"
  cat > "${JOURNAL_DIR}/${file}" << JOURNAL
{
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "product": "${PRODUCT}",
  "edition": "${EDITION}"
}
JOURNAL
  ok "Journal: ${JOURNAL_DIR}/${file}"
}

# Check if already installed
is_installed() {
  [[ -f "${STATE_DIR}/installed-version" ]] && [[ -d "$(current_symlink)" ]]
}
