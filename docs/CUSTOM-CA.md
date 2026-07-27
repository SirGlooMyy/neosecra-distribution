# NeoSecra Custom CA — TLS for update.neosecra.com + license.neosecra.com

## Overview

Replaces Caddy's ephemeral `tls internal` with a persistent Root CA so TLS
certificates survive container restarts without breaking client trust.

| Component | Detail |
|-----------|--------|
| **Root CA** | `NeoSecra Root CA` — ECDSA P-384, 10 years (self-signed) |
| **Leaf (update.neosecra.com)** | ECDSA P-256, 1 year, SAN: `update.neosecra.com`, `localhost`, `127.0.0.1`, `192.168.2.101` |
| **Leaf (license.neosecra.com)** | ECDSA P-256, 1 year, SAN: `license.neosecra.com` |

## File Layout

```
update-server/
├── Caddyfile                 # References certs via tls directive (NO tls internal)
├── ca/
│   └── update-neosecra-com-root.crt   # Root CA public cert (committed)
├── certs/
│   ├── update-neosecra-com.crt        # Leaf cert for update.neosecra.com (committed)
│   ├── update-neosecra-com.key        # Leaf PRIVATE KEY — NEVER COMMIT (gitignored)
│   ├── license-neosecra-com.crt       # Leaf cert for license.neosecra.com (committed)
│   └── license-neosecra-com.key       # Leaf PRIVATE KEY — NEVER COMMIT (gitignored)
└── docker-compose.yml       # Mounts ./certs → /etc/caddy/certs:ro + ./ca → /etc/caddy/ca:ro

deployment/
└── ca/
    └── update-neosecra-com-root.crt   # Same root CA, bundled for client trust

bootstrap.sh                  # Embedded (base64) CA for system trust injection

docs/
└── CUSTOM-CA.md              # This file

.secrets-ca/                  # NOT COMMITTED — local CA generation workspace
```

## Key Material

| File | Location | Permissions | Committed? |
|------|----------|-------------|------------|
| Root CA private key | `/opt/neosecra/secrets/neosecra-root-ca.key` | `600` | **NO** |
| Leaf private key (update) | `/opt/neosecra/secrets/update-neosecra-com.key` | `600` | **NO** |
| Leaf private key (license) | `/opt/neosecra/secrets/license-neosecra-com.key` | `600` | **NO** |
| Serial file | `/opt/neosecra/secrets/neosecra-root-ca.srl` | `600` | **NO** |

**The `.secrets-ca/` directory in the repo root is a local-only workspace
and is listed in `.gitignore`. Never copy live private keys into the repo.**

## CA Generation Procedure

### Initial generation (one-time)

```bash
# On the publish workstation (NOT in the repo):
export SECRETS=/opt/neosecra/secrets
sudo mkdir -p "$SECRETS" && sudo chmod 700 "$SECRETS"

# === Root CA (ECDSA P-384, 10 years) ===
openssl ecparam -genkey -name secp384r1 -out "$SECRETS/neosecra-root-ca.key"
chmod 600 "$SECRETS/neosecra-root-ca.key"

openssl req -x509 -new -nodes \
  -key "$SECRETS/neosecra-root-ca.key" -sha384 -days 3650 \
  -out "$SECRETS/neosecra-root-ca.crt" \
  -subj "/CN=NeoSecra Root CA/O=NeoSecra" \
  -addext "basicConstraints=critical,CA:TRUE" \
  -addext "keyUsage=critical,keyCertSign,cRLSign"

# === Leaf: update.neosecra.com (ECDSA P-256, 1 year) ===
openssl ecparam -genkey -name prime256v1 -out "$SECRETS/update-neosecra-com.key"
chmod 600 "$SECRETS/update-neosecra-com.key"
# ... (create CSR with SANs, sign with root CA)

# === Leaf: license.neosecra.com (ECDSA P-256, 1 year) ===
# ... (same process)
```

### Rotation (every 11 months or on compromise)

1. Generate a new root CA key and self-signed cert (10-year validity).
2. Issue new leaf certs (1-year validity) signed by the new root.
3. Copy new `.crt` files to `update-server/ca/`, `update-server/certs/`, `deployment/ca/`.
4. Update `bootstrap.sh` with the new base64-encoded root CA.
5. Update system trust on every appliance (see `bootstrap.sh`).
6. Reload Caddy: `docker compose exec -T caddy caddy reload --config /etc/caddy/Caddyfile`
7. **Never rotate the private key into the repo.**

### Emergency recovery

If the private key is lost, you must regenerate everything and update trust
on all appliances. Keep the private key in a secure backup (e.g. encrypted
offline storage).

## Trust Distribution

| Mechanism | File | Updated By |
|-----------|------|------------|
| **bootstrap.sh** (embedded) | `NEOSECRA_CA_B64` variable | Manual on rotation |
| **deployment/ca** (bundled) | `deployment/ca/update-neosecra-com-root.crt` | Manual on rotation |
| **update-server/ca** (server-side) | `update-server/ca/update-neosecra-com-root.crt` | Manual on rotation |
| **System trust** | `/usr/local/share/ca-certificates/update-neosecra-com.crt` | `bootstrap.sh install_update_server_ca()` |

## Verification

```bash
# Without -k/insecure flag — uses system trust OR explicit --cacert:
curl -fsSL --cacert /etc/ssl/certs/update-neosecra-com.pem https://update.neosecra.com/channels/assessment-stable.json
curl -fsSL --cacert /etc/ssl/certs/update-neosecra-com.pem https://license.neosecra.com/
```

## Restart Test

```bash
docker compose restart caddy
curl -fsSL --cacert /opt/neosecra-update/ca/update-neosecra-com-root.crt https://update.neosecra.com/channels/assessment-stable.json \
  | python3 -c "import json,sys; print(json.load(sys.stdin).get('current_version','?'))"

docker compose restart caddy  # second restart
curl -fsSL --cacert /opt/neosecra-update/ca/update-neosecra-com-root.crt https://update.neosecra.com/channels/assessment-stable.json \
  | python3 -c "import json,sys; print(json.load(sys.stdin).get('current_version','?'))"
```

## CA Fingerprint (SHA256)

```
12:AB:2D:A6:0F:AA:AB:AC:EA:0A:C8:20:BF:FB:47:60:33:35:F5:9B:02:3E:3C:52:7D:37:46:70:8C:14:F7:8F
```

Verify with:
```bash
openssl x509 -in update-server/ca/update-neosecra-com-root.crt -fingerprint -sha256 -noout | cut -d= -f2
```
