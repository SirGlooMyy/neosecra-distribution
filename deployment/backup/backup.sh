#!/usr/bin/env bash
# Compatibility entrypoint.  The canonical V1 backup implementation is the
# only path allowed to create a pre-upgrade backup.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CANONICAL="${SCRIPT_DIR}/../v1/backup/backup.sh"
if [[ ! -x "${CANONICAL}" ]]; then
  printf '%s\n' "SECURITY VIOLATION: canonical V1 backup implementation is missing" >&2
  exit 4
fi
exec "${CANONICAL}" "$@"
