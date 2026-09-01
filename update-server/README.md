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

### Public / Let's Encrypt (Production)

```dns
update.neosecra.com.  A  <server-public-ip>
license.neosecra.com. A  <server-public-ip>
```

Caddy auto-HTTPS (Let's Encrypt) requires:
- A public DNS record pointing to the server's public IP.
- Ports 80 and 443 reachable from the internet.
- Use `Caddyfile.public` (no `tls` directive, Caddy auto-provisions).

**Start public server:**
```bash
CADDY_MODE=public CADDYFILE=./Caddyfile.public docker compose up -d
```

### Cloudflare Origin CA (Public / Full strict)

The default `Caddyfile` uses one Cloudflare Origin CA certificate for the
update, license, registry, assessment, and default TLS listeners. Cloudflare
must remain in **Full (strict)** mode. The public certificate is tracked at
`update-server/certs/neosecra-origin.crt`; its matching private key is an
external root-owned secret and is never committed.

```bash
CADDY_MODE=internal \
CADDYFILE=./Caddyfile \
CADDY_CERTS_DIR=/opt/neosecra/secrets/caddy \
docker compose up -d
```

The secret directory must contain `neosecra-origin.crt` (0644) and
`neosecra-origin.key` (0600). See
[docs/CLOUDFLARE-ORIGIN-TLS.md](../docs/CLOUDFLARE-ORIGIN-TLS.md) for the
installation, SNI validation, smoke, and rollback procedure.

### Internal / Custom CA (LAN / Air-Gap / Lab)

```dns
; /etc/hosts on each appliance or internal DNS
100.125.0.108  update.neosecra.com license.neosecra.com
```

Use a legacy Caddyfile selected with `CADDYFILE`, plus the custom CA from
`update-server/certs/` and `update-server/ca/`. Do not point the Origin CA
configuration at a custom-CA key.

**Start internal server:**
```bash
# Select the legacy custom-CA Caddyfile and its matching certificate directory:
CADDY_MODE=internal \
CADDYFILE=/opt/neosecra-update/Caddyfile.internal \
CADDY_CERTS_DIR=/opt/neosecra/secrets/custom-ca \
docker compose up -d
```

For full custom CA documentation see [docs/CUSTOM-CA.md](../docs/CUSTOM-CA.md).
For public deployment details see [docs/PUBLIC-UPDATE-SERVER.md](../docs/PUBLIC-UPDATE-SERVER.md).
For Cloudflare Full (strict) Origin CA installation, validation, and rollback
see [docs/CLOUDFLARE-ORIGIN-TLS.md](../docs/CLOUDFLARE-ORIGIN-TLS.md).

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

## Client Wiring (Current State)

The bootstrap and upgrade scripts in this repository are now wired to use
`update.neosecra.com` as their primary distribution endpoint.

### What is wired

| Mechanism | Status | Details |
|-----------|--------|---------|
| Channel URL | ✅ Wired | `upgrade.sh` fetches `https://update.neosecra.com/channels/assessment-stable.json` (overridable via `NEOSECRA_CHANNEL_URL`). |
| Bootstrap URL | ✅ Wired | Derived from target version: `https://update.neosecra.com/releases/<version>/bootstrap.sh` |
| Archive URL | ✅ Wired | Resolved from the channel JSON release entry (`archive`/`url` field), with fallback to `https://update.neosecra.com/releases/<version>/distribution.tar.gz`. Overridable via `NEOSECRA_DISTRIBUTION_ARCHIVE_URL`. |
| SHA-256 verification | ✅ Wired | `upgrade.sh` verifies every downloaded distribution archive. Prefers the `sha256` field in channel JSON; falls back to the `.sha256` sidecar file. Hard-fails on mismatch. |
| Minisign verification | ✅ Wired | `upgrade.sh`, bootstrap and the host update-agent verify both the channel manifest and release `.minisig` files against the pinned public key (`deployment/upgrade/update-neosecra-com.pub`). Signature verification is unconditionally fail-closed; unsigned or hash-unverified payloads are rejected in every environment. |
| Bootstrap version resolution | ✅ Wired | `bootstrap.sh` resolves the target version from channel JSON `current_version` at runtime, using `python3` / `jq` / `grep+sed` in preference order. No more hardcoded `1.0.9`. |
| Downgrade protection | ✅ Wired | `upgrade.sh` refuses to install a version older than the installed one; `NEOSECRA_ALLOW_DOWNGRADE=1` overrides. |
| Channel JSON parsing | ✅ Wired | Uses `python3` first, then `jq`, falls back to `grep`+`sed` if neither is available. |

### Env overrides

| Variable | Default | Purpose |
|----------|---------|---------|
| `NEOSECRA_CHANNEL_URL` | `https://update.neosecra.com/channels/assessment-stable.json` | Channel manifest URL |
| `NEOSECRA_DISTRIBUTION_ARCHIVE_URL` | auto-resolved from channel JSON | Distribution archive URL |
| `NEOSECRA_VERSION` | auto-resolved from channel JSON | Pin a specific version (in bootstrap.sh) |
| `NEOSECRA_SIGNATURE_PUBKEY` | `deployment/upgrade/update-neosecra-com.pub` | Path to minisign public key |
| `NEOSECRA_REQUIRE_SIGNATURE` | `1` (固定) | İmza doğrulaması atlanamaz; `0` açıkça reddedilir |
| `NEOSECRA_ALLOW_DOWNGRADE` | `0` | Set to `1` to allow downgrading |
| `NEOSECRA_UPGRADE_BOOTSTRAP` | `1` | Set to `0` to skip the bootstrap pipeline |

### Remaining work

- **Docker bundle artifact** (`docker-bundle-*.tar.zst`) — the publish script
  generates it, but the client does not yet consume it (future: air-gapped
  installs).

### Offline E2E harness

The upgrade E2E test is parameterized and does not require the live update host.
Point it at an isolated HTTP(S) fixture or test server and provide the trusted
public key explicitly:

```bash
UPDATE_SERVER_BASE_URL=http://127.0.0.1:18993 \
UPDATE_SERVER_CHANNEL=assessment-stable \
UPDATE_SERVER_EXPECTED_VERSION=1.3.29 \
UPDATE_SERVER_PUBLIC_KEY=public-keys/update-neosecra-com.pub \
bash update-server/src/e2e-test.sh
```

For an internal CA, set `UPDATE_SERVER_CA_CERT=/path/to/ca.crt`. The harness
fails closed when the channel signature, archive hash, or archive minisign is
missing or invalid.
- **Fallback to GitHub** if the update server is unreachable — the scripts will
  currently fail with an error; resilience fallback can be added in a future
  iteration.

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
