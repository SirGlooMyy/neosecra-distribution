# V1 Backup & Restore (Skeleton)

| Script | Status | What it does |
|---|---|---|
| `backup.sh` | SAFE / read-only | Runs `pg_dump` on the running V1 DB and writes a checksummed `MANIFEST`. Does **not** modify data. |
| `restore.sh` | SKELETON (non-applying) | Inspects a backup and prints the manual restore procedure. `--confirm` is refused. |

## Backup

```
backup/backup.sh --target /backups/neosecra-v1-<date>
```

- `pg_dump` is **read-only** — safe to run against a live stack.
- Output dir contains `neosecra-v1-<version>-db.sql` + `MANIFEST` (version,
  timestamp, file list, sha256).
- If the stack is not running, only the `MANIFEST` is written.

## What is NOT in a backup (on purpose)

- `.env.v1` and raw secrets — **never** included.
- Volume/file snapshots (`uploads`, `reports`) — **not** auto-archived by this
  skeleton. Snapshot them separately if needed (e.g. `docker run --rm -v
  neosecra-v1_uploads:/d -v "$PWD:/o" alpine tar czf /o/uploads.tgz -C /d .`).
- Restore is **not implemented** — see `restore.sh`.

## Restore (manual, destructive)

```
restore/restore.sh --target <backup-dir>          # inspect + print steps
# then perform the DB reload manually under DBA supervision
```

Always validate a backup by restoring into an **isolated** instance before
relying on it for production rollback.

## Rotation

This skeleton does not manage retention. Keep backups off-host and rotate per
your policy. Never store backups on the same volume as the live database.
