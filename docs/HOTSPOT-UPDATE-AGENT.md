# NeoSecra Hotspot update-agent

The Assessment and Hotspot products share the signed channel and trigger
contract, but they do not share a Compose project, database volume, or systemd
unit. Install the Hotspot flavour on the customer host with:

```bash
sudo deployment/v1/agent/install-hotspot-agent.sh \
  --hotspot-root /opt/neosecra/hotspot \
  --backend-uid 1000:1000
```

The installer creates:

* `/opt/neosecra/hotspot/state/upgrade-bridge/trigger` (API writable)
* `/opt/neosecra/hotspot/state/upgrade-bridge/journal` (agent writable/API read-only)
* `/opt/neosecra/hotspot/state/upgrade-bridge/agent-alive`
* `neosecra-hotspot-update-agent.path` and heartbeat timer units
* `/opt/neosecra/hotspot/update-agent/artifact-verifier.sh` (SHA-256/minisign helpers)

The API writes `upgrade-request.json` only after local license entitlement,
channel signature, target version, and heartbeat checks pass. The host agent
downloads and verifies `archive.sha256` plus `archive.minisig`, then invokes the
fixed Hotspot updater. No trigger field is treated as a shell command.

## Host layout

The updater expects the current Hotspot release at `/opt/neosecra/hotspot/current`
and keeps immutable releases under `/opt/neosecra/hotspot/releases/<version>`.
The current `backend/.env` is copied into each staged release; secrets are not
part of the signed archive. Compose project name is `neosecra-hotspot` and its
named volumes remain isolated from Assessment.

## Release contract

The `hotspot-stable` channel must identify canonical `product_code: hotspot`
and an edition of `standard` or `enterprise`. Every release needs:

* semver `version` and `minimum_current_version`;
* `archive.url`, `archive.sha256`, and a minisign signature at
  `archive.url + .minisig`;
* a source archive containing `docker-compose.yml`, `backend/.env.example`,
  `backend/`, `frontend/admin/`, and `frontend/portal/`.

The checked-in channel is `unavailable` until a signed Hotspot artifact is
published. This prevents the UI from advertising an unverified or Assessment
artifact. Runtime compatibility aliases such as `neosecra-hotspot` are accepted
only while normalizing legacy installation configuration.
