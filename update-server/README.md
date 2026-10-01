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

### Internal / Custom CA (LAN / Air-Gap / Lab)

```dns
; /etc/hosts on each appliance or internal DNS
100.125.0.108  update.neosecra.com license.neosecra.com
```

Use `Caddyfile` (default, with `tls /etc/caddy/certs/...` directive) and
the custom CA from `update-server/certs/` and `update-server/ca/`.

**Start internal server:**
```bash
docker compose up -d
# or explicitly:
CADDY_MODE=internal docker compose up -d
```

For full custom CA documentation see [docs/CUSTOM-CA.md](../docs/CUSTOM-CA.md).
For public deployment details see [docs/PUBLIC-UPDATE-SERVER.md](../docs/PUBLIC-UPDATE-SERVER.md).

## Caddy Upstream Map (live `Caddyfile`)

The default `Caddyfile` mirrors the configuration running on the live update
host. Caddy reaches the other stacks' containers by Docker DNS name; only
`registry` is defined in this compose file.

| Host / listener | Upstream | Notes |
|---|---|---|
| `neosecra.com`, `www.neosecra.com` (`:443`, and `:7443` for the Cloudflare origin) | `neosecra-web:8080` | Marketing site container; HSTS `max-age=63072000; includeSubDomains` |
| `update.neosecra.com` (`:443`, `:9445`) | static `/srv/update` (`./www`) | `/channels/*` no-cache, `/releases/*` immutable |
| `license.neosecra.com` (`:443`, `:9446`) `/api/*`, `/health` | `lisans-backend-1:8000` | License backend |
| `license.neosecra.com` (`:443`, `:9446`) everything else | `lisans-frontend-1:8080` | License frontend; the old Vite port `5173` is no longer used |
| `registry.neosecra.com` (`:443`, `:9447`) | `registry:5000` | Docker Registry (this compose file) |
| catch-all `:443`, `:7443`: `/api/demo-request*` | `demo-mailer:8000` | `mailer/mailer.py`; requires `SMTP_PASS` (optional `SMTP_SERVER`, `SMTP_PORT`, `SMTP_USER`, `NOTIFY_EMAIL`) from the environment, no built-in default password |
| catch-all `:443`, `:7443`: everything else | static `/srv/web` (`/opt/neosecra/web`) | SPA fallback to `/index.html` |
| `:80` | redirect to HTTPS | |

Every site block uses `tls /etc/caddy/certs/neosecra.com.crt
/etc/caddy/certs/neosecra.com.key`; the host `certs/` directory must contain
that pair (private keys are never committed).

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

# 3. Add the new public key beside the old key in the client's pinned
#    keyring (upgrade.sh / bootstrap.sh). Clients accept any regular *.pub
#    file in the configured keyring directory during the overlap window.

# 4. Publish a channel update noting the key rotation.

# 5. After all deployed appliances have rotated, retire the old key.
```

## Publish a Release

`publish.sh` is the canonical Bash publisher. Product behavior is configured in
`../products/<code>.json`, validated against
`../schemas/product-registry.schema.json`. It uses Python 3 standard-library
helpers under `lib/`; installing a new runtime or service is unnecessary.

The existing CLI remains supported:

```bash
./update-server/publish.sh --product assessment --channel stable \
  --version 1.3.30 --archive /tmp/neosecra-distribution-1.3.30.tar.gz \
  --bundle /tmp/docker-bundle-1.3.30.tar.zst --dry-run

./update-server/publish.sh --product soc --channel beta --version 1.0.4 \
  --archive /tmp/neosecra-soc-1.0.4.tar.gz \
  --bundle /tmp/neosecra-soc-1.0.4-bundle.tar.zst \
  --images-lock /tmp/neosecra-soc-1.0.4.images.lock

./update-server/publish.sh --product hotspot --channel candidate \
  --version 0.3.118 --archive /tmp/hotspot-0.3.118.tar.gz \
  --migration-metadata /tmp/migration-contract.json --dry-run
```

`--key`, `--www`, `--rsync`, `MINISIGN_BIN` and
`UPDATE_SERVER_TARGETS` keep their existing meanings. `--help` lists all options.
Use canonical product codes on the CLI; historical product aliases are accepted
when reading existing channels. Versions are numeric `major.minor.patch`.
Unknown products/channels/steps and missing required inputs fail before staging
an active publication. Dry-run uses cleaned private temporary previews; it does
not sign, run promotion gates, lock active paths, or contact remote targets. It
still validates inputs, transformations, existing signed channels and monotonicity.

### Registering another product

Add a schema-valid `products/<code>.json` with its permitted channels, archive
name pattern, trust policy, input requirements/formats, optional bootstrap,
repository gate, migration contract, rollback policy and release path layout.
The fixture `../tests/fixtures/fixtureprod.json` demonstrates a product using the
existing generic artifact gate without publisher changes. No prerequisite empty
channel file is required for a new product.

`steps` names repository-owned `lib/steps/<name>.sh` files. The current named
steps are `bundle-lock` (Docker-save configuration verification and authenticated
package lock) and `migration-contract` (backup-free, rollback-safe migration
metadata). Their contributions compose without replacing artifact metadata. Optional steps
skip absent inputs; bundle-lock inputs must be supplied together. Artifact and
signature/checksum filenames cannot collide.
Registry files cannot contain commands, shell expressions or arbitrary executable
paths. New products can reuse these steps in any declared order.

Bootstrap `null` publishes no bootstrap file; its release field is `null`.
Hotspot retains the historical `/none` bundle sentinel when no bundle is supplied,
including `docker_bundle` and the compatibility `bundle_url` field.
Assessment beta's historical `security-health` edition is an explicit
read-compatibility exception. Its never-published channel remains registered
under `legacy_empty_channels` with `status: reserved`.

`bash bin/validate-channels.sh [SOURCE_ROOT [WWW_ROOT]]` validates all registered
channels (seven in the canonical registry), using `python3` or falling back to
`python`. An omitted or empty WWW root disables source/WWW comparison. Only a
channel explicitly listed in `legacy_empty_channels` may lack a signature, and
only with an empty `releases` array, explicit `current_version: null`, and status
`reserved` or `unavailable`. Existing signatures are always verified; a published
channel requires a valid signature even while listed in `legacy_empty_channels`.
When a WWW root is supplied, unsigned reservations must match JSON bytes and
have no signature there either. This validation exception does not authorize
unsigned publication or activation; the publisher still requires signed pairs.

### Publication and trust

All four canonical product records (Assessment, PISH, SOC and Hotspot) use
`minisign-package-v1`. Minisign is the active trust path; neither Cosign nor
Syft is a prerequisite for this policy. Product-specific bundle, images-lock,
migration and attestation requirements remain unchanged.

The publisher takes exclusive source/WWW locks, snapshots and verifies existing
channel pairs, stages original filenames in an owner-only directory, inspects
archives, executes declared transformations, and passes the final archive to the
registered gate on its declared promotion channels. A gate cannot mutate the
release inputs. The generic gate accepts `--archive`, `--version` and
`--trust-policy` and optional `--registry` while retaining its parameterless repository-test mode. Its
artifact mode inspects the supplied archive and still requires repository tests;
product-specific artifact/attestation gates retain their existing checks. The
parameterless generic gate defaults to Minisign; an explicit policy must match
the supplied registry. Cosign/SPDX is an **optional future upgrade**, retained
in the implementation and negative tests but selected by no canonical record.
In that artifact mode, the actual package must contain a version/product-bound
release manifest, immutable images (or an exact packaged lock) and SPDX-2.3 SBOMs.
Every image signature and the existing customer attestation predicate are verified
with the root-owned, non-writable public trust root `/etc/neosecra/certs/cosign.pub`.
Missing metadata or trust roots block publication, without a legacy/Minisign fallback.

SHA-256 sidecars and Minisign signatures are generated and verified against the
repository's pinned `public-keys/*.pub` keyring before activation. The trust policy
never falls back: `cosign-spdx-v1` requires Cosign even if a gate would otherwise
not run; `minisign-package-v1` requires Minisign. SOC stable additionally requires
the existing root-managed attestation policy and pinned preflight receipt; its
method must exactly match the registry. A receipt must bind the **final** archive,
bundle and images lock. `soc-bundle-lock.py` retains its standalone CLI for
preparing that final archive before the root-pinned preflight. Gzip transformation
is deterministic; an already correct bundle lock/checksum package is retained.

The generic upgrade image-enforcement step resolves `trust_policy` from the
canonical `products/<product>.json` next to the original Distribution source
tree. Installed trees without that registry must carry an explicit top-level
`trust_policy: minisign-package-v1` in the authenticated package's
`release-manifest.yaml`. Missing, unsupported or conflicting policies fail
closed. Both policies retain signed channel/package verification, exact Compose
service/dependency mapping, local image digest checks and immutable pinning.
Only `cosign-spdx-v1` additionally requires per-image Cosign signatures and
attestations. Existing installers or package producers that omit both the
registry and manifest policy must supply that metadata before generic apply;
publisher dry-run alone does not establish installability.

Every new release manifest must declare the schema-required top-level
`trust_policy: minisign-package-v1` (or `cosign-spdx-v1` for a product registered
with that policy). YAML uses a single-line scalar; JSON manifests use the same
field. If an archive contains a release manifest, publication requires exactly
one manifest whose policy matches `products/<product>.json`, both before and
after registered archive transformations, including dry-run and ungated channels.
Missing, duplicate, unsupported or mismatched policies stop publication before
signing/activation. Archives without a manifest retain their existing contract.
An old manifest without this field still fails closed on a customer host without
the registry: obtain a newly signed package carrying the registered policy;
never edit the installed signed manifest to bypass the error.

The POSIX signer receives the existing private key through an inherited read-only
file descriptor (`/dev/fd/3`), scoped to the signing subprocess. No key pathname,
key contents or password is passed to Minisign as a command-line value; no key
copy or emulated filesystem symlink is created. Enter encrypted-key passwords
through Minisign's stdin/TTY. Tracing is disabled, signer diagnostics are suppressed,
and temporary paths are created under `umask 077`
and cleaned on exit. Archive links, traversal, special files, duplicate members
and secret-looking filenames are rejected without extraction. Exact approved
`tests/...` paths may be declared in `secret_allowlist`; this is not a glob.

The verified channel candidates are renamed into both `channels/` and
`www/channels/` with identical signatures. Caught replacement errors and
INT/TERM restore the original pairs. Each rename is atomic; regular files across
multiple paths/filesystems cannot switch at one instant. A concurrent reader can
briefly observe a mismatched pair and must retry after signature rejection.
SIGKILL/power loss can interrupt this multi-file transaction: inspect source/WWW
pairs and outstanding `.publish-lock` directories before recovery. Do not remove
locks while another publisher is running. An interrupted publish can leave a
verified, unreferenced immutable release; identical artifacts can be reused on
retry or channel promotion, but different content is always rejected.

Optional transfers send only this publication's private staging paths. They do
not mirror the entire WWW tree and never delete unrelated files. SSH requires
`StrictHostKeyChecking=yes`; the destination runs Python 3 and Minisign, verifies
received SHA-256/signatures, binds payloads to the signed channel, rejects remote
downgrades and immutable-version replacements, then activates the received inodes. The remote helper
cleans its incoming directory; cleanup is attempted after failed transfers too.
Publishing to multiple hosts is not a distributed atomic transaction; reconcile
already successful hosts if a later host or local activation fails.

### Release URL compatibility and host rollout

New SOC, Hotspot and PISH artifacts use `releases/<product>/<version>/`.
`deployment/v1/agent/*.sh` resolves artifact URLs from signed channel metadata.
Assessment retains `releases/<version>/`: the agent-invoked
`deployment/v1/upgrade/upgrade.sh` still derives its bootstrap URL from that
legacy layout. Historical release records are preserved as raw JSON bytes;
previously published `/releases/<version>/...` artifacts must remain available.

Deploy the publisher, **all** `lib/` helpers/steps, `soc-bundle-lock.py`, the four
product records, the registry schema, affected CI gates and channel validator
as one reviewed unit. Keep existing public keys, private-key location, old
releases and the exact current source/WWW channel pairs. Reconcile any existing
source/WWW JSON **or signature** drift through the separately authorized
operations process before the first publish. Do not blindly replace channel
files with repository snapshots from another host.

Host tools: Bash with arrays/mapfile, Python 3, SHA-256 coreutils, Minisign,
Cosign and its root-managed public trust root for the applicable policy, and the existing gate dependencies (pytest,
Docker and product-owned verifiers). Zstd is necessary for `.tar.zst` inputs.
Rsync targets additionally need rsync/SSH locally and Python 3/Minisign remotely,
an approved SSH host-key entry and write access to the destination. Gates run
through Bash; no executable-bit dependency is introduced for sourced steps.
The first new publish changes only the new release URLs for namespaced products;
Assessment paths and all old release URLs remain unchanged. Assessment records
the existing `backup-restore` runtime policy; the publisher does not execute or
change customer rollback scripts. Production signing requires POSIX descriptor
paths; Git Bash/Windows tests use the fake signing adapter.

### Offline verification

```powershell
$env:TEMP="$PWD\.codex-tmp"; $env:TMP=$env:TEMP
$env:PYTHONDONTWRITEBYTECODE='1'
New-Item -ItemType Directory -Force .codex-tmp | Out-Null
.\.codex-python\python.exe -m pytest tests/test_product_registry.py `
  tests/test_publish_activation.py tests/test_soc_publish_contract.py `
  tests/test_compatibility_matrix.py -q -p no:cacheprovider `
  --basetemp=.codex-tmp\pt-d2r
```

The tests use Git Bash on Windows and isolated fake Minisign/rsync/SSH tools.
They do not use real private keys, contact a live host or modify checked-in
channels/WWW artifacts. Local contract tests do not constitute live release
acceptance.

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
| Minisign verification | ✅ Wired | `upgrade.sh`, bootstrap and the host update-agent verify both the channel manifest and release `.minisig` files against the pinned keyring (`deployment/v1/ca/*.pub`). Signature verification is unconditionally fail-closed; unsigned or hash-unverified payloads are rejected in every environment. |
| Bootstrap version resolution | ✅ Wired | `bootstrap.sh` resolves the target version from channel JSON `current_version` at runtime, using `python3` / `jq` / `grep+sed` in preference order. No more hardcoded `1.0.9`. |
| Downgrade protection | ✅ Wired | `upgrade.sh` refuses to install a version older than the installed one; `NEOSECRA_ALLOW_DOWNGRADE=1` overrides. |
| Channel JSON parsing | ✅ Wired | Uses `python3` first, then `jq`, falls back to `grep`+`sed` if neither is available. |

### Env overrides

| Variable | Default | Purpose |
|----------|---------|---------|
| `NEOSECRA_CHANNEL_URL` | `https://update.neosecra.com/channels/assessment-stable.json` | Channel manifest URL |
| `NEOSECRA_DISTRIBUTION_ARCHIVE_URL` | auto-resolved from channel JSON | Distribution archive URL |
| `NEOSECRA_VERSION` | auto-resolved from channel JSON | Pin a specific version (in bootstrap.sh) |
| `NEOSECRA_SIGNATURE_PUBKEY` | `deployment/v1/ca` | Path to a minisign public key or a directory of pinned `*.pub` keys |
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
├── mailer/                 # Demo-request mailer (demo-mailer:8000 upstream)
│   └── mailer.py
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
