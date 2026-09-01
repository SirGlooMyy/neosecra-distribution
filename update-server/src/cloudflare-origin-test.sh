#!/usr/bin/env bash
# Offline contract test for the Cloudflare Origin CA certificate binding.
# No live host, Docker volume, or private-key contents are modified.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CERT="${CLOUDFLARE_ORIGIN_CERT:-${ROOT_DIR}/update-server/certs/neosecra-origin.crt}"
CADDYFILE="${CLOUDFLARE_ORIGIN_CADDYFILE:-${ROOT_DIR}/update-server/Caddyfile}"
CA_ROOT="${CLOUDFLARE_ORIGIN_CA_ROOT:-}"
KEY="${CLOUDFLARE_ORIGIN_KEY:-}"

PASS=0
FAIL=0
SKIP=0
pass() { printf 'PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }
skip() { printf 'SKIP: %s\n' "$1"; SKIP=$((SKIP + 1)); }

[[ -f "$CERT" ]] && pass "Origin certificate exists" || fail "Origin certificate exists"
if openssl x509 -in "$CERT" -noout >/dev/null 2>&1; then
  pass "Origin certificate parses"
else
  fail "Origin certificate parses"
fi

if openssl x509 -in "$CERT" -checkend 0 -noout >/dev/null 2>&1; then
  pass "Origin certificate is currently valid"
else
  fail "Origin certificate is currently valid"
fi

SUBJECT_ALT_NAME="$(openssl x509 -in "$CERT" -noout -ext subjectAltName 2>/dev/null || true)"
for name in update.neosecra.com license.neosecra.com registry.neosecra.com; do
  if grep -Fq "DNS:*.neosecra.com" <<<"$SUBJECT_ALT_NAME"; then
    pass "SAN wildcard covers $name"
  else
    fail "SAN wildcard covers $name"
  fi
done

ISSUER="$(openssl x509 -in "$CERT" -noout -issuer 2>/dev/null || true)"
if grep -Fq "CloudFlare Origin SSL Certificate Authority" <<<"$ISSUER"; then
  pass "Issuer is Cloudflare Origin SSL CA"
else
  fail "Issuer is Cloudflare Origin SSL CA"
fi

BASIC_CONSTRAINTS="$(openssl x509 -in "$CERT" -noout -text 2>/dev/null || true)"
if grep -Fq "CA:FALSE" <<<"$BASIC_CONSTRAINTS"; then
  pass "Certificate is a leaf (CA:FALSE)"
else
  fail "Certificate is a leaf (CA:FALSE)"
fi

TLS_REFS="$(grep -F -c 'tls /etc/caddy/certs/neosecra-origin.crt /etc/caddy/certs/neosecra-origin.key' "$CADDYFILE" || true)"
if [[ "$TLS_REFS" == 5 ]]; then
  pass "All five Caddy TLS listeners use the Origin pair"
else
  fail "All five Caddy TLS listeners use the Origin pair (found $TLS_REFS)"
fi

if [[ -n "$CA_ROOT" ]]; then
  if [[ -f "$CA_ROOT" ]]; then
    for name in update.neosecra.com license.neosecra.com registry.neosecra.com; do
      if openssl verify -CAfile "$CA_ROOT" -purpose sslserver \
          -verify_hostname "$name" "$CERT" >/dev/null 2>&1; then
        pass "Origin certificate verifies for $name against Cloudflare RSA root"
      else
        fail "Origin certificate verifies for $name against Cloudflare RSA root"
      fi
    done
  else
    fail "Supplied Cloudflare CA root exists"
  fi
else
  skip "Cloudflare CA root not supplied (set CLOUDFLARE_ORIGIN_CA_ROOT)"
fi

if [[ -n "$KEY" ]]; then
  if [[ -f "$KEY" ]]; then
    cert_hash="$(openssl x509 -in "$CERT" -pubkey -noout | \
      openssl pkey -pubin -outform DER | sha256sum | awk '{print $1}')"
    key_hash="$(openssl pkey -in "$KEY" -pubout | \
      openssl pkey -pubin -outform DER | sha256sum | awk '{print $1}')"
    if [[ "$cert_hash" == "$key_hash" ]]; then
      pass "Origin certificate matches supplied private key"
    else
      fail "Origin certificate matches supplied private key"
    fi
  else
    fail "Supplied private key exists"
  fi
else
  skip "Private-key match not run (set CLOUDFLARE_ORIGIN_KEY; key contents are never printed)"
fi

printf '\n%d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
(( FAIL == 0 ))
