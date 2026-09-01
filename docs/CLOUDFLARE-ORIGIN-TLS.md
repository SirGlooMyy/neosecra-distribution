# Cloudflare Origin TLS (DIST-CLOUDFLARE-ORIGIN-CERT-010)

This runbook keeps Cloudflare SSL mode at **Full (strict)** for:

- `update.neosecra.com`
- `license.neosecra.com`
- `registry.neosecra.com`

The origin certificate is the Cloudflare Origin CA leaf in
`update-server/certs/neosecra-origin.crt`. It has SANs `*.neosecra.com` and
`neosecra.com`, is issued by `CloudFlare Origin SSL Certificate Authority`,
and is valid from 2026-08-29 through 2041-08-25. The certificate is public
material and may be committed. The matching private key is never committed.

## Secret layout

Keep the private key in a root-owned directory on the origin host. The
directory must contain only the certificate and its matching key:

```text
/opt/neosecra/secrets/caddy/
  neosecra-origin.crt  root:root  0644
  neosecra-origin.key  root:root  0600
```

Install the certificate from the checked-out release tree and copy the key
from the approved secret-handling path. Do not print or copy the key into the
repository:

```bash
sudo install -d -o root -g root -m 0700 /opt/neosecra/secrets/caddy
sudo install -o root -g root -m 0644 \
  update-server/certs/neosecra-origin.crt \
  /opt/neosecra/secrets/caddy/neosecra-origin.crt
sudo install -o root -g root -m 0600 \
  /secure/operator-input/neosecra-origin.key \
  /opt/neosecra/secrets/caddy/neosecra-origin.key
```

Set the Compose environment on the origin host:

```dotenv
CADDYFILE=./Caddyfile
CADDY_CERTS_DIR=/opt/neosecra/secrets/caddy
CADDY_MODE=internal
```

`CADDY_MODE` is a mode label; the explicit `tls` directives in `Caddyfile`
select the certificate. `Caddyfile.public` remains the separate Let's Encrypt
configuration.

## Offline certificate checks

Use the Cloudflare RSA Origin CA root supplied by the operator. The leaf is
directly signed by that root, so a one-certificate server chain is expected;
the root itself is not sent by Caddy. These checks never expose key material:

```bash
CERT=update-server/certs/neosecra-origin.crt
KEY=/opt/neosecra/secrets/caddy/neosecra-origin.key
ROOT=/secure/operator-input/cloudflare-origin-rsa-root.pem

openssl x509 -in "$CERT" -noout -subject -issuer -dates \
  -fingerprint -sha256 -ext subjectAltName
openssl verify -CAfile "$ROOT" -purpose sslserver \
  -verify_hostname update.neosecra.com "$CERT"

openssl x509 -in "$CERT" -pubkey -noout | \
  openssl pkey -pubin -outform DER | sha256sum
openssl pkey -in "$KEY" -pubout | \
  openssl pkey -pubin -outform DER | sha256sum
```

The two public-key hashes must be identical. Repeat hostname verification for
`license.neosecra.com` and `registry.neosecra.com`.

## Validate and reload

Take a non-secret rollback checkpoint before changing the running proxy. It
must include the current Caddyfile, public certificate metadata, container
inspect output, image digest, and persistent volume names. Do not include
private keys or secret environment values.

After the secret directory is populated, validate the exact Compose mounts and
the Caddy configuration:

```bash
docker compose config --quiet
docker compose run --rm --no-deps caddy \
  caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
```

If validation succeeds, reload only the proxy configuration. This preserves
the Caddy and registry volumes:

```bash
docker compose exec -T caddy \
  caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile
```

Confirm the container remains healthy and that its mounts still reference the
root-owned secret directory. Never use `docker compose down -v` and never
delete a data volume for a certificate change.

## Direct SNI and public smoke checks

Run direct checks against the explicitly authorized origin address
`10.33.99.13`; do not silently substitute another lab address:

```bash
ROOT=/secure/operator-input/cloudflare-origin-rsa-root.pem
for spec in \
  '9445 update.neosecra.com' \
  '9446 license.neosecra.com' \
  '9447 registry.neosecra.com'; do
  set -- $spec
  timeout 10 openssl s_client \
    -connect "10.33.99.13:$1" -servername "$2" \
    -CAfile "$ROOT" -verify_hostname "$2" -verify_return_error \
    -brief </dev/null
done
```

From a network path that resolves through Cloudflare, use normal certificate
verification for the positive checks:

```bash
curl --fail --silent --show-error --location \
  https://license.neosecra.com/health
curl --fail --silent --show-error --location \
  https://update.neosecra.com/channels/assessment-stable.json

status="$(curl --silent --show-error --location --output /dev/null \
  --write-out '%{http_code}' https://registry.neosecra.com/v2/)"
case "$status" in
  200|401) echo "registry /v2/: $status" ;;
  *) echo "unexpected registry /v2/ status: $status" >&2; exit 1 ;;
esac
```

Record the Cloudflare response headers and `cf-ray` value. A `526` means the
edge still cannot validate the origin and is not an acceptance result.

## Rollback

If validation, reload, or any smoke fails, restore the checkpointed Caddyfile
and the previous certificate/key pair from the protected secret store. Run the
same validation command, reload Caddy, and verify the persistent volume names
are unchanged. Keep both the failed-change evidence and the rollback evidence;
do not delete volumes or weaken TLS verification.
