#!/usr/bin/env bash
# Compatibility entrypoint.  The canonical V1 restore implementation (verify
# sha256 + age decrypt, verify-only by default) lives in ../v1/backup/restore.sh.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CANONICAL="${SCRIPT_DIR}/../v1/backup/restore.sh"
if [[ ! -x "${CANONICAL}" ]]; then
  printf '%s\n' "SECURITY VIOLATION: canonical V1 restore implementation is missing" >&2
  exit 4
fi
exec "${CANONICAL}" "$@"
