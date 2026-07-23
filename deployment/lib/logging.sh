#!/usr/bin/env bash
# Logging helpers for the NeoSecra Assessment deployment.
# Source this after common.sh
set -Euo pipefail

_info()  { log "$*"; }
_ok()    { ok "$*"; }
_warn()  { warn "$*"; }
_error() { err "$*"; }

# Print a formatted table of key=value pairs
print_table() {
  local format="${1:-%-30s %s\n}"
  shift
  while [[ $# -gt 0 ]]; do
    printf "$format" "$1" "$2"
    shift 2
  done
}
