#!/usr/bin/env bash
# DIST-LIVE-CLOUDFLARE-TLS-012 contract test.
# Static mode is read-only and does not contact a live host. --live performs
# strict direct-SNI and two-round public probes; it never disables TLS checks.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CERT="${CLOUDFLARE_ORIGIN_CERT:-${ROOT_DIR}/update-server/certs/neosecra-origin.crt}"
CADDYFILE="${CLOUDFLARE_ORIGIN_CADDYFILE:-${ROOT_DIR}/update-server/Caddyfile}"
KEY="${CLOUDFLARE_ORIGIN_KEY:-}"
CA_ROOT="${CLOUDFLARE_ORIGIN_CA_ROOT:-}"
ORIGIN_IP="${CLOUDFLARE_ORIGIN_IP:-10.33.99.13}"
LIVE=0

PASS=0
FAIL=0
SKIP=0
pass() { printf 'PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }
skip() { printf 'SKIP: %s\n' "$1"; SKIP=$((SKIP + 1)); }

usage() {
  printf 'usage: %s [--static] [--live]\n' "$0"
}

while (($#)); do
  case "$1" in
    --static) LIVE=0 ;;
    --live) LIVE=1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done

[[ -f "$CERT" ]] && pass "Origin certificate exists" || fail "Origin certificate exists"
if [[ -f "$CERT" ]] && openssl x509 -in "$CERT" -noout >/dev/null 2>&1; then
  pass "Origin certificate parses"
else
  fail "Origin certificate parses"
fi
if [[ -f "$CERT" ]] && openssl x509 -in "$CERT" -checkend 0 -noout >/dev/null 2>&1; then
  pass "Origin certificate is currently valid"
else
  fail "Origin certificate is currently valid"
fi

if [[ -f "$CERT" ]]; then
  subject_alt_name="$(openssl x509 -in "$CERT" -noout -ext subjectAltName 2>/dev/null || true)"
  for name in update.neosecra.com license.neosecra.com registry.neosecra.com; do
    if grep -Fq 'DNS:*.neosecra.com' <<<"$subject_alt_name"; then
      pass "Wildcard SAN covers $name"
    else
      fail "Wildcard SAN covers $name"
    fi
  done
  issuer="$(openssl x509 -in "$CERT" -noout -issuer 2>/dev/null || true)"
  if grep -Fq 'CloudFlare Origin SSL Certificate Authority' <<<"$issuer"; then
    pass "Issuer is Cloudflare Origin SSL CA"
  else
    fail "Issuer is Cloudflare Origin SSL CA"
  fi
  leaf_count="$(grep -c 'BEGIN CERTIFICATE' "$CERT" || true)"
  [[ "$leaf_count" == 1 ]] && pass "Origin chain contains one leaf" || fail "Origin chain contains one leaf"
fi

for path in \
  'update.neosecra.com:9445' \
  'license.neosecra.com:9446' \
  'registry.neosecra.com:9447'; do
  host="${path%:*}"
  port="${path##*:}"
  pair="tls /etc/caddy/certs/neosecra-origin.crt /etc/caddy/certs/neosecra-origin.key"
  if grep -Fq "$pair" "$CADDYFILE" && grep -Fq "$host:$port" "$CADDYFILE"; then
    pass "Caddy maps $host:$port to the Origin pair"
  else
    fail "Caddy maps $host:$port to the Origin pair"
  fi
done
if grep -Fq 'tls /etc/caddy/certs/neosecra-origin.crt /etc/caddy/certs/neosecra-origin.key' "$CADDYFILE"; then
  pass "Caddy has a public listener Origin pair"
else
  fail "Caddy has a public listener Origin pair"
fi

if [[ -n "$CA_ROOT" ]]; then
  if [[ -f "$CA_ROOT" ]]; then
    for name in update.neosecra.com license.neosecra.com registry.neosecra.com; do
      if openssl verify -CAfile "$CA_ROOT" -purpose sslserver \
          -verify_hostname "$name" "$CERT" >/dev/null 2>&1; then
        pass "Origin verifies for $name against Cloudflare root"
      else
        fail "Origin verifies for $name against Cloudflare root"
      fi
    done
  else
    fail "Cloudflare root exists"
  fi
else
  skip "Cloudflare root not supplied (set CLOUDFLARE_ORIGIN_CA_ROOT)"
fi

if [[ -n "$KEY" ]]; then
  if [[ -f "$KEY" ]]; then
    cert_hash="$(openssl x509 -in "$CERT" -pubkey -noout |
      openssl pkey -pubin -outform DER | sha256sum | awk '{print $1}')"
    key_hash="$(openssl pkey -in "$KEY" -pubout |
      openssl pkey -pubin -outform DER | sha256sum | awk '{print $1}')"
    [[ "$cert_hash" == "$key_hash" ]] && pass "Origin certificate matches key" || fail "Origin certificate matches key"
  else
    fail "Supplied Origin key exists"
  fi
else
  skip "Private-key match not run (set CLOUDFLARE_ORIGIN_KEY; key is never printed)"
fi

if [[ "$LIVE" == 1 ]]; then
  [[ -n "$CA_ROOT" && -f "$CA_ROOT" ]] || fail "Live mode requires Cloudflare root"
  if [[ -n "$CA_ROOT" && -f "$CA_ROOT" ]]; then
    for spec in \
      '9445 update.neosecra.com' \
      '9446 license.neosecra.com' \
      '9447 registry.neosecra.com'; do
      set -- $spec
      if timeout 10 openssl s_client -connect "$ORIGIN_IP:$1" \
          -servername "$2" -CAfile "$CA_ROOT" -verify_hostname "$2" \
          -verify_return_error -brief </dev/null >/dev/null 2>&1; then
        pass "Direct SNI $ORIGIN_IP:$1 for $2"
      else
        fail "Direct SNI $ORIGIN_IP:$1 for $2"
      fi
    done
  fi
  for round in 1 2; do
    if curl --fail --silent --show-error --location \
        https://license.neosecra.com/health >/dev/null 2>&1; then
      pass "Public license health round $round"
    else
      fail "Public license health round $round"
    fi
    if curl --fail --silent --show-error --location \
        https://license.neosecra.com/api/v1/health >/dev/null 2>&1; then
      pass "Public license API round $round"
    else
      fail "Public license API round $round"
    fi
    if curl --fail --silent --show-error --location \
        https://update.neosecra.com/channels/assessment-stable.json >/dev/null 2>&1; then
      pass "Public update manifest round $round"
    else
      fail "Public update manifest round $round"
    fi
    status="$(curl --silent --show-error --location --output /dev/null \
      --write-out '%{http_code}' https://registry.neosecra.com/v2/ || true)"
    case "$status" in
      200|401) pass "Public registry /v2/ round $round ($status)" ;;
      *) fail "Public registry /v2/ round $round ($status)" ;;
    esac
  done
else
  skip "Live direct-SNI and public smoke not requested (use --live)"
fi

printf '\n%d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
(( FAIL == 0 ))
