import json
import os
import subprocess
import jsonschema
from jsonschema import Draft7Validator, FormatChecker
import pytest

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCHEMA_PATH = os.path.join(REPO_ROOT, "schemas", "platform-release-manifest.schema.json")
CHANNELS_DIR = os.path.join(REPO_ROOT, "channels")


@pytest.fixture
def platform_manifest_schema():
    with open(SCHEMA_PATH, "r", encoding="utf-8") as f:
        return json.load(f)


@pytest.fixture
def valid_manifest_sample():
    return {
        "schema_version": 1,
        "platform_version": "1.4.0",
        "release_id": "123e4567-e89b-12d3-a456-426614174000",
        "released_at": "2026-08-30T20:00:00Z",
        "channel": "stable",
        "min_supported_version": "1.2.0",
        "components": {
            "assessment": {
                "version": "1.3.53",
                "commit_hash": "ad7893af6993caca52d6c1e6e784093894f070fd",
                'images': {'backend': {'reference': 'registry.neosecra.com/backend', 'digest': 'sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'}},
                "migration_head": "063_add_finding_closure_workflow",
                "health_gate_endpoint": "/api/v1/health",
            },
            "soc": {
                "version": "1.0.0",
                "commit_hash": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
                'images': {'backend': {'reference': 'registry.neosecra.com/backend', 'digest': 'sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'}},
                "migration_head": "093_forced_rls",
                "health_gate_endpoint": "/api/v1/health",
            },
            "hotspot": {
                "version": "0.3.6",
                "commit_hash": "c6bc42c2925b760455ebb9718b8a4110225af979",
                'images': {'backend': {'reference': 'registry.neosecra.com/backend', 'digest': 'sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'}},
                "migration_head": "012_hotspot_tables",
                "health_gate_endpoint": "/health",
            },
            "pish": {
                "version": "1.0.0",
                "commit_hash": "3e6d5343e6d5343e6d5343e6d5343e6d5343e6d5",
                'images': {'backend': {'reference': 'registry.neosecra.com/backend', 'digest': 'sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'}},
                "migration_head": "008_phish_events",
                "health_gate_endpoint": "/health",
            },
            "license": {
                "version": "1.0.0",
                "commit_hash": "f69b72d824b95f6953ab340c10133353bfb4101f",
                'images': {'backend': {'reference': 'registry.neosecra.com/backend', 'digest': 'sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'}},
                "migration_head": "005_license_authority",
                "health_gate_endpoint": "/health",
            },
            "distribution": {
                "version": "1.0.0",
                "commit_hash": "5172329d404ccb6f19331201aa52c460b6ac63ec",
                'images': {'backend': {'reference': 'registry.neosecra.com/backend', 'digest': 'sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'}},
                "migration_head": "none",
                "health_gate_endpoint": "/channels/assessment-stable.json",
            },
        },
        "signatures": {
            "sha256_checksum": "1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef",
            "minisign_signature": "untrusted comment: signature\nRW12345678901234567890123456789012",
        },
        "attestations": {
            "cosign_attestation_type": "https://cosign.sigstore.dev/attestation/v1",
            "verifier_chain": "neosecra-root-ca",
        },
        "sbom": {
            "format": "SPDX-2.3-JSON",
            "uri": "https://update.neosecra.com/releases/1.4.0/sbom.spdx.json",
            "sha256": "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
        },
        "rollback_plan": {
            "supported_rollback_version": "1.3.29",
            "database_strategy": "backup_restore",
            "automatic_on_health_failure": True,
        },
    }


def test_platform_release_manifest_schema_validity(platform_manifest_schema):
    Draft7Validator.check_schema(platform_manifest_schema)


def test_platform_release_manifest_valid_sample(platform_manifest_schema, valid_manifest_sample):
    jsonschema.validate(instance=valid_manifest_sample, schema=platform_manifest_schema, format_checker=FormatChecker())


def test_schema_rejects_missing_component(platform_manifest_schema, valid_manifest_sample):
    bad = dict(valid_manifest_sample)
    bad["components"] = dict(valid_manifest_sample["components"])
    del bad["components"]["soc"]
    with pytest.raises(jsonschema.ValidationError):
        jsonschema.validate(instance=bad, schema=platform_manifest_schema)


def test_schema_rejects_invalid_uuid(platform_manifest_schema, valid_manifest_sample):
    bad = dict(valid_manifest_sample)
    bad["release_id"] = "not-a-valid-uuid-format-1234"
    with pytest.raises(jsonschema.ValidationError):
        jsonschema.validate(instance=bad, schema=platform_manifest_schema)


def test_schema_rejects_invalid_digest_format(platform_manifest_schema, valid_manifest_sample):
    bad = dict(valid_manifest_sample)
    bad["components"] = dict(valid_manifest_sample["components"])
    bad["components"]["assessment"] = dict(valid_manifest_sample["components"]["assessment"])
    bad["components"]["assessment"]["image_digest"] = "md5:12345"
    with pytest.raises(jsonschema.ValidationError):
        jsonschema.validate(instance=bad, schema=platform_manifest_schema)


def test_schema_rejects_additional_properties(platform_manifest_schema, valid_manifest_sample):
    bad = dict(valid_manifest_sample)
    bad["unexpected_extra_field"] = "malicious"
    with pytest.raises(jsonschema.ValidationError):
        jsonschema.validate(instance=bad, schema=platform_manifest_schema)


def test_channel_definitions_consistency():
    channels = ["assessment-stable.json", "soc-stable.json", "hotspot-stable.json", "pish-stable.json"]
    for ch in channels:
        ch_path = os.path.join(CHANNELS_DIR, ch)
        assert os.path.exists(ch_path), f"Missing channel file: {ch}"
        with open(ch_path, "r", encoding="utf-8") as f:
            data = json.load(f)
            assert data["channel"] == ch.replace(".json", "")
            assert data["product_code"] in ["assessment", "soc", "hotspot", "pish"]
            assert data["status"] in ["available", "reserved", "unavailable"]

            # Reserved channel consistency
            if data["status"] == "reserved":
                assert data["current_version"] is None
                assert len(data["releases"]) == 0

            # Available releases consistency
            if data["status"] == "available":
                assert data["current_version"] is not None
                assert len(data["releases"]) > 0
                for rel in data["releases"]:
                    assert "version" in rel
                    if "archive" in rel:
                        assert "sha256" in rel["archive"]
                        assert len(rel["archive"]["sha256"]) == 64
