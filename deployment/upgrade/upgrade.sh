#!/usr/bin/env bash
# Compatibility entrypoint for installations that still invoke deployment/upgrade.
# The security-sensitive implementation lives in the canonical V1 tree.  Do not
# duplicate the release verifier here: an old copy would create a mutable,
# unsigned promotion path.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CANONICAL="${SCRIPT_DIR}/../v1/upgrade/upgrade.sh"
if [[ ! -x "${CANONICAL}" ]]; then
  printf '%s\n' "SECURITY VIOLATION: canonical V1 upgrade implementation is missing" >&2
  exit 4
fi
exec "${CANONICAL}" "$@"
