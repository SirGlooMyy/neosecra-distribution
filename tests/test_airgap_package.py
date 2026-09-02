import pytest
import subprocess
import json
import os
import tempfile
import base64
import nacl.signing

def generate_keypair():
    signing_key = nacl.signing.SigningKey.generate()
    verify_key = signing_key.verify_key
    pubkey_b64 = base64.urlsafe_b64encode(bytes(verify_key)).decode('utf-8')
    return signing_key, pubkey_b64

def generate_mock_license(signing_key, tenant, modules, tampered=False):
    payload = json.dumps({"tenant_id": tenant, "modules": modules}).encode('utf-8')
    payload_b64 = base64.urlsafe_b64encode(payload).decode('utf-8').rstrip("=")

    # Real signature
    signature = signing_key.sign(payload_b64.encode("utf-8")).signature
    signature_b64 = base64.urlsafe_b64encode(signature).decode('utf-8').rstrip("=")

    if tampered:
        # Change payload slightly but keep original signature
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

def get_installer_path():
    return os.path.join(os.path.dirname(__file__), "../deployment/v1/install/airgap_installer.py")

@pytest.fixture
def env_setup():
    with tempfile.TemporaryDirectory() as tmpdir:
        sk, pk_b64 = generate_keypair()
        pk_file = os.path.join(tmpdir, "pub.key")
        with open(pk_file, "w") as f:
            f.write(pk_b64)
        yield tmpdir, sk, pk_file

def test_license_entitlement_rejection(env_setup):
    tmpdir, sk, pk_file = env_setup
    lic_file = os.path.join(tmpdir, "lic.vlicense")
    man_file = os.path.join(tmpdir, "man.json")

    with open(lic_file, "w") as f:
        f.write(generate_mock_license(sk, "tenantA", ["assessment"]))

    with open(man_file, "w") as f:
        f.write(generate_mock_manifest({"soc": {"version": "1.0.0", "digest": "a", "tar_sha256": "a", "sbom": "a", "attestation": "a"}}, {}))

    res = subprocess.run(
        ["python3", get_installer_path(), "--manifest", man_file, "--license", lic_file, "--pubkey", pk_file, "--tenant", "tenantA", "--products", "soc"],
        capture_output=True, text=True
    )
    assert res.returncode == 4
    assert "License entitlement error" in res.stderr

def test_tampered_license(env_setup):
    tmpdir, sk, pk_file = env_setup
    lic_file = os.path.join(tmpdir, "lic.vlicense")
    man_file = os.path.join(tmpdir, "man.json")

    with open(lic_file, "w") as f:
        f.write(generate_mock_license(sk, "tenantA", ["assessment"], tampered=True))

    with open(man_file, "w") as f:
        f.write(generate_mock_manifest({"assessment": {"version": "1.0.0", "digest": "a", "tar_sha256": "a", "sbom": "a", "attestation": "a"}}, {}))

    res = subprocess.run(
        ["python3", get_installer_path(), "--manifest", man_file, "--license", lic_file, "--pubkey", pk_file, "--tenant", "tenantA", "--products", "assessment"],
        capture_output=True, text=True
    )
    assert res.returncode == 4
    assert "SECURITY VIOLATION: License signature verification failed (Tampered!)" in res.stderr

def test_wrong_tenant(env_setup):
    tmpdir, sk, pk_file = env_setup
    lic_file = os.path.join(tmpdir, "lic.vlicense")
    man_file = os.path.join(tmpdir, "man.json")

    with open(lic_file, "w") as f:
        f.write(generate_mock_license(sk, "tenantA", ["assessment"]))

    with open(man_file, "w") as f:
        f.write(generate_mock_manifest({"assessment": {"version": "1.0.0", "digest": "a", "tar_sha256": "a", "sbom": "a", "attestation": "a"}}, {}))

    res = subprocess.run(
        ["python3", get_installer_path(), "--manifest", man_file, "--license", lic_file, "--pubkey", pk_file, "--tenant", "tenantB", "--products", "assessment"],
        capture_output=True, text=True
    )
    assert res.returncode == 4
    assert "Tenant mismatch: License is for tenantA, expected tenantB" in res.stderr

def test_archive_traversal(env_setup):
    tmpdir, sk, pk_file = env_setup
    lic_file = os.path.join(tmpdir, "lic.vlicense")
    man_file = os.path.join(tmpdir, "man.json")

    with open(lic_file, "w") as f:
        f.write(generate_mock_license(sk, "tenantA", ["assessment"]))

    with open(man_file, "w") as f:
        f.write(generate_mock_manifest({"assessment": {"version": "1.0.0", "digest": "a", "tar_sha256": "a", "sbom": "a", "attestation": "a"}}, {}))

    res = subprocess.run(
        ["python3", get_installer_path(), "--manifest", man_file, "--license", lic_file, "--pubkey", pk_file, "--tenant", "tenantA", "--products", "../../../root"],
        capture_output=True, text=True
    )
    assert res.returncode == 4
    assert "SECURITY VIOLATION: Invalid product name" in res.stderr
    assert "Path traversal blocked" in res.stderr

def test_successful_idempotent_plan_generation(env_setup):
    tmpdir, sk, pk_file = env_setup
    lic_file = os.path.join(tmpdir, "lic.vlicense")
    man_file = os.path.join(tmpdir, "man.json")
    plan_file = os.path.join(tmpdir, "plan.sh")

    with open(lic_file, "w") as f:
        f.write(generate_mock_license(sk, "tenantA", ["assessment", "soc"]))

    components = {
        "assessment": {"version": "1.0.0", "digest": "sha256:" + "a" * 64, "tar_sha256": "a" * 64, "sbom": "a", "attestation": "a", "required_disk_mb": 0},
        "soc": {"version": "2.0.0", "digest": "sha256:" + "b" * 64, "tar_sha256": "b" * 64, "sbom": "a", "attestation": "a", "required_disk_mb": 0}
    }
    with open(man_file, "w") as f:
        f.write(generate_mock_manifest(components, {}))

    res = subprocess.run(
        ["python3", get_installer_path(), "--manifest", man_file, "--license", lic_file, "--pubkey", pk_file, "--tenant", "tenantA", "--products", "soc,assessment,soc", "--plan-out", plan_file],
        capture_output=True, text=True
    )
    assert res.returncode == 0
    assert "Install plan generated securely" in res.stdout

    with open(plan_file) as f:
        plan_content = f.read()
        # Verify deduplication (should only install soc once, even though provided twice)
        assert plan_content.count("Installing soc") == 1
        assert "docker load --quiet -i images/assessment-1.0.0.tar" in plan_content
        assert "actual_hash=$(sha256sum" in plan_content
        assert "a" * 64 in plan_content

def test_offline_corruption_execution(env_setup):
    # Simulate the execution of the bash plan to prove hash enforcement
    tmpdir, sk, pk_file = env_setup
    lic_file = os.path.join(tmpdir, "lic.vlicense")
    man_file = os.path.join(tmpdir, "man.json")
    plan_file = os.path.join(tmpdir, "plan.sh")

    with open(lic_file, "w") as f:
        f.write(generate_mock_license(sk, "tenantA", ["assessment"]))

    components = {
        "assessment": {"version": "1.0.0", "digest": "sha256:" + "a" * 64, "tar_sha256": "f" * 64, "sbom": "a", "attestation": "a", "required_disk_mb": 0}
    }
    with open(man_file, "w") as f:
        f.write(generate_mock_manifest(components, {}))

    res = subprocess.run(
        ["python3", get_installer_path(), "--manifest", man_file, "--license", lic_file, "--pubkey", pk_file, "--tenant", "tenantA", "--products", "assessment", "--plan-out", plan_file, "--install-dir", os.path.join(tmpdir, "opt")],
        capture_output=True, text=True
    )
    assert res.returncode == 0

    # Write a fake tarball
    images_dir = os.path.join(tmpdir, "images")
    os.makedirs(images_dir)
    tar_path = os.path.join(images_dir, "assessment-1.0.0.tar")
    with open(tar_path, "w") as f:
        f.write("corrupted data")

    # Execute the generated plan
    res_bash = subprocess.run(["bash", plan_file], cwd=tmpdir, capture_output=True, text=True)
    assert res_bash.returncode == 4
    assert "SECURITY VIOLATION: Artifact hash mismatch" in res_bash.stderr
