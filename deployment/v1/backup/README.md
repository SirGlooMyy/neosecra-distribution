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
- Output contains `neosecra-<version>-db.sql.gz.age`,
  `neosecra-<version>-config.tar.gz.age`, checksums and `MANIFEST`.
- Configure `age` and `BACKUP_AGE_RECIPIENT` or `BACKUP_AGE_RECIPIENTS_FILE`.
  Missing encryption settings or a stopped stack fail closed.

## What is NOT in a backup (on purpose)

- `.env.v1` and configuration snapshots are included only in the encrypted
  config bundle; they are not published as plaintext backup artifacts.
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

## Signed backup-restore rollback

`upgrade/rollback.sh --to <version> --auth <signed-auth.json>` locates the newest
`${BACKUP_ROOT}/*-<version>` pre-upgrade backup. `--from-backup <dir>` selects the
operator/upgrade-provided directory; product trigger files cannot select it.
Encrypted DB dumps take precedence over old `*-db.sql` dumps, which remain
readable with a legacy plaintext warning.

For encrypted dumps, `BACKUP_AGE_IDENTITY_FILE` must name a regular non-symlink
file with mode 0600 and root-only access. Decryption/decompression and a nonempty
SQL stream are verified before any changes, including in `--dry-run`. Before
stopping services, rollback calls `backup.sh` for an encrypted safety backup;
it requires the recipient setting even when restoring a legacy dump. SQL is
decrypted directly into strict `psql` replay, never into a plaintext file.
Missing/unsafe identity, missing `age`, unreadable dumps or failed safety backup
stop rollback before service shutdown or schema reset. Keep the on-device
identity root-only: encryption protects copies exported off-device.

## Rotation

This skeleton does not manage retention. Keep backups off-host and rotate per
your policy. Never store backups on the same volume as the live database.
