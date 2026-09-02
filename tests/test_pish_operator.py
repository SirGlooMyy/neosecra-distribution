import pytest
import subprocess
import json
import os
import tempfile
import base64

try:
    import nacl.signing
    NACL_AVAILABLE = True
except ImportError:
    NACL_AVAILABLE = False

def get_installer_path():
    return os.path.join(os.path.dirname(__file__), "../deployment/v1/install/airgap_installer.py")

def generate_keypair():
    signing_key = nacl.signing.SigningKey.generate()
    verify_key = signing_key.verify_key
    pubkey_b64 = base64.urlsafe_b64encode(bytes(verify_key)).decode('utf-8')
    return signing_key, pubkey_b64

def generate_mock_license(signing_key, tenant, modules, tampered=False):
    payload = json.dumps({"tenant_id": tenant, "modules": modules}).encode('utf-8')
    payload_b64 = base64.urlsafe_b64encode(payload).decode('utf-8').rstrip("=")

    signature = signing_key.sign(payload_b64.encode("utf-8")).signature
    signature_b64 = base64.urlsafe_b64encode(signature).decode('utf-8').rstrip("=")

    if tampered:
        payload_tampered = json.dumps({"tenant_id": tenant, "modules": modules + ["hacker"]}).encode('utf-8')
        payload_b64 = base64.urlsafe_b64encode(payload_tampered).decode('utf-8').rstrip("=")

    return json.dumps({
        "schema_version": 1,
        "key_id": "test",
        "algorithm": "Ed25519",
        "payload": payload_b64,
        "signature": signature_b64
    })

def generate_mock_manifest(components, comp_lock):
    return json.dumps({
        "components": components,
        "compatibility_lock": comp_lock
    })

@pytest.fixture
def env_setup():
    if not NACL_AVAILABLE:
        pytest.skip("pynacl not available")
    with tempfile.TemporaryDirectory() as tmpdir:
        sk, pk_b64 = generate_keypair()
        pk_file = os.path.join(tmpdir, "pub.key")
        with open(pk_file, "w") as f:
            f.write(pk_b64)
        yield tmpdir, sk, pk_file

def test_pish_missing_license_entitlement(env_setup):
    tmpdir, sk, pk_file = env_setup
    lic_file = os.path.join(tmpdir, "lic.vlicense")
    man_file = os.path.join(tmpdir, "man.json")

    with open(lic_file, "w") as f:
        f.write(generate_mock_license(sk, "tenantA", ["soc", "assessment"]))

    with open(man_file, "w") as f:
        f.write(generate_mock_manifest({"pish": {"version": "1.0.0", "digest": "a", "tar_sha256": "a", "sbom": "a", "attestation": "a"}}, {}))

    res = subprocess.run(
        ["python3", get_installer_path(), "--manifest", man_file, "--license", lic_file, "--pubkey", pk_file, "--tenant", "tenantA", "--products", "pish"],
        capture_output=True, text=True
    )
    assert res.returncode == 4
    assert "License entitlement error: Product 'pish' is not allowed by this license" in res.stderr

def test_pish_missing_artifact_fields(env_setup):
    tmpdir, sk, pk_file = env_setup
    lic_file = os.path.join(tmpdir, "lic.vlicense")
    man_file = os.path.join(tmpdir, "man.json")

    with open(lic_file, "w") as f:
        f.write(generate_mock_license(sk, "tenantA", ["pish"]))

    # Missing sbom and attestation
    with open(man_file, "w") as f:
        f.write(generate_mock_manifest({"pish": {"version": "1.0.0", "digest": "sha256:" + "a" * 64, "tar_sha256": "a" * 64}}, {}))

    res = subprocess.run(
        ["python3", get_installer_path(), "--manifest", man_file, "--license", lic_file, "--pubkey", pk_file, "--tenant", "tenantA", "--products", "pish"],
        capture_output=True, text=True
    )
    assert res.returncode == 4
    assert "pish.sbom must be a string" in res.stderr

def test_pish_legacy_bypass_rejected():
    # pish-stable should NOT allow legacy bypass in verify_mapping.py
    env = os.environ.copy()
    env["CHANNEL_JSON"] = json.dumps({"channel": "pish-stable", "product": "pish", "releases": [{"version": "1.0.0"}]})
    env["TARGET"] = "1.0.0"

    with tempfile.NamedTemporaryFile("w", suffix=".json") as f:
        json.dump({"pish-stable": {"product": "pish", "releases": {"1.0.0": {"expires_at": "2099-01-01T00:00:00Z", "archive_sha256": "abc"}}}}, f)
        f.flush()
        env["LEGACY_ALLOWLIST"] = f.name
        env["ARCHIVE_SHA256"] = "abc"

        # We pass empty services payload - if it applies legacy, it would exit 0
        res = subprocess.run(["python3", "deployment/v1/upgrade/verify_mapping.py"], input=b"{}", env=env, capture_output=True)
        assert res.returncode == 4 # Fails because legacy is blocked for pish-stable, and empty compose is invalid

def test_pish_compose_manifest_parity():
    env = os.environ.copy()
    env["CHANNEL_JSON"] = json.dumps({
            "channel": "pish-stable",
            "product": "pish",
            "product_code": "pish",
            "edition": "standard",
            "status": "available",
            "updated": "2026-08-31T00:00:00Z",
            "current_version": "1.0.0",
        "releases": [
            {
                "version": "1.0.0",
                "images": {
                        "backend": {"reference": "registry/pish-backend", "digest": "sha256:" + "1" * 64},
                        "frontend": {"reference": "registry/pish-frontend", "digest": "sha256:" + "2" * 64}
                }
            }
        ]
    })
    env["TARGET"] = "1.0.0"

    # Missing frontend in compose
    res = subprocess.run(
        ["python3", "deployment/v1/upgrade/verify_mapping.py"],
        input=b'{"services": {"backend": {"image": "registry/pish-backend"}}}',
        env=env, capture_output=True
    )
    assert res.returncode == 4 # Fails parity check

    # Matching compose
    res2 = subprocess.run(
        ["python3", "deployment/v1/upgrade/verify_mapping.py"],
        input=(b'{"services": {"backend": {"image": "registry/pish-backend@sha256:' + b"1" * 64 + b'"}, "frontend": {"image": "registry/pish-frontend@sha256:' + b"2" * 64 + b'"}}}'),
        env=env, capture_output=True
    )
    # Output should show ENFORCE messages
    assert res2.returncode == 0
    assert (b"ENFORCE backend registry/pish-backend sha256:" + b"1" * 64) in res2.stdout
    assert (b"ENFORCE frontend registry/pish-frontend sha256:" + b"2" * 64) in res2.stdout
