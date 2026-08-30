#!/usr/bin/env bash
# NeoSecra Artifact & Attestation Verifier
# Canonical fail-closed cryptographic, digest, attestation, and SBOM verification helpers.
#
# Non-negotiable security invariant:
# - Fail-closed on missing inputs, missing binaries, missing keys, invalid digests, signature/attestation failures.
# - No private signing keys in verification scripts.

# 1. SHA-256 Sidecar Verification
verify_sha256_sidecar() {
  local file="${1:-}" sidecar="${2:-${1:-}.sha256}" expected actual
  [[ -n "${file}" && -f "${file}" && -s "${file}" ]] || return 1
  [[ -n "${sidecar}" && -f "${sidecar}" && -s "${sidecar}" ]] || return 1
  expected="$(awk 'NF {print tolower($1); exit}' "${sidecar}" 2>/dev/null || true)"
  [[ "${expected}" =~ ^[0-9a-f]{64}$ ]] || return 1
  actual="$(sha256sum "${file}" 2>/dev/null | awk '{print tolower($1)}')"
  [[ -n "${actual}" && "${actual}" == "${expected}" ]]
}

# 2. Minisign Signature Verification
verify_minisign_file() {
  local file="${1:-}" signature="${2:-${1:-}.minisig}" public_key="${3:-}"
  [[ -n "${file}" && -f "${file}" && -s "${file}" ]] || return 1
  [[ -n "${signature}" && -f "${signature}" && -s "${signature}" ]] || return 1
  [[ -n "${public_key}" && -f "${public_key}" && -s "${public_key}" ]] || return 1
  command -v minisign >/dev/null 2>&1 || return 1
  minisign -V -p "${public_key}" -m "${file}" -x "${signature}" -q >/dev/null 2>&1
}

# 3. Image Signature Verification (cosign verify)
verify_image_signature() {
  local image_ref="${1:-}" expected_digest="${2:-}" pubkey="${3:-}"
  [[ -n "${image_ref}" && -n "${expected_digest}" && -n "${pubkey}" ]] || return 1
  [[ "${expected_digest}" =~ ^sha256:[0-9a-f]{64}$ ]] || return 1
  command -v cosign >/dev/null 2>&1 || return 1

  if [[ -d "${pubkey}" ]]; then
    for key in "${pubkey}"/*.pub; do
      [[ -f "$key" ]] || continue
      if cosign verify --key "$key" "${image_ref}@${expected_digest}" >/dev/null 2>&1; then
        return 0
      fi
    done
    return 1
  else
    [[ -f "${pubkey}" && -s "${pubkey}" ]] || return 1
    cosign verify --key "${pubkey}" "${image_ref}@${expected_digest}" >/dev/null 2>&1
  fi
}

# 4. Image Attestation & Predicate Verification (cosign verify-attestation)
verify_image_attestation() {
  local image_ref="${1:-}" expected_digest="${2:-}" pubkey="${3:-}" predicate_type="${4:-https://cosign.sigstore.dev/attestation/v1}"
  [[ -n "${image_ref}" && -n "${expected_digest}" && -n "${pubkey}" && -n "${predicate_type}" ]] || return 1
  [[ "${expected_digest}" =~ ^sha256:[0-9a-f]{64}$ ]] || return 1
  command -v cosign >/dev/null 2>&1 || return 1

  if [[ -d "${pubkey}" ]]; then
    for key in "${pubkey}"/*.pub; do
      [[ -f "$key" ]] || continue
      if cosign verify-attestation --key "$key" --type "${predicate_type}" "${image_ref}@${expected_digest}" >/dev/null 2>&1; then
        return 0
      fi
    done
    return 1
  else
    [[ -f "${pubkey}" && -s "${pubkey}" ]] || return 1
    cosign verify-attestation --key "${pubkey}" --type "${predicate_type}" "${image_ref}@${expected_digest}" >/dev/null 2>&1
  fi
}

# 5. SBOM Integrity & Structural Validation (SPDX / CycloneDX)
verify_sbom_integrity() {
  local sbom_file="${1:-}" expected_sha256="${2:-}" declared_format="${3:-}" actual
  [[ -n "${sbom_file}" && -f "${sbom_file}" && -s "${sbom_file}" ]] || return 1
  [[ -n "${expected_sha256}" && "${expected_sha256}" =~ ^[0-9a-f]{64}$ ]] || return 1
  actual="$(sha256sum "${sbom_file}" 2>/dev/null | awk '{print tolower($1)}')"
  [[ -n "${actual}" && "${actual}" == "${expected_sha256}" ]] || return 1

  # Structural JSON & format validation
  python3 -c "
import json, sys

with open('${sbom_file}', 'r', encoding='utf-8') as f:
    try:
        data = json.load(f)
    except Exception:
        sys.exit(1)

declared = '${declared_format}'
if declared in ('SPDX', 'SPDX-2.3-JSON'):
    if 'spdxVersion' not in data or not str(data.get('spdxVersion', '')).startswith('SPDX-'):
        sys.exit(1)
elif declared in ('CycloneDX', 'CycloneDX-1.5-JSON'):
    if data.get('bomFormat') != 'CycloneDX' or 'specVersion' not in data:
        sys.exit(1)
else:
    # Auto-detect if declared_format is empty
    if 'spdxVersion' in data and str(data.get('spdxVersion', '')).startswith('SPDX-'):
        pass
    elif data.get('bomFormat') == 'CycloneDX' and 'specVersion' in data:
        pass
    else:
        sys.exit(1)
sys.exit(0)
" 2>/dev/null
}
