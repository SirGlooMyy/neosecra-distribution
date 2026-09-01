# neosecra-distribution fix log

## 2026-09-01 - DIST-CLOUDFLARE-ORIGIN-CERT-010

- Bound the verified Cloudflare Origin CA wildcard certificate to the shared
  Caddy TLS listeners for update, license, registry, assessment, and default
  HTTPS traffic.
- Kept the private key outside Git and documented the root-owned
  `CADDY_CERTS_DIR` secret boundary.
- Added offline certificate/Caddy contract validation and recorded the
  non-secret rollback snapshot.
- Live `.33` deployment remains blocked because the requested address is not
  reachable from the authorized runner.
