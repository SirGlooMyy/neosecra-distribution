import pytest
import json
import os
import jsonschema
import copy
import shlex
import subprocess
from pathlib import Path

import yaml
from fixtures.publisher import BASH, posix

def test_release_manifest_compatibility_matrix():
    v1_root = os.path.join(os.path.dirname(__file__), "../deployment/v1")
    schema_path = os.path.join(v1_root, "schemas/release-manifest.schema.json")

    with open(schema_path) as f:
        schema = json.load(f)

    valid_manifest = {
        "product": "assessment",
        "edition": "standard",
        "version": "1.0.0",
        "trust_policy": "minisign-package-v1",
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


@pytest.mark.parametrize("policy", ["minisign-package-v1", "cosign-spdx-v1"])
def test_explicit_trust_policies_pass_schema(release_policy_manifests, policy):
    schema, backup, _ = release_policy_manifests
    backup["trust_policy"] = policy
    jsonschema.validate(backup, schema)


@pytest.mark.parametrize("policy", [None, "fallback", "", 1])
def test_missing_or_invalid_trust_policy_fails_schema(release_policy_manifests, policy):
    schema, backup, _ = release_policy_manifests
    if policy is None:
        del backup["trust_policy"]
    else:
        backup["trust_policy"] = policy
    with pytest.raises(jsonschema.ValidationError):
        jsonschema.validate(backup, schema)


@pytest.mark.parametrize("policy", [None, "minisign-package-v1", "cosign-spdx-v1", "fallback"])
def test_upgrade_manifest_policy_without_registry(tmp_path, policy):
    if not BASH or not Path(BASH).is_file():
        pytest.skip("Git Bash/bash is unavailable")
    root = Path(__file__).resolve().parents[1]
    source = (root / "deployment/v1/upgrade/upgrade.sh").read_text(encoding="utf-8")
    function = "enforce_image_security() {\n" + source.split("enforce_image_security() {\n", 1)[1].split("\n# Every Compose service", 1)[0]
    runtime = tmp_path / "customer/deployment/v1"
    (runtime / "agent").mkdir(parents=True)
    (runtime / "upgrade").mkdir()
    (runtime / "agent/artifact-verifier.sh").write_text("# fixture\n", encoding="utf-8", newline="\n")
    manifest = runtime / "release-manifest.yaml"
    manifest.write_text("version: 1.0.0\n" + ("" if policy is None else "trust_policy: " + policy + "\n"), encoding="utf-8", newline="\n")
    env_file = tmp_path / "fixture-env"
    env_file.write_bytes(b"fixture-unchanged\n")
    script = "\n".join([
        "set -euo pipefail",
        "source " + shlex.quote(posix(root / "deployment/v1/lib/manifest.sh")),
        "V1_ROOT=" + shlex.quote(posix(runtime)),
        'UPGRADE_SCRIPT_DIR="$V1_ROOT/upgrade"; RECOVERY_ROOT="$V1_ROOT"',
        "MANIFEST_FILE=" + shlex.quote(posix(manifest)),
        "ENV_FILE=" + shlex.quote(posix(env_file)),
        "NEOSECRA_PRODUCT=assessment; NEOSECRA_EXPECTED_CHANNEL=assessment-stable; CHANNEL_URL=; CHANNEL_JSON=; TARGET=1.0.0",
        "NEOSECRA_REQUIRE_PLATFORM_MANIFEST=0; NEOSECRA_PLATFORM_MANIFEST=; NEOSECRA_COSIGN_PUBKEY=",
        'die() { echo "$1" >&2; exit "${2:-1}"; }',
        "ok() { :; }; run_compose() { echo '{}'; }",
        # Only mapping/host commands are doubled; execute the real policy gate.
        'python3() { [[ "$1" == "$V1_ROOT/upgrade/verify_mapping.py" ]]; }',
        function, "enforce_image_security 0",
    ])
    result = subprocess.run([str(BASH), "--noprofile", "--norc", "-s"], input=script, capture_output=True, text=True, timeout=30)
    assert env_file.read_bytes() == b"fixture-unchanged\n"
    assert not Path(str(env_file) + ".bak").exists()
    if policy is None:
        assert result.returncode == 4, result.stdout + result.stderr
        assert "Missing trust_policy in release-manifest.yaml" in result.stderr
        assert "no product registry is installed" in result.stderr
        assert "obtain a newly signed release package" in result.stderr
        assert "Do not edit the installed signed manifest" in result.stderr
    elif policy == "fallback":
        assert result.returncode == 4
        assert "unsupported product trust policy" in result.stderr
    else:
        assert result.returncode == 0, result.stdout + result.stderr
