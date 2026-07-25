# NeoSecra Update Server

Self-hosted release distribution server for NeoSecra on-prem appliances.
Serves release artifacts, channel metadata, and signatures via HTTPS.

## Architecture

```
┌──────────────┐       HTTPS (80/443)      ┌──────────────────────┐
│  NeoSecra    │ ──────────────────────▶   │  update.neosecra.com │
│  Appliance   │                           │  (Caddy + static)    │
│  (client)    │ ◀──────────────────────   │                      │
└──────────────┘     artifacts + sigs      │  ┌────────────────┐  │
                                           │  │  /srv/update/  │  │
                                           │  │  ├─ channels/  │  │
                                           │  │  └─ releases/  │  │
                                           │  └────────────────┘  │
                                           └──────────────────────┘
                                                      ▲
                                                      │ rsync
                                           ┌──────────┴─────────┐
                                           │  Publish workstation│
                                           │  (publish.sh)       │
                                           └────────────────────┘
```

## DNS Setup

**Production (public DNS):**
```
update.neosecra.com.  A  <server-public-ip>
```

**LAN / testing (hosts file on each appliance or DNS override):**
```
192.168.2.101  update.neosecra.com
```

Caddy auto-HTTPS (Let's Encrypt / ZeroSSL) requires:
- A public DNS record pointing to the server's public IP.
- Ports 80 and 443 reachable from the internet.

**For LAN-only testing without public DNS:**
Use a self-signed certificate or internal CA. Run Caddy with the `tls internal`
directive, or mount your own cert. Example:

```caddyfile
update.neosecra.com {
    tls internal
    # ... rest of config
}
```

## First Deploy

```bash
# On the update server:
cd /opt/neosecra-update
git clone <repo> .
cp -r update-server/* .

# Or if using rsync from the publish workstation:
rsync -az ./update-server/ user@update.neosecra.com:/opt/neosecra-update/

# Start Caddy:
docker compose up -d

# Verify:
curl -I https://update.neosecra.com/channels/assessment-stable.json
```

## Key Ceremony

The signing keypair uses **minisign** (Ed25519). Run this once:

```bash
# 1. Install minisign if missing (see "Installing minisign" below).

# 2. Generate the keypair:
mkdir -p ~/.neosecra
minisign -G -s ~/.neosecra/update-signing.key \
            -p public-keys/update-neosecra-com.pub

# 3. Protect the secret key:
chmod 600 ~/.neosecra/update-signing.key

# 4. Commit the public key to the repo:
git add public-keys/update-neosecra-com.pub
git commit -m "feat: add update server public signing key"
```

**The secret key (`~/.neosecra/update-signing.key`) must NEVER be committed.
It stays on the publish workstation or a hardware security module.**

### Installing minisign

- **Debian/Ubuntu:** `apt install minisign`
- **Arch Linux:** `pacman -S minisign`
- **Static binary** (recommended for CI): download from
  https://github.com/jedisct1/minisign/releases and place in `~/.local/bin/`.

### Key Rotation

```bash
# 1. Generate a new keypair (use a different comment/identifying name):
minisign -G -s ~/.neosecra/update-signing-YYYYMMDD.key \
            -p public-keys/update-neosecra-com-YYYYMMDD.pub

# 2. Re-sign all published artifacts with the new key
#    (or publish a transitional channel JSON signed by both keys).

# 3. Update the pinned public key in the client (upgrade.sh / bootstrap.sh)
#    to point to the new public key.

# 4. Publish a channel update noting the key rotation.

# 5. After all deployed appliances have rotated, retire the old key.
```

## Publish a Release

```bash
./update-server/publish.sh \
    --product assessment \
    --channel stable \
    --version 1.1.2 \
    --archive /tmp/neosecra-distribution-1.1.2.tar.gz \
    --bundle /tmp/docker-bundle-1.1.2.tar.zst \
    --rsync user@update.neosecra.com:/srv/update

# Dry-run first to verify:
./update-server/publish.sh \
    --product assessment \
    --channel stable \
    --version 1.1.2 \
    --archive /tmp/neosecra-distribution-1.1.2.tar.gz \
    --dry-run
```

## Client Wiring (Next Step)

The existing `bootstrap.sh` and `upgrade.sh` currently pull from GitHub raw
URLs. After this server is deployed, those scripts will be updated to:

1. Fetch channel JSON from `https://update.neosecra.com/channels/<product>-<channel>.json`
2. Verify the channel JSON with the minisign signature and the pinned public key.
3. Download `distribution.tar.gz` (and optionally `docker-bundle-*.tar.zst`)
   from the release URL in the channel JSON.
4. Verify SHA-256 checksum and minisign signature on every artifact.
5. Fall back to GitHub if the update server is unreachable (resilience).

The pinned public key will be bundled in the bootstrap script or deployed
alongside the appliance at `/opt/neosecra/assessment/state/update-pubkey`.

## File Layout

```
update-server/
├── docker-compose.yml      # Caddy reverse-proxy
├── Caddyfile               # Site config with caching directives
├── publish.sh              # Release publishing script
├── README.md               # This file
└── www/                    # Document root served by Caddy
    ├── README.md           # www layout documentation
    ├── channels/           # Channel manifests (+ .minisig)
    │   └── .gitkeep
    └── releases/           # Versioned artifact directories
        └── .gitkeep
```

## `.gitignore` Notes

The repository's `.gitignore` already excludes sensitive files. Ensure
`*.key` and any secret key material are **never** committed. The signing
key lives at `~/.neosecra/update-signing.key` — outside the repo entirely.
