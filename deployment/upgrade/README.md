# V1 Upgrade & Rollback (Skeleton)

These scripts are **skeletons**. They document and preflight the upgrade and
rollback paths but do **not** apply them automatically.

| Script | Status | What it does |
|---|---|---|
| `upgrade.sh` | SKELETON (non-applying) | Reads version + state, validates config, prints the manual upgrade procedure. `--apply` is refused. |
| `rollback.sh` | SKELETON (non-applying) | Prints the manual rollback procedure. `--restore` is refused. |

## Why not automatic?

Upgrade/rollback touch the database (migrations) and swap images. Automating
that safely requires: version-aware migration planning, pre/post hooks,
verified-backup enforcement, and idempotent retry. That is a **separate
workstream** and is **not runtime-verified** (see `release-manifest.yaml` →
`package_status.upgrade_runtime_verified: false`, `rollback_supported: false`).

## Upgrade flow (manual, under DBA supervision)

```
1. backup/backup.sh --target <dir>          # mandatory, verify it restores
2. read target version + database_revision from release-manifest.yaml
3. docker compose --env-file .env.v1 -f docker-compose.v1.yml build
4. docker compose --env-file .env.v1 -f docker-compose.v1.yml exec backend alembic upgrade head
5. docker compose --env-file .env.v1 -f docker-compose.v1.yml up -d
6. install/postflight.sh
```

## Rollback flow (manual, destructive)

Only from a **verified pre-upgrade backup**:

```
1. docker compose --env-file .env.v1 -f docker-compose.v1.yml stop   # NO -v
2. restore DB from backup (pg_restore)
3. alembic downgrade <backup_revision>   # only if the failed upgrade advanced revision
4. revert images, then up -d
5. install/postflight.sh
```

## Data separation note

The V1 stack uses `neosecra-v1_*` volumes. Migrating data **from a prior dev
stack** (`it-sec-platfrom_*` volumes) into this production profile is **not**
performed by any script here and is **deferred**. Do it explicitly, off-hours,
with a verified backup, only after confirming schema compatibility
(`database_revision`).

Never run `down -v` against this stack — it destroys named volumes.
