#!/usr/bin/env bash
# Compatibility entrypoint for installations that still invoke deployment/upgrade.
# Rollback authorization and database safety checks are owned by the canonical
# V1 implementation; this wrapper intentionally has no bypass or fallback path.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CANONICAL="${SCRIPT_DIR}/../v1/upgrade/rollback.sh"
if [[ ! -x "${CANONICAL}" ]]; then
  printf '%s\n' "SECURITY VIOLATION: canonical V1 rollback implementation is missing" >&2
  exit 4
fi
exec "${CANONICAL}" "$@"
