#!/usr/bin/env bash
# neosecra backup — create a database backup (encrypted with age)
#
# Output in <target>/ (dir 0700, files 0600):
#   neosecra-<ver>-db.sql.gz.age       pg_dump | gzip | age   (never plaintext on disk)
#   neosecra-<ver>-config.tar.gz.age   compose snapshot, release manifest, env.v1,
#                                      versions — the secrets live ONLY in here
#   *.sha256                           sha256 of each encrypted artifact
#   MANIFEST                           metadata (no secrets)
# Everything is written as *.partial and renamed only when the whole backup
# succeeded; any failure removes what this run created.
#
# Encryption env (fail-closed; one is required):
#   BACKUP_AGE_RECIPIENT        single age recipient (public key)
#   BACKUP_AGE_RECIPIENTS_FILE  path to a recipients file
#   BACKUP_ALLOW_PLAINTEXT=1    explicit exception when no recipient is set:
#                               UNENCRYPTED backup, loud warning, ".PLAINTEXT" in names
set -uo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
V1_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${V1_ROOT}/lib/common.sh"
source "${V1_ROOT}/lib/state.sh"
umask 077

usage() { cat <<'EOF'
neosecra backup — create database and configuration backup (age-encrypted)
Usage: neosecra backup --target <dir> | --auto [--help]
Env:   BACKUP_AGE_RECIPIENT | BACKUP_AGE_RECIPIENTS_FILE  (required)
       BACKUP_ALLOW_PLAINTEXT=1  (explicit unencrypted exception)
EOF
}

TARGET=""; AUTO=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h)  usage; exit 0 ;;
    --target)   shift; TARGET="${1:-}" ;;
    --auto)     AUTO=1 ;;
    *) usage; die "unexpected argument: $1" 2 ;;
  esac
  shift
done

VERSION="$(read_version)"
if [[ $AUTO -eq 1 ]]; then
  STAMP=$(date -u +%Y%m%dT%H%M%SZ)
  TARGET="${BACKUP_ROOT}/${STAMP}-${VERSION}"
fi
[[ -n "$TARGET" ]] || { usage; die "--target or --auto required" 2; }

# --- Encryption mode: decided BEFORE anything is created ---
BACKUP_AGE_RECIPIENT="${BACKUP_AGE_RECIPIENT:-}"
BACKUP_AGE_RECIPIENTS_FILE="${BACKUP_AGE_RECIPIENTS_FILE:-}"
BACKUP_ALLOW_PLAINTEXT="${BACKUP_ALLOW_PLAINTEXT:-0}"
AGE_ARGS=(); ENCRYPT=0
[[ -z "$BACKUP_AGE_RECIPIENT" ]] || AGE_ARGS+=(-r "$BACKUP_AGE_RECIPIENT")
if [[ -n "$BACKUP_AGE_RECIPIENTS_FILE" ]]; then
  [[ -f "$BACKUP_AGE_RECIPIENTS_FILE" && -s "$BACKUP_AGE_RECIPIENTS_FILE" ]] \
    || die "BACKUP_AGE_RECIPIENTS_FILE is not a readable, non-empty file: ${BACKUP_AGE_RECIPIENTS_FILE}" 3
  AGE_ARGS+=(-R "$BACKUP_AGE_RECIPIENTS_FILE")
fi
if [[ ${#AGE_ARGS[@]} -gt 0 ]]; then
  ENCRYPT=1
  command -v age >/dev/null 2>&1 \
    || die "age is not installed but a recipient is configured; refusing to write an unencrypted backup (install package 'age')" 3
elif [[ "$BACKUP_ALLOW_PLAINTEXT" == "1" ]]; then
  warn "BACKUP_ALLOW_PLAINTEXT=1 -> this backup is NOT ENCRYPTED. Anyone who can read it obtains .env.v1 and the database. Configure BACKUP_AGE_RECIPIENT."
else
  die "No age recipient configured (set BACKUP_AGE_RECIPIENT or BACKUP_AGE_RECIPIENTS_FILE); refusing to create a backup. Explicit exception: BACKUP_ALLOW_PLAINTEXT=1" 3
fi
if [[ $ENCRYPT -eq 1 ]]; then
  DB_NAME_OUT="neosecra-${VERSION}-db.sql.gz.age"
  CFG_NAME_OUT="neosecra-${VERSION}-config.tar.gz.age"
else
  DB_NAME_OUT="neosecra-${VERSION}-db.PLAINTEXT.sql.gz"
  CFG_NAME_OUT="neosecra-${VERSION}-config.PLAINTEXT.tar.gz"
fi

# stdin -> stdout; fails when the stream is empty.
require_nonempty_stream() {
  local hex
  hex="$(dd bs=1 count=1 2>/dev/null | od -An -tx1 | tr -d ' \n')"
  [[ -n "$hex" ]] || return 1
  printf "\\x${hex}"
  cat
}
encrypt_stream() { if [[ $ENCRYPT -eq 1 ]]; then age "${AGE_ARGS[@]}"; else cat; fi; }
file_mode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null || echo "?"; }

# --- Target directory: 0700 (tighten a loose pre-existing one) ---
if [[ -d "$TARGET" ]]; then
  _m="$(file_mode "$TARGET")"
  [[ "$_m" == "700" ]] || warn "backup directory ${TARGET} had mode ${_m}; tightening to 0700"
else
  mkdir -p "$TARGET" || die "cannot create backup directory ${TARGET}" 12
fi
chmod 0700 "$TARGET" || die "backup directory permissions could not be secured" 12
TARGET="$(cd "$TARGET" && pwd)"

# --- Cleanup: staging dir + everything this run wrote unless it succeeded ---
STAGE=""; PARTIALS=()
cleanup() {
  [[ -z "$STAGE" ]] || rm -rf -- "$STAGE"
  local f
  for f in "${PARTIALS[@]:-}"; do [[ -z "$f" ]] || rm -f -- "$f"; done
  return 0
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

log "Backup -> ${TARGET} (version ${VERSION}, encrypted=${ENCRYPT})"

DB_PART="${TARGET}/${DB_NAME_OUT}.partial"
CFG_PART="${TARGET}/${CFG_NAME_OUT}.partial"
PARTIALS+=("$DB_PART" "$CFG_PART")

# --- Database dump: streamed pg_dump | gzip | age -> .partial ---
if stack_is_running; then
  PGUSER=$(env_value POSTGRES_USER neosecra)
  PGDB=$(env_value POSTGRES_DB neosecra_assessment)
  : > "$DB_PART"; chmod 0600 "$DB_PART"
  if run_compose exec -T postgres pg_dump -U "$PGUSER" -d "$PGDB" 2>/dev/null \
      | require_nonempty_stream | gzip -c | encrypt_stream > "$DB_PART"; then
    [[ -s "$DB_PART" ]] || die "pg_dump output is empty — refusing incomplete backup" 12
    ok "pg_dump: $(du -h "$DB_PART" | cut -f1)"
  else
    die "pg_dump failed (or empty output / encryption error) — refusing to report an incomplete backup" 12
  fi
else
  die "Stack not running — pg_dump could not be taken; refusing incomplete backup" 12
fi

# --- Config snapshot (staging is 0700, same filesystem, removed on exit) ---
STAGE="$(mktemp -d "${TARGET}/.staging.XXXXXX")" || die "cannot create staging directory" 12
chmod 0700 "$STAGE"
cp "$COMPOSE_FILE" "${STAGE}/docker-compose.snapshot.yml" 2>/dev/null || die "Compose snapshot failed" 12
cp "$MANIFEST_FILE" "${STAGE}/release-manifest.yaml" 2>/dev/null || die "Release manifest snapshot failed" 12
[[ -f "$ENV_FILE" && ! -L "$ENV_FILE" ]] || die ".env.v1 is missing or unsafe — refusing incomplete backup" 12
cp -a "$ENV_FILE" "${STAGE}/env.v1" 2>/dev/null || die "Environment snapshot failed" 12
chmod 0600 "${STAGE}/env.v1" || die "Environment snapshot permissions could not be secured" 12
echo "$VERSION" > "${STAGE}/source-version"
ACTIVE=$(read_installed_version 2>/dev/null || echo "?")
echo "$ACTIVE" > "${STAGE}/active-version"

: > "$CFG_PART"; chmod 0600 "$CFG_PART"
if ! tar -cf - -C "$STAGE" . | gzip -c | encrypt_stream > "$CFG_PART"; then
  die "config archive pipeline (tar/gzip/age) failed — refusing incomplete backup" 12
fi
[[ -s "$CFG_PART" ]] || die "config archive is empty — refusing incomplete backup" 12
ok "Config bundle (env.v1 + snapshots) packed$([[ $ENCRYPT -eq 1 ]] && echo ' and encrypted')"

# --- Checksums + manifest (each as .partial, then commit by rename) ---
DB_SHA="$(sha256sum "$DB_PART" | cut -d' ' -f1)"
CFG_SHA="$(sha256sum "$CFG_PART" | cut -d' ' -f1)"
printf '%s  %s\n' "$DB_SHA"  "$DB_NAME_OUT"  > "${DB_PART%.partial}.sha256.partial"
printf '%s  %s\n' "$CFG_SHA" "$CFG_NAME_OUT" > "${CFG_PART%.partial}.sha256.partial"
MAN_PART="${TARGET}/MANIFEST.partial"
PARTIALS+=("${DB_PART%.partial}.sha256.partial" "${CFG_PART%.partial}.sha256.partial" "$MAN_PART")
{
  echo "# NeoSecra Assessment backup manifest"
  echo "product: ${PRODUCT}"
  echo "edition: ${EDITION}"
  echo "version: ${VERSION}"
  echo "active_version: ${ACTIVE}"
  echo "backup_time: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "encrypted: $([[ $ENCRYPT -eq 1 ]] && echo age || echo NO)"
  echo "files:"
  echo "  - ${DB_NAME_OUT} (${DB_SHA})"
  echo "  - ${CFG_NAME_OUT} (${CFG_SHA})"
} > "$MAN_PART"
chmod 0600 "$DB_PART" "$CFG_PART" "$MAN_PART" "${DB_PART%.partial}.sha256.partial" "${CFG_PART%.partial}.sha256.partial" \
  || die "backup artifact permissions could not be secured" 12

for part in "${DB_PART%.partial}.sha256" "${CFG_PART%.partial}.sha256"; do
  mv -f "${part}.partial" "$part" || die "could not finalize ${part}" 12
done
mv -f "$DB_PART" "${TARGET}/${DB_NAME_OUT}" || die "could not finalize ${DB_NAME_OUT}" 12
mv -f "$CFG_PART" "${TARGET}/${CFG_NAME_OUT}" || die "could not finalize ${CFG_NAME_OUT}" 12
mv -f "$MAN_PART" "${TARGET}/MANIFEST" || die "could not finalize MANIFEST" 12
PARTIALS=()
ok "Backup manifest: ${TARGET}/MANIFEST"

ok "Backup complete -> ${TARGET}"
