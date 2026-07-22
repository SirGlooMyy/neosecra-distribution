# NeoSecra Distribution Channel

Private distribution repository for NeoSecra product releases.

**This repository contains NO source code.** Only release metadata,
channel manifests, schemas, and public verification keys.

## Products

| Product | Edition | Channel |
|---------|---------|---------|
| NeoSecra Assessment | security-health | `assessment-stable`, `assessment-beta` |
| NeoSecra SOC | soc | `soc-stable`, `soc-beta` (future) |

## Repository Structure

```
schemas/          JSON Schemas for release/channel/revocation manifests
channels/         Channel manifests listing available releases
public-keys/      Public verification keys (signing, when implemented)
docs/             Customer updater documentation
```

## Access

- **Source repositories**: No customer access
- **Distribution repository**: Customer `Contents: read` only
- **GHCR packages**: Customer `read:packages` only

See `docs/CUSTOMER-UPDATER-AUTH.md` for credential requirements.
