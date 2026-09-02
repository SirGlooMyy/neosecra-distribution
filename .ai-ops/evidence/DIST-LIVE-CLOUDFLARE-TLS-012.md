# DIST-LIVE-CLOUDFLARE-TLS-012 — verification evidence

- **Captured:** 2026-09-01 (UTC)
- **Scope:** Distribution only; no SOC work
- **Requested origin:** `10.33.99.13`
- **Repository:** `/home/sirgloomy/projects/neosecra-distribution`
- **Branch / HEAD:** `main` / `e9f7df4e0b618d0602c77719828ec396aac92edf`
- **Worktree:** dirty before this evidence; pre-existing user files preserved
- **Reviewed HEAD comparison:** global Distribution review is `08c4a19`; current HEAD differs and was treated as stale

## Proxy and DNS diagnosis

- Public DNS via `@1.1.1.1` resolves all three names to Cloudflare edges
  `104.21.58.17` and `172.67.197.53`; `license.neosecra.com` is a CNAME to
  `update.neosecra.com`.
- Local `/etc/hosts` overrides update/license to `192.168.2.101`; that local
  endpoint presents an unrelated self-signed `VDATAINKJET` certificate and was
  not used as public acceptance evidence.
- Public proxy is Cloudflare. No Cloudflare mode or TLS bypass was changed.

## Public baseline (strict TLS, before any live change)

Normal `curl` with certificate verification enabled, using Cloudflare edge
resolution, returned `HTTP/2 526` for each endpoint:

| Host | Probe | Result |
|---|---|---|
| `license.neosecra.com` | `/health` | 526 |
| `update.neosecra.com` | `/channels/assessment-stable.json` | 526 |
| `registry.neosecra.com` | `/v2/` | 526 |

The body was `error code: 526`; no `-k`/`--insecure` option was used. The
Cloudflare edge certificate itself was valid (`CN=neosecra.com`, SAN
`neosecra.com` and `*.neosecra.com`, Google Trust Services WE1, valid through
2026-11-01), proving the failure is edge-to-origin validation.

## Authorized-origin reachability gate

`10.33.99.13` did not answer ICMP, TCP 22, 80, 443, 7443, 9445, 9446, or
9447. SSH as `neosecra` timed out before authentication; no password was
entered or stored. Tailscale has no peer or subnet route for this address.

The separately reachable `10.34.99.13` was **not substituted**. Read-only SNI
probes there returned the old self-signed, SAN-less leaves on all three named
listeners (2026-08-21 through 2027-08-21), which is consistent with the 526
root cause but is not proof of the requested origin.

## Candidate certificate and local mapping

`update-server/certs/neosecra-origin.crt` is the existing Cloudflare Origin CA
wildcard leaf and is byte-identical to the prior approved Origin candidate.

| Field | Observed |
|---|---|
| Subject | `O=CloudFlare, Inc., OU=CloudFlare Origin CA, CN=CloudFlare Origin Certificate` |
| Issuer | `C=US, O=CloudFlare, Inc., OU=CloudFlare Origin SSL Certificate Authority, L=San Francisco, ST=California` |
| Validity | 2026-08-29 14:58:00 UTC → 2041-08-25 14:58:00 UTC |
| SAN | `DNS:*.neosecra.com`, `DNS:neosecra.com` |
| SHA-256 fingerprint | `C6:4A:E2:FF:72:9A:14:BE:05:E8:4D:27:84:FE:1E:A7:61:26:09:B7:50:63:7A:56:62:99:CA:E6:42:6B:15:21` |
| Chain | one leaf; Cloudflare Origin RSA root is not sent by Caddy |
| Key match | PASS; cert/key public-key SHA-256 `3ad8a26da079dc94292ff41c63167b8f1c6b5be289fe99abbb1cf7f1c19ad7ec` |
| File modes | cert `0644`, key `0600` (key remains ignored/uncommitted) |

The candidate verifies for all three hostnames against the official
Cloudflare Origin RSA root fetched over strict HTTPS. The current dirty
Caddyfile maps the same pair to `update:9445`, `license:9446`,
`registry:9447`, and the public `:443` listener.

## Validation and change state

- `docker compose -f update-server/docker-compose.yml config --quiet`: PASS.
- Docker `caddy:2-alpine` validation of the exact current Caddyfile/mounts:
  PASS (`Valid configuration`).
- `bash -n` on seven `update-server` scripts: 7 passed, 0 failed.
- `update-server/src/cloudflare-origin-test-012.sh --static`: 12 passed,
  0 failed, 3 skipped (live SNI/public smoke and optional secret/root inputs).
- `shellcheck` is not installed in this runner; `bash -n` is the available
  shell syntax check and passed for the new test.
- Nginx and Traefik are not part of this stack and their binaries are absent;
  no such proxy was changed.
- `git diff --check`: FAIL only on pre-existing user dirty whitespace in
  `.ai-ops/fix-log.md`, `deployment/v1/install/postflight.sh`,
  `deployment/v1/upgrade/upgrade.sh`, and
  `tests/test_platform_release_contract.py`; no cleanup was performed.
- No live config/certificate metadata backup could be taken because the exact
  origin is unreachable. No certificate copy, reload, recreate, volume change,
  rollback, or destructive action occurred.

## Smoke and verdict

The required two post-change public smoke rounds and direct `.33` SNI checks
are `NOT_RUN` because the authorized origin control path is unavailable; the
baseline remains 526. No `LIVE_VERIFIED` claim is made.

**Verdict: `BLOCKED`** — obtain network reachability to `10.33.99.13` and the
interactive `neosecra` access path, then execute the runbook and record both
successful public rounds before any live verdict.

## 429-wait retry (2026-09-01 UTC)

After the requested 429 wait interval, the exact same gates were rechecked:

- `10.33.99.13` remained unreachable on TCP 22/80/443/7443/9445/9446/9447;
  interactive SSH timed out before authentication.
- Strict Cloudflare probes remained `526` for license health, update manifest,
  and registry `/v2/` (latest observed `cf-ray`: `a345a5c7e9db4e91-DUS`,
  `a345a5ca5eaff805-DUS`, `a345a5ccbc846d1d-AMS`).
- No live backup, certificate/key copy, reload/recreate, rollback, or smoke
  round was possible. Verdict remains `BLOCKED` and `LIVE_VERIFIED` remains
  prohibited.
