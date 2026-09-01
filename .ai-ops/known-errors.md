# neosecra-distribution known errors

- **DIST-CLOUDFLARE-ORIGIN-CERT-010 / live target unavailable:**
  `10.33.99.13` does not answer SSH or the expected TLS ports from the
  authorized runner. The reachable `10.34.99.13` origin still serves the old
  self-signed certificates and must not be changed without explicit target
  confirmation. Cloudflare consequently remains at HTTP `526`.
