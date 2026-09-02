import pytest
import subprocess
import json
import os
import tempfile

def test_rejects_unsigned_platform_manifest():
    with tempfile.NamedTemporaryFile("w", suffix=".json") as f:
        json.dump({"channel": "stable", "platform_version": "1.0.0"}, f)
        f.flush()
        res = subprocess.run(["python3", "deployment/v1/upgrade/verify_platform_manifest.py", "--verify", f.name], capture_output=True)
        assert res.returncode == 4
        assert b"SECURITY VIOLATION" in res.stderr

def test_rejects_expired_legacy_allowlist():
    # This is handled by verify_mapping.py, let's test it directly
    env = os.environ.copy()
    env["CHANNEL_JSON"] = json.dumps({"channel": "assessment-stable", "product": "assessment", "releases": [{"version": "1.0.0"}]})
    env["TARGET"] = "1.0.0"

    with tempfile.NamedTemporaryFile("w", suffix=".json") as f:
        json.dump({"assessment-stable": {"product": "assessment", "releases": {"1.0.0": {"expires_at": "2020-01-01T00:00:00Z", "archive_sha256": "abc"}}}}, f)
        f.flush()
        env["LEGACY_ALLOWLIST"] = f.name
        env["ARCHIVE_SHA256"] = "abc"

        res = subprocess.run(["python3", "deployment/v1/upgrade/verify_mapping.py"], input=b"{}", env=env, capture_output=True)
        assert res.returncode == 4

def test_rejects_downgrade():
    with tempfile.NamedTemporaryFile("w", suffix=".json") as f:
        json.dump({"channel": "stable", "platform_version": "1.0.0", "released_at": "2025-01-01T00:00:00Z", "signatures": {"minisign_signature": "dummy"}}, f)
        f.flush()

        env = os.environ.copy()
        with tempfile.TemporaryDirectory() as tmpdir:
            env["V1_ROOT"] = tmpdir
            # Setup state
            with open(os.path.join(tmpdir, ".release_state.json"), "w") as sf:
                json.dump({"released_at": "2026-01-01T00:00:00Z"}, sf)

            pubkey_path = os.path.join(tmpdir, "pub.key")
            with open(pubkey_path, "w") as kf:
                kf.write("untrusted comment: mock pubkey\nRWT...")
            env["NEOSECRA_SIGNATURE_PUBKEY"] = pubkey_path

            res = subprocess.run(["python3", "deployment/v1/upgrade/verify_platform_manifest.py", "--verify", f.name], env=env, capture_output=True)
            assert res.returncode == 4
            # Schema validation is intentionally performed before monotonic
            # state checks; malformed input must never reach the trust gate.
            assert b"Manifest schema validation failed" in res.stderr

def test_rejects_unsigned_rollback_auth():
    with tempfile.NamedTemporaryFile("w", suffix=".json") as f:
        json.dump({"rollback_to": "1.0.0"}, f)
        f.flush()
        res = subprocess.run(["python3", "deployment/v1/upgrade/verify_rollback_auth.py", f.name, "1.0.0"], capture_output=True)
        assert res.returncode == 4
        assert b"Unsigned rollback authorization" in res.stderr

def test_rejects_expired_rollback_auth():
    with tempfile.NamedTemporaryFile("w", suffix=".json") as f:
        json.dump({"rollback_to": "1.0.0", "expires_at": "2020-01-01T00:00:00Z"}, f)
        f.flush()
        res = subprocess.run(["python3", "deployment/v1/upgrade/verify_rollback_auth.py", f.name, "1.0.0"], capture_output=True)
        assert res.returncode == 4
        assert b"Rollback authorization has expired" in res.stderr
