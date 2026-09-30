import pytest
import json
import os
import jsonschema
import copy
from pathlib import Path

import yaml

def test_release_manifest_compatibility_matrix():
    v1_root = os.path.join(os.path.dirname(__file__), "../deployment/v1")
    schema_path = os.path.join(v1_root, "schemas/release-manifest.schema.json")

    with open(schema_path) as f:
        schema = json.load(f)

    valid_manifest = {
        "product": "assessment",
        "edition": "standard",
        "version": "1.0.0",
        "release_channel": "stable",
        "git_commit": "abcdef1234567",
        "build_date": "2026-08-31T00:00:00Z",
        "target_database_revision": "head",
        "images": {
            "backend": {"reference": "a", "digest": "sha256:0000000000000000000000000000000000000000000000000000000000000000"},
            "frontend": {"reference": "a", "digest": "sha256:0000000000000000000000000000000000000000000000000000000000000000"}
        },
        "upgrade": {
            "backup_required": False,
            "migration_required": False,
            "migration_strategy": "off",
            "backward_compatible_with_previous_app": True,
            "rollback_safe_without_db_restore": True,
            "migration_checksum": None,
            "schema_from": None,
            "schema_to": None,
            "estimated_lock_seconds": 0,
            "estimated_temp_space_bytes": 0,
        },
        "rollback": {"database_strategy": "none"},
        "compatibility": {
            "product": "assessment",
            "edition": "standard",
            "version_line": "1.x"
        }
    }

    jsonschema.validate(instance=valid_manifest, schema=schema)

    invalid_manifest = dict(valid_manifest)
    invalid_manifest["compatibility"] = {
        "product": "assessment",
        "edition": "standard",
        "version_line": "2.0.0" # invalid pattern
    }

    with pytest.raises(jsonschema.ValidationError):
        jsonschema.validate(instance=invalid_manifest, schema=schema)


@pytest.fixture
def release_policy_manifests():
    root = Path(__file__).resolve().parents[1] / "deployment" / "v1"
    schema = json.loads((root / "schemas/release-manifest.schema.json").read_text(encoding="utf-8"))
    backup = yaml.safe_load((root / "release-manifest.yaml").read_text(encoding="utf-8"))
    pointer = copy.deepcopy(backup)
    pointer["product"] = "hotspot"
    pointer["edition"] = "hotspot"
    pointer["upgrade"] = {
        "backup_required": False,
        "migration_required": False,
        "migration_strategy": "off",
        "backward_compatible_with_previous_app": True,
        "rollback_safe_without_db_restore": True,
        "migration_checksum": None,
        "schema_from": None,
        "schema_to": None,
        "estimated_lock_seconds": 0,
        "estimated_temp_space_bytes": 0,
    }
    pointer["rollback"]["database_strategy"] = "none"
    return schema, backup, pointer


def test_both_product_policies_and_legacy_default(release_policy_manifests):
    schema, backup, pointer = release_policy_manifests
    jsonschema.Draft7Validator.check_schema(schema)
    for manifest in (backup, pointer):
        jsonschema.validate(manifest, schema)
    legacy = copy.deepcopy(backup)
    del legacy["rollback"]["database_strategy"]
    jsonschema.validate(legacy, schema)


@pytest.mark.parametrize("policy,backup_required", [("none", True), ("backup_restore", False), (None, False), ("downgrade", False)])
def test_inconsistent_policy_is_rejected(release_policy_manifests, policy, backup_required):
    schema, _, pointer = release_policy_manifests
    pointer["upgrade"]["backup_required"] = backup_required
    if policy is None:
        del pointer["rollback"]["database_strategy"]
    else:
        pointer["rollback"]["database_strategy"] = policy
    with pytest.raises(jsonschema.ValidationError):
        jsonschema.validate(pointer, schema)


@pytest.mark.parametrize("field", ["migration_strategy", "backward_compatible_with_previous_app", "rollback_safe_without_db_restore", "migration_checksum", "schema_from", "schema_to", "estimated_lock_seconds", "estimated_temp_space_bytes"])
def test_pointer_policy_requires_migration_metadata(release_policy_manifests, field):
    schema, _, pointer = release_policy_manifests
    del pointer["upgrade"][field]
    with pytest.raises(jsonschema.ValidationError):
        jsonschema.validate(pointer, schema)


def test_pointer_policy_requires_safe_migrations(release_policy_manifests):
    schema, _, pointer = release_policy_manifests
    pointer["upgrade"].update(migration_required=True, migration_strategy="additive", migration_checksum="a" * 64, schema_from="old", schema_to="new")
    jsonschema.validate(pointer, schema)
    for change in ({"migration_strategy": "offline"}, {"backward_compatible_with_previous_app": False}, {"rollback_safe_without_db_restore": False}, {"migration_checksum": None}, {"schema_from": ""}):
        invalid = copy.deepcopy(pointer)
        invalid["upgrade"].update(change)
        with pytest.raises(jsonschema.ValidationError):
            jsonschema.validate(invalid, schema)
