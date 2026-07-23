# NeoSecra Security Health (V1) — Deployment Package

This directory ships the **V1 release package** for the NeoSecra Security
Health & Assessment product line. It is a **skeleton**: it isolates V1 from the
V2 MSSP SOC stack and provides safe, non-destructive lifecycle scaffolding.
The **full installer / upgrade / rollback / V1→V2 upgrade is a separate
workstream** and is NOT implemented here.

```
deployment/v1/
├── docker-compose.v1.yml     # isolated stack (project: neosecra-v1)
├── .env.v1.example           # environment template (placeholders only)
├── VERSION                   # 1.0.0
├── release-manifest.yaml     # package metadata (version, images, gates)
├── lib/common.sh             # shared helpers (sourced by scripts)
├── install/
│   ├── preflight.sh          # host readiness (Docker/Compose/ports/disk) — read-only
│   ├── install.sh            # bring-up (refuses without backup confirmation)
│   └── postflight.sh         # health + negative SOC/canonical gates (running stack)
├── upgrade/
│   ├── upgrade.sh            # procedure + preflight (non-applying skeleton)
│   ├── rollback.sh           # procedure (non-applying skeleton)
│   └── README.md
├── backup/
│   ├── backup.sh             # pg_dump (read-only) + MANIFEST
│   ├── restore.sh            # procedure (non-applying skeleton)
│   └── README.md
└── smoke-tests/
    └── verify-v1.sh          # package self-consistency + optional live checks
```

## Isolation contract (V1 vs V2)

| Namespace | V1 (this package) | V2 (separate) |
|---|---|---|
| Compose project | `neosecra-v1` | `neosecra-v2` |
| PostgreSQL | `neosecra-v1_pgdata` | `neosecra-v2_pgdata` |
| Redis | dedicated container | dedicated container |
| Network | `neosecra-v1_default` | `neosecra-v2_default` |
| Volumes | `neosecra-v1_*` | `neosecra-v2_*` |
| Env file | `.env.v1` | `.env.v2` |
| Ports | 23543 / 23639 / 23800 / 23300 | offset (e.g. 33xxx) |

V1 and V2 can run **side-by-side** without collision. See `release-manifest.yaml`
for the authoritative list.

## Quick start (skeleton)

```bash
cd deployment/v1
cp .env.v1.example .env.v1          # fill every CHANGE_ME with real secrets
install/preflight.sh                # host readiness (read-only)
backup/backup.sh --target /backups/v1-init   # MANDATORY before install
install/install.sh --confirm-backed-up       # bring the stack up
install/postflight.sh               # verify health + SOC-excluded negative gate
```

OpenVAS is optional and **off by default**:

```bash
install/install.sh --confirm-backed-up --profile openvas
```

## What is READY vs NOT (no false claims)

| Capability | Status |
|---|---|
| Isolated compose + env template + VERSION + manifest | ✅ READY |
| `preflight.sh` (read-only host checks) | ✅ READY |
| `verify-v1.sh` (package self-consistency) | ✅ READY |
| `backup.sh` (read-only pg_dump) | ✅ SAFE / runtime-not-verified |
| `install.sh` bring-up + `postflight.sh` | ⚠️ SKELETON / runtime-not-verified |
| `upgrade.sh` apply / `rollback.sh` restore | ❌ NOT IMPLEMENTED |
| Dev → production volume data migration | ❌ DEFERRED |
| V1 → V2 data upgrade | ❌ NOT IMPLEMENTED (see deployment/v2/) |

**Verdicts (reported separately in the split report):**
`V1_PACKAGE_SKELETON_READY` · `V1_INSTALLER_RUNTIME_NOT_VERIFIED` ·
`V1_TO_V2_UPGRADE_CONTRACT_READY` · `V1_TO_V2_UPGRADE_NOT_IMPLEMENTED`.

## Safety rules (enforced)

- **No destructive operations** in any script. No `down -v`, no `volume rm`,
  no prune, no migration rewrite, no history reset.
- **Existing volumes are preserved** — never wiped, never renamed.
- **Backup is mandatory** before install/upgrade (`install.sh` refuses without
  `--confirm-backed-up`).
- **Real secrets stay out of the release package** — `.env.v1` is gitignored;
  `.env.v1.example` contains placeholders only; secret generation is runtime.
- **Credential secrets are never written to plaintext** by these scripts.

## Data separation

This stack uses `neosecra-v1_*` volumes. They are **additive** — a prior dev
stack's volumes (`it-sec-platfrom_*`) are untouched, not renamed, not migrated.
Moving dev data into this production profile is an explicitly **deferred**
workstream (see `upgrade/README.md`). **Never** run `down -v` here.
