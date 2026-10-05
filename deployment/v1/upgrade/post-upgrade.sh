#!/usr/bin/env bash
# neosecra post-upgrade — inspect or retry the idempotent post-upgrade hooks that
# the installed release declares in release-manifest.yaml.
#
#   post-upgrade.sh status            list the declared hooks (done / failed / pending)
#   post-upgrade.sh run               retry hooks that failed during an upgrade
#   post-upgrade.sh run --hook <id>   run one declared hook that has not completed yet
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
V1_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${V1_ROOT}/lib/common.sh"
source "${V1_ROOT}/lib/state.sh"
source "${V1_ROOT}/lib/post_upgrade.sh"

usage() { cat <<'EOF'
neosecra post-upgrade — post-upgrade hooks of the installed release
Usage: post-upgrade.sh status
       post-upgrade.sh run [--hook <id>]
EOF
}

ACTION="${1:-}"
[[ -n "$ACTION" ]] || { usage; exit 2; }
shift || true
HOOK=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --hook) shift; HOOK="${1:-}"; [[ -n "$HOOK" ]] || die "--hook requires an id" 2 ;;
    --help|-h) usage; exit 0 ;;
    *) usage; die "unexpected argument: $1" 2 ;;
  esac
  shift
done

HELPER="${V1_ROOT}/upgrade/post_upgrade.py"
case "$ACTION" in
  status)
    python3 "$HELPER" status "$MANIFEST_FILE" "$STATE_DIR" | tr -d '\r'
    ;;
  run)
    VERSION_NOW="$(read_installed_version 0 2>/dev/null || true)"
    [[ -n "$VERSION_NOW" && "$VERSION_NOW" != "none" ]] || VERSION_NOW="$(read_version)"
    # Without --hook only hooks that failed earlier are pending (the installed
    # version is already past every "since").  The services must be up.
    run_post_upgrade_hooks "$VERSION_NOW" "$VERSION_NOW" "$MANIFEST_FILE" "$HOOK"
    ;;
  --help|-h) usage ;;
  *) usage; exit 2 ;;
esac
