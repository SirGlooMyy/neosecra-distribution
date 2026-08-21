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
bootstrap.sh      Customer install entry point
deployment/       Customer deployment tree (install/upgrade/backup scripts)
deployment/v1/    Shipped v1 deployment — SOURCE OF TRUTH (see below)
schemas/          JSON Schemas for release/channel/revocation manifests
channels/         Channel manifests listing available releases
public-keys/      Public verification keys (signing, when implemented)
update-server/    Update server (Caddy, publish.sh, www/channels staging)
docs/             Customer updater documentation
```

## Customer deployment source of truth

`deployment/v1/` in THIS repository is the shipped source of truth for what
customers install and run. The sibling `neosecra-assessment` repo carries a
development copy of the same tree; changes that must reach customers are
ported here and released through `bootstrap.sh` / the update channel.

### Update agent (one-click upgrade)

New installs get the host-side update agent by default
(`NEOSECRA_INSTALL_UPDATE_AGENT=1`; set to `0` to opt out). The installer
runs `deployment/v1/agent/install-agent.sh`, which:

- creates `/opt/neosecra/assessment/state/upgrade-bridge/{trigger,journal}`
- installs and enables `neosecra-update-agent.{path,service}` and
  `neosecra-update-agent-heartbeat.{timer,service}` under systemd
- is idempotent — re-running refreshes units/dirs without breaking state

The backend container talks to the agent through the upgrade-bridge bind
mounts in `deployment/v1/docker-compose.v1.yml` (trigger RW, journal and
`agent-alive` heartbeat RO) plus the `UPGRADE_EXECUTION_PROVIDER=AGENT` env
block.

**Journal contract:** `upgrade.sh`/`rollback.sh` write their journals to
`/opt/neosecra/assessment/upgrade-journal/` on the host. After each run the
agent copies the produced `upgrade-*.json` / `rollback-*.json` into the
bridge journal dir (`state/upgrade-bridge/journal/`), which the backend
reads via its `/upgrade-bridge/journal` mount. `agent-status.json` is
written directly into the bridge journal dir by the agent.

## Access

- **Source repositories**: No customer access
- **Distribution repository**: Customer `Contents: read` only
- **GHCR packages**: Customer `read:packages` only

See `docs/CUSTOMER-UPDATER-AUTH.md` for credential requirements.

## Release Gate (zorunlu)

**Her yayın, publish edilmeden önce `bin/prerelease-gate.sh` ile temiz bir
VM üzerinde geçmelidir.** Gate, hedef VM'e yayınlanmış `bootstrap.sh`'i SSH ile
çalıştırır ve kurulum sonrası 7 container'ın ayakta olduğunu, `.env.v1`'de
lisans/kanal/admin değerlerinin bulunduğunu, backend health/version/login ve
openvas readiness uç noktalarının doğru yanıt verdiğini, loglarda kanal hatası
olmadığını ve veritabanı yedeklenebilirliğini doğrular. Herhangi bir madde
FAIL dönerse gate exit 1 ile başarısız olur ve publish yapılmamalıdır:

```bash
bin/prerelease-gate.sh --host root@<temiz-vm>        # bootstrap + tüm kontroller
bin/prerelease-gate.sh --host root@<temiz-vm> --dry-run   # komut/kontrol önizleme
```
