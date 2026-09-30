#!/usr/bin/env bash
# NeoSecra V1 — restore (SKELETON, non-applying) with backup VERIFICATION.
#
# DEFAULT = VERIFY ONLY: checks every artifact's .sha256, then fully decrypts
# (age) the DB dump and the config bundle into pipes (nothing written to disk)
# and prints the manual restore procedure.
#
# It does NOT reload the database — restore is destructive (overwrites live
# data) and is a separate, not-yet-implemented workstream. --confirm is
# intentionally refused after verification.
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
V1_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=lib/common.sh
source "${V1_ROOT}/lib/common.sh"
umask 077

usage() {
  cat <<EOF
NeoSecra V1 restore — verify + procedure (SKELETON, non-applying).

Usage:
  restore.sh --target <backup-dir>                     Verify backup (sha256 + age decrypt) + print procedure.
  restore.sh --target <backup-dir> --legacy-plaintext  Same for old, unencrypted backups (*.sql).
  restore.sh --target <backup-dir> --confirm           ATTEMPT restore — currently REFUSED.
  restore.sh --help

Env: BACKUP_AGE_IDENTITY_FILE = age private identity file (mode 0600), required
     for encrypted backups. Keep it off the backup host.

Restore overwrites live database data. This skeleton refuses to perform it
automatically. Perform the steps below manually under DBA supervision, only
from a verified backup.
EOF
}

TARGET=""; CONFIRM=0; LEGACY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h)          usage; exit 0 ;;
    --target)           shift; TARGET="${1:-}" ;;
    --confirm)          CONFIRM=1 ;;
    --legacy-plaintext) LEGACY=1 ;;
    *) usage; die "unexpected argument: $1" 2 ;;
  esac
  shift
done

[[ -n "$TARGET" ]] || { usage; die "--target <backup-dir> is required" 2; }
[[ -d "$TARGET" ]] || die "backup directory not found: $TARGET" 2

VERSION="$(read_version)"
log "NeoSecra V1 restore inspection — backup dir ${TARGET} (installed version ${VERSION})"

MANIFEST="${TARGET}/MANIFEST"
if [[ -f "$MANIFEST" ]]; then
  ok "backup MANIFEST found:"
  sed 's/^/    /' "$MANIFEST" >&2
else
  warn "no MANIFEST in ${TARGET} — provenance unknown, proceed with extreme caution."
fi

first_match() {  # first_match <glob-pattern> -> prints one path or nothing
  local f
  for f in "${TARGET}"/$1; do [[ -f "$f" ]] && { printf '%s\n' "$f"; return 0; }; done
  return 0
}

verify_sha256() {
  local f="$1" shaf="${1}.sha256" expected actual
  actual="$(sha256sum "$f" | cut -d' ' -f1)"
  if [[ -f "$shaf" ]]; then
    expected="$(awk 'NR==1{print $1}' "$shaf" | tr -d '[:space:]')"
  elif [[ $LEGACY -eq 1 && -f "$MANIFEST" ]]; then
    expected="$(grep -F "$(basename "$f") (" "$MANIFEST" | sed -E 's/.*\(([0-9a-f]{64})\).*/\1/' | head -1 || true)"
    if [[ -z "$expected" ]]; then
      warn "no checksum recorded for $(basename "$f"); legacy backup integrity cannot be verified"
      return 0
    fi
  elif [[ $LEGACY -eq 1 ]]; then
    warn "no checksum for $(basename "$f"); legacy backup integrity cannot be verified"
    return 0
  else
    die "missing checksum file: ${shaf}" 4
  fi
  [[ -n "$expected" && "$expected" == "$actual" ]] \
    || die "SHA256 MISMATCH for $(basename "$f"): backup corrupt or tampered; nothing was restored" 4
  ok "sha256 verified: $(basename "$f")"
}

identity_mode_ok() {
  local f="$1" mode probe pm
  mode="$(stat -c '%a' "$f" 2>/dev/null || stat -f '%Lp' "$f" 2>/dev/null || echo "")"
  [[ -n "$mode" ]] || return 1
  if [[ $(( 8#$mode & 8#077 )) -eq 0 ]]; then return 0; fi
  probe="$(mktemp "$(dirname "$f")/.permprobe.XXXXXX" 2>/dev/null)" || return 1
  chmod 0600 "$probe" 2>/dev/null || true
  pm="$(stat -c '%a' "$probe" 2>/dev/null || echo "")"
  rm -f -- "$probe"
  if [[ "$pm" != "600" ]]; then
    warn "filesystem does not enforce POSIX modes; identity file permissions cannot be verified"
    return 0
  fi
  return 1
}

DB_ART="$(first_match 'neosecra-*-db.sql.gz.age')"
CFG_ART="$(first_match 'neosecra-*-config.tar.gz.age')"
PLAIN_DB=""; PLAIN_CFG=""

if [[ -n "$DB_ART" ]]; then
  [[ $LEGACY -eq 0 ]] || die "--legacy-plaintext given but the backup is age-encrypted" 2
  [[ -n "$CFG_ART" ]] || die "config bundle (neosecra-*-config.tar.gz.age) is missing — incomplete backup" 4
  require_cmd age
  [[ -n "${BACKUP_AGE_IDENTITY_FILE:-}" ]] || die "BACKUP_AGE_IDENTITY_FILE is not set" 3
  [[ -f "$BACKUP_AGE_IDENTITY_FILE" ]] || die "identity file not found: ${BACKUP_AGE_IDENTITY_FILE}" 3
  identity_mode_ok "$BACKUP_AGE_IDENTITY_FILE" \
    || die "identity file ${BACKUP_AGE_IDENTITY_FILE} must be mode 0600 (chmod 600); refusing" 3

  verify_sha256 "$DB_ART"
  verify_sha256 "$CFG_ART"

  if ! DB_BYTES="$( set -o pipefail; age -d -i "$BACKUP_AGE_IDENTITY_FILE" "$DB_ART" | gunzip -c | wc -c )"; then
    die "DB dump decrypt/decompress failed (wrong identity or corrupt backup); nothing was restored" 4
  fi
  [[ "${DB_BYTES:-0}" -gt 0 ]] || die "DB dump decodes to an empty stream" 4
  if ! CFG_LIST="$( set -o pipefail; age -d -i "$BACKUP_AGE_IDENTITY_FILE" "$CFG_ART" | tar -tzf - )"; then
    die "config bundle decrypt/read failed; nothing was restored" 4
  fi
  printf '%s\n' "$CFG_LIST" | grep -q 'env.v1$' || die "config bundle lacks env.v1 — incomplete backup" 4
  ok "encrypted backup verified: dump ${DB_BYTES} bytes, config bundle readable"
else
  # No encrypted artifact: only acceptable with the explicit legacy flag.
  [[ $LEGACY -eq 1 ]] || die "no age-encrypted backup found in ${TARGET}; old/unencrypted backups need the explicit --legacy-plaintext flag" 2
  PLAIN_DB="$(first_match 'neosecra-*-db.sql')"
  [[ -n "$PLAIN_DB" ]] || PLAIN_DB="$(first_match 'neosecra-*-db.PLAINTEXT.sql.gz')"
  [[ -n "$PLAIN_DB" ]] || die "no pg_dump artifact (*-db.sql / *-db.PLAINTEXT.sql.gz) found in ${TARGET}" 4
  verify_sha256 "$PLAIN_DB"
  warn "legacy/plaintext backup: $(basename "$PLAIN_DB") is NOT encrypted — re-encrypt or securely delete it (see docs/BACKUP-RESTORE.md)"
  ok "pg_dump file present in ${TARGET}"
fi

if [[ $CONFIRM -eq 1 ]]; then
  err "restore --confirm is NOT IMPLEMENTED in this skeleton."
  err "Restoring overwrites live data: stop services -> drop/reload DB (pg_restore)"
  err "  -> optional alembic downgrade -> restart -> postflight, under DBA review."
  die "refusing to restore (skeleton; restore NOT runtime-verified)" 1
fi

cat <<EOF

=== NeoSecra V1 restore procedure (MANUAL — destructive, DBA supervision) ===

PRECONDITION: the stack is STOPPED and a verified backup exists in ${TARGET}.
              The age identity (private key) is supplied by the operator only
              for this step; it is not stored on the backup host.

1. Stop services (NO -v):
     run_compose stop

2. Reload the database from the (decrypted, streamed) dump:
     age -d -i "\$BACKUP_AGE_IDENTITY_FILE" ${TARGET}/neosecra-*-db.sql.gz.age | gunzip -c | \\
       run_compose exec -T postgres psql -U <POSTGRES_USER> -d <POSTGRES_DB>
   (Reload into an isolated instance first to validate before touching
    production. Legacy plaintext: psql ... < ${TARGET}/neosecra-*-db.sql)

3. If the backup revision differs from the running one, align with alembic.

4. Start + verify:
     run_compose up -d
     bash ${V1_ROOT}/install/postflight.sh
==============================================================================
EOF

ok "restore procedure printed. No changes were made."
warn "restore application is NOT implemented in this skeleton (V1_RESTORE_NOT_IMPLEMENTED)."
