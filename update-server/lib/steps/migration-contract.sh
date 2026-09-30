#!/usr/bin/env bash
if [[ -n "$MIGRATION_METADATA" ]]; then
  python3 "${SCRIPT_DIR}/lib/migration.py" "$MIGRATION_METADATA" "$RELEASE_EXTRA"
fi
