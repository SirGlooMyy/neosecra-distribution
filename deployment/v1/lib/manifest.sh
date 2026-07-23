#!/usr/bin/env bash
# Release manifest validation helpers.
# Source after common.sh

# Validate product and edition from manifest
check_product_identity() {
  local manifest="${1:-$MANIFEST_FILE}"
  [[ -f "$manifest" ]] || die "Manifest not found: $manifest" 2

  local m_product m_edition
  m_product=$(grep -E '^product:' "$manifest" | awk '{print $2}' || echo "")
  m_edition=$(grep -E '^edition:' "$manifest" | awk '{print $2}' || echo "")

  [[ "$m_product" == "$PRODUCT" ]] || die "Product mismatch: '$m_product' != '$PRODUCT'" 3
  [[ "$m_edition" == "$EDITION" ]] || die "Edition mismatch: '$m_edition' != '$EDITION'" 3
  ok "Product identity verified: ${PRODUCT}/${EDITION}"
}

# Read a field from the release manifest
manifest_field() {
  local field="$1" manifest="${2:-$MANIFEST_FILE}"
  grep -E "^${field}:" "$manifest" 2>/dev/null | awk '{print $2}' | tr -d '"' || echo ""
}

# Validate checksum of a file against a checksum file
verify_checksum() {
  local file="$1" checksum_file="${2:-}"
  if [[ -z "$checksum_file" ]]; then
    sha256sum "$file" | cut -d' ' -f1
    return
  fi
  sha256sum -c "$checksum_file" 2>/dev/null || die "Checksum verification failed for $file" 4
}
