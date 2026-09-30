import json
import re
import sys

path = sys.argv[1]
try:
    with open(path, encoding="utf-8") as stream:
        data = json.load(stream)
except (OSError, UnicodeError, ValueError, TypeError) as exc:
    raise SystemExit(f"[ERROR] invalid product migration metadata: {exc}")
if not isinstance(data, dict):
    raise SystemExit("[ERROR] product migration metadata must be a JSON object")
required = {
    "migration_required", "migration_strategy",
    "backward_compatible_with_previous_app", "rollback_safe_without_db_restore",
    "migration_checksum", "schema_from", "schema_to",
    "estimated_lock_seconds", "estimated_temp_space_bytes",
}
missing = sorted(required - set(data))
if missing:
    raise SystemExit("[ERROR] product migration metadata missing: " + ",".join(missing))
for key in ("migration_required", "backward_compatible_with_previous_app", "rollback_safe_without_db_restore"):
    if not isinstance(data[key], bool):
        raise SystemExit(f"[ERROR] product migration metadata {key} must be boolean")
if data["migration_strategy"] not in {"off", "additive", "expand-contract", "offline"}:
    raise SystemExit("[ERROR] product migration_strategy is invalid")
for key in ("estimated_lock_seconds", "estimated_temp_space_bytes"):
    if isinstance(data[key], bool) or not isinstance(data[key], int) or data[key] < 0:
        raise SystemExit(f"[ERROR] product migration metadata {key} must be a non-negative integer")
checksum = data["migration_checksum"]
if checksum is not None and not re.fullmatch(r"[0-9a-fA-F]{64}", str(checksum)):
    raise SystemExit("[ERROR] product migration_checksum must be a 64-character SHA-256 or null")
if data["migration_required"]:
    if data["migration_strategy"] not in {"additive", "expand-contract"}:
        raise SystemExit("[ERROR] product migrations must use additive or expand-contract strategy")
    if not data["backward_compatible_with_previous_app"] or not data["rollback_safe_without_db_restore"]:
        raise SystemExit("[ERROR] product migration release is not backward-compatible/rollback-safe")
    if not checksum or not data["schema_from"] or not data["schema_to"]:
        raise SystemExit("[ERROR] product migration release requires checksum and schema_from/schema_to")
else:
    if data["migration_strategy"] != "off" or checksum is not None or data["schema_from"] is not None or data["schema_to"] is not None:
        raise SystemExit("[ERROR] migration-free product release must use strategy=off and null migration identity")
    if not data["backward_compatible_with_previous_app"] or not data["rollback_safe_without_db_restore"]:
        raise SystemExit("[ERROR] migration-free product release must remain rollback-safe")
if data.get("backup_required") not in (None, False):
    raise SystemExit("[ERROR] product migration metadata cannot enable database backups")
from channel import merge_extra
merge_extra(sys.argv[2], {"migration_contract": data, "backup_required": False, "migrations": bool(data["migration_required"]), "rollback_supported": bool(data["rollback_safe_without_db_restore"])})
