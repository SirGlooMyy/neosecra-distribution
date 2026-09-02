# DIST-LIVE-CLOUDFLARE-TLS-012 — Cloudflare Origin TLS runbook

This runbook is limited to the Distribution host and the exact authorized
origin `10.33.99.13`. It keeps Cloudflare at **Full (strict)** for:

- `license.neosecra.com`
- `update.neosecra.com`
- `registry.neosecra.com`

Do not substitute another lab address (including `10.34.99.13`) and do not
use `curl -k`, `--insecure`, a TLS bypass, an insecure registry, or a weaker
Cloudflare mode.

## Candidate certificate and secret boundary

The public Cloudflare Origin CA wildcard leaf is
`update-server/certs/neosecra-origin.crt`. It must contain SANs
`*.neosecra.com` and `neosecra.com`, be currently valid, and verify against
the operator-supplied Cloudflare Origin RSA root. The matching private key is
never committed or copied into this repository. On the origin host keep it in
the root-owned directory below:

```text
/opt/neosecra/secrets/caddy/
  neosecra-origin.crt  root:root  0644
  neosecra-origin.key  root:root  0600
```

The key is supplied only through an interactive, approved operator path. Do
not put its contents in shell history, logs, checkpoints, commits, or test
output.

## Pre-flight and rollback checkpoint

Before changing the proxy, use an interactive login (`ssh neosecra@10.33.99.13`)
and record a non-secret checkpoint under `/var/backups/`. Capture the current
Caddyfile, certificate metadata (not key material), `docker inspect` output,
image digest, and persistent volume names. Keep the prior certificate/key pair
available in the protected secret store for rollback. Do not stop the stack or
delete volumes.

## Install, validate, and reload

Install the public certificate from the checked-out Distribution release and
the key from the protected operator input, then set these Compose variables on
the origin host:

```dotenv
CADDYFILE=./Caddyfile
CADDY_CERTS_DIR=/opt/neosecra/secrets/caddy
CADDY_MODE=internal
```

Validate the exact mounted configuration before reload:

```bash
docker compose config --quiet
docker compose run --rm --no-deps caddy \
  caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
```

Reload only Caddy after validation succeeds. Do not run `docker compose down`:

```bash
docker compose exec -T caddy \
  caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile
```

The Caddyfile must use the same certificate/key pair for the three named
vhosts (9445/9446/9447) and the public `:443` listener. Confirm the running
container still mounts `/opt/neosecra/secrets/caddy` read-only and that
`registry_data`, `caddy_data`, and `caddy_config` volumes are unchanged.

## Direct-origin proof

Use the operator-supplied Cloudflare Origin RSA root. The root is not sent by
Caddy; a single leaf in the server chain is expected for Cloudflare Origin
CA. Verify subject, issuer, dates, SANs, chain, and key match without printing
the key:

```bash
ROOT=/secure/operator-input/cloudflare-origin-rsa-root.pem
CERT=/opt/neosecra/secrets/caddy/neosecra-origin.crt
KEY=/opt/neosecra/secrets/caddy/neosecra-origin.key

openssl x509 -in "$CERT" -noout -subject -issuer -dates \
  -fingerprint -sha256 -ext subjectAltName
openssl verify -CAfile "$ROOT" -purpose sslserver \
  -verify_hostname update.neosecra.com "$CERT"
openssl verify -CAfile "$ROOT" -purpose sslserver \
  -verify_hostname license.neosecra.com "$CERT"
openssl verify -CAfile "$ROOT" -purpose sslserver \
  -verify_hostname registry.neosecra.com "$CERT"

cert_hash="$(openssl x509 -in "$CERT" -pubkey -noout |
  openssl pkey -pubin -outform DER | sha256sum | awk '{print $1}')"
key_hash="$(openssl pkey -in "$KEY" -pubout |
  openssl pkey -pubin -outform DER | sha256sum | awk '{print $1}')"
test "$cert_hash" = "$key_hash"
```

Repeat direct SNI against the exact authorized origin and the three TLS
listeners. Any timeout or verification failure is a failed gate:

```bash
for spec in \
  '9445 update.neosecra.com' \
  '9446 license.neosecra.com' \
  '9447 registry.neosecra.com'; do
  set -- $spec
  timeout 10 openssl s_client -connect "10.33.99.13:$1" \
    -servername "$2" -CAfile "$ROOT" -verify_hostname "$2" \
    -verify_return_error -brief </dev/null
done
```

## Two-round public smoke gate

Run both rounds sequentially after reload. Use normal certificate verification
and record the HTTP status and `cf-ray`; `526` is a failure, not an acceptance.

```bash
for round in 1 2; do
  curl --fail --silent --show-error --location \
    https://license.neosecra.com/health >/dev/null
  curl --fail --silent --show-error --location \
    https://license.neosecra.com/api/v1/health >/dev/null
  curl --fail --silent --show-error --location \
    https://update.neosecra.com/channels/assessment-stable.json >/dev/null
  status="$(curl --silent --show-error --location --output /dev/null \
    --write-out '%{http_code}' https://registry.neosecra.com/v2/)"
  case "$status" in 200|401) ;; *)
    printf 'registry /v2/ unexpected status: %s\n' "$status" >&2
    exit 1
  esac
done
```

## Rollback

If certificate validation, reload, direct SNI, or either smoke round fails,
restore the checkpointed Caddyfile and the previous protected certificate/key
pair, validate again, and reload only Caddy. Re-check volume names and keep
both failure and rollback evidence. Never weaken TLS or delete persistent
data.
