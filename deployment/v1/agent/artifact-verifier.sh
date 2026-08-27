#!/usr/bin/env bash
# Small, side-effect-free artifact verification helpers for the host agent.
# Callers decide where temporary files live and how failures are journalled.

verify_sha256_sidecar() {
  local file="${1:-}" sidecar="${2:-${1:-}.sha256}" expected actual
  [[ -s "${file}" && -f "${sidecar}" ]] || return 1
  expected="$(awk 'NF {print tolower($1); exit}' "${sidecar}" 2>/dev/null || true)"
  [[ "${expected}" =~ ^[0-9a-f]{64}$ ]] || return 1
  actual="$(sha256sum "${file}" | awk '{print tolower($1)}')"
  [[ "${actual}" == "${expected}" ]]
}

verify_minisign_file() {
  local file="${1:-}" signature="${2:-${1:-}.minisig}" public_key="${3:-}"
  [[ -s "${file}" && -s "${signature}" && -s "${public_key}" ]] || return 1
  command -v minisign >/dev/null 2>&1 || return 1
  minisign -V -p "${public_key}" -m "${file}" -x "${signature}" -q >/dev/null 2>&1
}
