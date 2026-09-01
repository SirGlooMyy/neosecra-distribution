# neosecra-distribution - DIST-CLOUDFLARE-ORIGIN-CERT-010

- **Updated:** 2026-09-01
- **Repository:** `/home/sirgloomy/projects/neosecra-distribution`
- **Branch / HEAD:** `fix/assessment-live-installer` / `322d772`
- **Worktree:** clean after scoped Cloudflare Origin TLS commit; no live mutation

## Verified repository state

- `update-server/Caddyfile` binds the shared Origin CA pair to update,
  license, registry, assessment, and the default TLS listeners.
- `update-server/certs/neosecra-origin.crt` is the verified public leaf:
  SAN `*.neosecra.com`, `neosecra.com`; Cloudflare Origin SSL CA issuer;
  valid 2026-08-29 through 2041-08-25; SHA-256 fingerprint
  `C6:4A:E2:FF:72:9A:14:BE:05:E8:4D:27:84:FE:1E:A7:61:26:09:B7:50:63:7A:56:62:99:CA:E6:42:6B:15:21`.
- Matching private key remains outside Git in protected operator scratch
  storage; public-key hash match and Cloudflare RSA root verification passed.
- `docker compose config --quiet` and Caddy validation with the candidate
  certificate/key mount passed; no volume was recreated or deleted.
- Focused results: Origin TLS contract `13 passed, 0 failed, 0 skipped`;
  regression suite `19 passed, 0 failed`; agent contract suite `11 passed,
  0 failed`; shell syntax and `git diff --check` passed.

## Live evidence and blocker

- Rollback snapshot: `/tmp/neosecra-origin-cert-rollback-20260901T100104Z`.
- Direct origin `10.34.99.13` still presents the old self-signed,
  single-name certificates on ports 9445-9447.
- Cloudflare positive smokes for all three names still return HTTP `526`.
- The user-authorized target `10.33.99.13` has no reachable route/service
  from this runner (SSH and ports 443/7443/9445/9446/9447 time out). It must
  not be silently replaced with `10.34.99.13`.
- Live certificate installation, Caddy reload, direct `.33` SNI validation,
  Cloudflare recovery smokes, and rollback drill are `NOT_RUN`/`BLOCKED`.

## Handoff

HANDOFF:
- Component: neosecra-distribution Cloudflare Origin TLS
- Status: BLOCKED (HEAD: 322d772)
- Completed: scoped certificate binding, offline validation, regression/runbook evidence
- Blockers/Open: authorized 10.33.99.13 control path unavailable; live 526 remains
- Next Action: obtain access to 10.33.99.13, install root-owned key/cert, validate/reload, run smokes
