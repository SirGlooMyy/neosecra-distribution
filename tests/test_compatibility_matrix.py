import pytest
import json
import os
import jsonschema

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
        "upgrade": {"backup_required": False, "migration_required": False},
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
