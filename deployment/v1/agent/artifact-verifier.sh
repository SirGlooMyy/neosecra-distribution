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

  # Structural JSON & format validation.  Pass values as argv rather than
  # interpolating them into Python source; SBOM paths and format strings are
  # release metadata and must never become executable code.  A format marker
  # alone is not an SBOM: the trust gate requires the mandatory document,
  # provenance and package/component fields as well.
  python3 - "${sbom_file}" "${declared_format}" <<'PY' 2>/dev/null
import datetime as dt
import json
import re
import sys
import uuid

path, declared = sys.argv[1:3]
try:
    with open(path, "r", encoding="utf-8") as stream:
        data = json.load(stream)
except (OSError, ValueError, TypeError):
    sys.exit(1)

if not isinstance(data, dict):
    sys.exit(1)
if declared in ("SPDX", "SPDX-2.3-JSON"):
    if data.get("spdxVersion") != "SPDX-2.3":
        sys.exit(1)
    if not re.fullmatch(r"SPDXRef-[A-Za-z0-9][A-Za-z0-9.-]*", str(data.get("SPDXID") or "")):
        sys.exit(1)
    if not isinstance(data.get("name"), str) or not data["name"].strip():
        sys.exit(1)
    if data.get("dataLicense") != "CC0-1.0":
        sys.exit(1)
    namespace = data.get("documentNamespace")
    if not isinstance(namespace, str) or not re.fullmatch(r"https?://[^\s]+", namespace):
        sys.exit(1)
    creation = data.get("creationInfo")
    if not isinstance(creation, dict):
        sys.exit(1)
    created = creation.get("created")
    try:
        parsed = dt.datetime.fromisoformat(str(created).replace("Z", "+00:00"))
    except (TypeError, ValueError):
        sys.exit(1)
    if parsed.tzinfo is None or not isinstance(creation.get("creators"), list) or not creation["creators"]:
        sys.exit(1)
    if any(not isinstance(value, str) or not value.strip() for value in creation["creators"]):
        sys.exit(1)
    packages = data.get("packages")
    if not isinstance(packages, list):
        sys.exit(1)
    for package in packages:
        if not isinstance(package, dict):
            sys.exit(1)
        if not re.fullmatch(r"SPDXRef-[A-Za-z0-9][A-Za-z0-9.-]*", str(package.get("SPDXID") or "")):
            sys.exit(1)
        if not isinstance(package.get("name"), str) or not package["name"].strip():
            sys.exit(1)
        checksums = package.get("checksums")
        if not isinstance(checksums, list) or not checksums:
            sys.exit(1)
        for checksum in checksums:
            if not isinstance(checksum, dict) or checksum.get("algorithm") != "SHA256":
                sys.exit(1)
            if not re.fullmatch(r"[0-9a-fA-F]{64}", str(checksum.get("checksumValue") or "")):
                sys.exit(1)
    # SPDX permits an empty package set for a document-only SBOM, but all
    # document/provenance fields above remain mandatory.
elif declared in ("CycloneDX", "CycloneDX-1.5-JSON"):
    if data.get("bomFormat") != "CycloneDX" or data.get("specVersion") != "1.5":
        sys.exit(1)
    serial = data.get("serialNumber")
    version = data.get("version")
    serial_ok = False
    if isinstance(serial, str):
        try:
            uuid.UUID(serial.removeprefix("urn:uuid:"))
            serial_ok = True
        except ValueError:
            serial_ok = False
    version_ok = isinstance(version, int) and not isinstance(version, bool) and version > 0
    if not (serial_ok or version_ok):
        sys.exit(1)
    components = data.get("components")
    if not isinstance(components, list):
        sys.exit(1)
    for component in components:
        if not isinstance(component, dict):
            sys.exit(1)
        if not isinstance(component.get("type"), str) or not component["type"].strip():
            sys.exit(1)
        if not isinstance(component.get("name"), str) or not component["name"].strip():
            sys.exit(1)
        if not isinstance(component.get("version"), str) or not component["version"].strip():
            sys.exit(1)
else:
    if declared:
        sys.exit(1)
    # Auto-detection is intentionally strict and uses the same validators as
    # an explicitly declared format.
    sys.exit(1)
sys.exit(0)
PY
}
