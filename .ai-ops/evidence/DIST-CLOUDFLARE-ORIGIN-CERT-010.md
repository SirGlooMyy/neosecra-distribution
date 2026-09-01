# DIST-CLOUDFLARE-ORIGIN-CERT-010 evidence

- **Captured:** 2026-09-01 (UTC)
- **Requested origin:** `10.33.99.13`
- **Observed reachable origin:** `10.34.99.13` (not substituted for the requested target)
- **Rollback checkpoint:** `/tmp/neosecra-origin-cert-rollback-20260901T100104Z`

## Pre-change diagnosis

Direct SNI on the reachable `.34` address returned one self-signed leaf per
vhost, with no SAN extension:

| SNI / port | Subject | Issuer | Validity |
|---|---|---|---|
| `update.neosecra.com:9445` | `CN=update.neosecra.com` | same subject | 2026-08-21 to 2027-08-21 |
| `license.neosecra.com:9446` | `CN=license.neosecra.com` | same subject | 2026-08-21 to 2027-08-21 |
| `registry.neosecra.com:9447` | `CN=registry.neosecra.com` | same subject | 2026-08-21 to 2027-08-21 |

The corresponding repository certificate files did contain only one leaf
each (no fullchain) but their private keys matched. Their SANs were limited to
their individual names (the update leaf also included localhost and the local
IP), so they could not satisfy all three Cloudflare origin vhosts with one
binding. The candidate pair's public-key hash is
`3ad8a26da079dc94292ff41c63167b8f1c6b5be289fe99abbb1cf7f1c19ad7ec`.

Normal TLS requests through Cloudflare returned `526` for all three names.
The response body was `error code: 526`; no verification bypass was used.
Captured `cf-ray` values were `a34389a73b43656b-AMS` (update),
`a34389aaa8f41489-AMS` (license), and `a34389ad6c43d7f-AMS` (registry).

## Candidate certificate and repository validation

- Candidate: `update-server/certs/neosecra-origin.crt` (public leaf only).
- SAN: `DNS:*.neosecra.com`, `DNS:neosecra.com`.
- Issuer: Cloudflare Origin SSL Certificate Authority.
- Validity: 2026-08-29 14:58:00 UTC through 2041-08-25 14:58:00 UTC.
- Chain: one leaf; `openssl verify` against the Cloudflare RSA Origin CA root
  passed for all three hostnames.
- Certificate/public-key hash matched the protected operator key.
- `update-server/Caddyfile` uses the shared pair on all five TLS listeners;
  Caddy validation passed with the key mounted read-only in a temporary test
  container.
- `docker compose config --quiet`, `git diff --check`, and the dedicated
  Origin TLS contract test passed.

## Live status

The requested `.33` address had no response on SSH or ports
443/7443/9445/9446/9447 from this runner. Therefore no certificate/key copy,
proxy reload, direct `.33` SNI acceptance, Cloudflare recovery smoke, or live
rollback drill was performed. Persistent volumes were not touched.
