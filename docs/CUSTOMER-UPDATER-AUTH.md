# Customer Updater Authentication

## Required Tokens

Two separate tokens must be provisioned for each customer installation.

### Token 1: GHCR Read

- Type: Classic PAT
- Scope: `read:packages`
- Expiration: 90 days
- Purpose: Pull Docker images

### Token 2: Distribution Read

- Type: Fine-grained PAT
- Repository: `SirGlooMyy/neosecra-distribution`
- Permission: `Contents: read`
- Expiration: 90 days
- Purpose: Download release metadata and bundles

## Installation

```bash
sudo mkdir -p /etc/neosecra/credentials
sudo chmod 0700 /etc/neosecra/credentials

# Install GHCR token
sudo install -m 600 /dev/stdin /etc/neosecra/credentials/ghcr-read-token
sudo chmod 0600 /etc/neosecra/credentials/ghcr-read-token

# Install distribution token
sudo install -m 600 /dev/stdin /etc/neosecra/credentials/release-read-token
sudo chmod 0600 /etc/neosecra/credentials/release-read-token
```

## Verification

```bash
# Test GHCR pull
cat /etc/neosecra/credentials/ghcr-read-token | \
  docker login ghcr.io --username token --password-stdin
docker pull ghcr.io/sirgloomyy/neosecra-assessment-backend:1.0.0

# Test distribution access
token=$(cat /etc/neosecra/credentials/release-read-token)
curl -s -H "Authorization: token $token" \
  "https://api.github.com/repos/SirGlooMyy/neosecra-distribution/releases/latest"
```

## Token Rotation

See TOKEN-ROTATION.md for rotation procedures.
