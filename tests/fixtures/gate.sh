#!/usr/bin/env bash
set -euo pipefail
archive="" version=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --archive) archive="$2" ;; --version) version="$2" ;;
    --bundle|--images-lock|--trust-policy|--registry) ;;
    *) exit 2 ;;
  esac
  shift 2
done
[[ -f "$archive" && -n "$version" ]] || exit 2
printf '%s\t' "$(basename "$0")" >> "$GATE_LOG"
sha256sum "$archive" >> "$GATE_LOG"
[[ "${FAIL_GATE:-}" != 1 ]]
