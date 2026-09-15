"""Focused no-database-copy and migration metadata contract checks."""

from pathlib import Path

import json


ROOT = Path(__file__).resolve().parents[1]
UPDATER = ROOT / "deployment" / "v1" / "agent" / "hotspot-updater.sh"
AGENT = ROOT / "deployment" / "v1" / "agent" / "update-agent.sh"
PUBLISH = ROOT / "update-server" / "publish.sh"
SCHEMA = ROOT / "deployment" / "v1" / "schemas" / "release-manifest.schema.json"


def test_hotspot_updater_is_backup_free_and_pointer_only():
    source = UPDATER.read_text(encoding="utf-8")
    assert "normal Hotspot updates are backup-free" in source
    assert "BACKING_UP" not in source
    assert "pg_dump" not in source
    assert "psql" not in source
    assert "restore_database" not in source
    assert "POINTER_ONLY_ROLLBACK" in source
    assert "release-metadata" in source


def test_agent_passes_signed_migration_contract_to_hotspot_updater():
    source = AGENT.read_text(encoding="utf-8")
    assert "migration_contract" in source
    assert "release-metadata.json" in source
    assert "--release-metadata" in source
    assert "backup_path" in source


def test_publisher_requires_and_emits_hotspot_migration_contract():
    source = PUBLISH.read_text(encoding="utf-8")
    assert "--migration-metadata" in source
    assert "required for --product hotspot" in source
    assert "validate_hotspot_migration_metadata" in source
    assert 'new_rel["migration_contract"]' in source
    assert 'new_rel["backup_required"] = False' in source


def test_manifest_requires_backup_free_migration_fields():
    schema = json.loads(SCHEMA.read_text(encoding="utf-8"))
    upgrade = schema["properties"]["upgrade"]
    assert upgrade["properties"]["backup_required"] == {"const": False}
    assert {
        "migration_strategy",
        "backward_compatible_with_previous_app",
        "rollback_safe_without_db_restore",
        "migration_checksum",
        "schema_from",
        "schema_to",
        "estimated_lock_seconds",
        "estimated_temp_space_bytes",
    }.issubset(set(upgrade["required"]))
