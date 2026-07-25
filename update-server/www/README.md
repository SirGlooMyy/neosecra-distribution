# Update Server — www Layout

This directory is served as the document root for `update.neosecra.com`.
All files here are public and served over HTTPS.

## Directory Structure

```
www/
├── channels/
│   ├── <product>-<channel>.json          # Channel manifest
│   └── <product>-<channel>.json.minisig  # Minisign (Ed25519) signature
└── releases/
    └── <version>/
        ├── distribution.tar.gz           # Full distribution archive
        ├── distribution.tar.gz.sha256    # SHA-256 checksum
        ├── distribution.tar.gz.minisig   # Minisign signature
        ├── docker-bundle-<version>.tar.zst   # Pre-baked Docker images (optional)
        ├── docker-bundle-<version>.tar.zst.sha256
        ├── docker-bundle-<version>.tar.zst.minisig
        ├── bootstrap.sh                  # One-line installer script
        └── bootstrap.sh.minisig          # Minisign signature
```

## Conventions

- **Channel JSON** is served with `Cache-Control: no-cache` so clients always
  fetch fresh metadata before deciding to upgrade.
- **Release artifacts** are served with `Cache-Control: public, max-age=31536000, immutable`
  because each version directory is written exactly once and never modified.
- **Signatures**: Every published file has a corresponding `.minisig` (Ed25519)
  created with the signing key whose public key is pinned in the client.

## Publishing

Use `../publish.sh` to stage files, update channel JSON, and optionally rsync
to the production server. Do **not** modify files inside `www/` manually —
always go through the publish script.

## .gitkeep

The `channels/` and `releases/` subdirectories contain a `.gitkeep` so the
directory tree is tracked by git even when empty.
