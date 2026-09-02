import hashlib
import json
import os
import subprocess
import pytest

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
VERIFIER_SCRIPT = os.path.join(REPO_ROOT, "deployment", "v1", "agent", "artifact-verifier.sh")


def run_verifier_fn(fn_name, *args, extra_path=None):
    arg_str = " ".join([f'"{a}"' for a in args])
    path_env = os.environ.get("PATH", "")
    if extra_path:
        path_env = f"{extra_path}:{path_env}"

    cmd = f'source "{VERIFIER_SCRIPT}" && {fn_name} {arg_str}'
    proc = subprocess.run(
        ["bash", "-c", cmd],
        capture_output=True,
        text=True,
        env={**os.environ, "PATH": path_env},
    )
    return proc.returncode, proc.stdout, proc.stderr


# ============================================================================
# 1. SHA-256 Sidecar Tests
# ============================================================================
def test_sha256_sidecar_pass(tmp_path):
    f = tmp_path / "test.tar.gz"
    f.write_bytes(b"hello world payload")
    digest = hashlib.sha256(b"hello world payload").hexdigest()
    sidecar = tmp_path / "test.tar.gz.sha256"
    sidecar.write_text(f"{digest}  test.tar.gz\n")

    code, _, _ = run_verifier_fn("verify_sha256_sidecar", str(f), str(sidecar))
    assert code == 0


def test_sha256_sidecar_fail_on_corrupted_payload(tmp_path):
    f = tmp_path / "test.tar.gz"
    f.write_bytes(b"tampered payload")
    sidecar = tmp_path / "test.tar.gz.sha256"
    sidecar.write_text("0000000000000000000000000000000000000000000000000000000000000000  test.tar.gz\n")

    code, _, _ = run_verifier_fn("verify_sha256_sidecar", str(f), str(sidecar))
    assert code != 0


def test_sha256_sidecar_fail_on_missing_file():
    code, _, _ = run_verifier_fn("verify_sha256_sidecar", "/non/existent/file.tar.gz")
    assert code != 0


# ============================================================================
# 2. Minisign Verification Tests
# ============================================================================
def test_minisign_fail_closed_when_minisign_missing():
    code, _, _ = run_verifier_fn("verify_minisign_file", "f", "s", "k", extra_path="/empty_fake_bin")
    assert code != 0


def test_minisign_fail_closed_on_missing_keys_or_signatures(tmp_path):
    f = tmp_path / "test.tar.gz"
    f.write_bytes(b"hello")
    code, _, _ = run_verifier_fn("verify_minisign_file", str(f), str(tmp_path / "missing.sig"), str(tmp_path / "missing.pub"))
    assert code != 0


# ============================================================================
# 3. Image Signature & Attestation Fail-Closed Tests
# ============================================================================
def test_image_signature_fail_closed_when_cosign_missing(tmp_path):
    key = tmp_path / "pub.key"
    key.write_text("fake-public-key")
    digest = "sha256:" + "a" * 64
    code, _, _ = run_verifier_fn("verify_image_signature", "registry.neosecra.com/backend", digest, str(key), extra_path="/empty_fake_bin")
    assert code != 0, "Must fail-closed when cosign executable is missing"


def test_image_signature_fail_closed_when_key_missing():
    digest = "sha256:" + "a" * 64
    code, _, _ = run_verifier_fn("verify_image_signature", "registry.neosecra.com/backend", digest, "/non/existent/key.pub")
    assert code != 0, "Must fail-closed when public key file is missing"


def test_image_signature_fail_closed_on_malformed_digest(tmp_path):
    key = tmp_path / "pub.key"
    key.write_text("fake-public-key")
    code, _, _ = run_verifier_fn("verify_image_signature", "registry.neosecra.com/backend", "md5:12345", str(key))
    assert code != 0, "Must fail-closed on non-sha256 digest format"


def test_image_attestation_fail_closed_when_cosign_missing(tmp_path):
    key = tmp_path / "pub.key"
    key.write_text("fake-public-key")
    digest = "sha256:" + "a" * 64
    code, _, _ = run_verifier_fn("verify_image_attestation", "registry.neosecra.com/backend", digest, str(key), "https://cosign.sigstore.dev/attestation/v1", extra_path="/empty_fake_bin")
    assert code != 0, "Must fail-closed when cosign is missing during attestation verification"


def test_image_attestation_fail_closed_when_key_missing():
    digest = "sha256:" + "a" * 64
    code, _, _ = run_verifier_fn("verify_image_attestation", "registry.neosecra.com/backend", digest, "/non/existent/key.pub")
    assert code != 0


# ============================================================================
# 4. Mocked Cosign Signature & Attestation Decision Matrix
# ============================================================================
def test_cosign_signature_and_attestation_decision_matrix(tmp_path):
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    fake_cosign = bin_dir / "cosign"
    fake_cosign.write_text("""#!/bin/bash
if [[ "$1" == "verify" ]]; then
  if [[ "$2" == "--key" && -s "$3" && "$4" == *"@sha256:"* ]]; then
    if [[ "$4" == *"fail-signature"* ]]; then exit 1; fi
    exit 0
  fi
  exit 1
fi
if [[ "$1" == "verify-attestation" ]]; then
  if [[ "$2" == "--key" && -s "$3" && "$4" == "--type" && -n "$5" && "$6" == *"@sha256:"* ]]; then
    if [[ "$5" != "https://cosign.sigstore.dev/attestation/v1" ]]; then exit 1; fi
    if [[ "$6" == *"fail-attestation"* ]]; then exit 1; fi
    exit 0
  fi
  exit 1
fi
exit 1
""")
    fake_cosign.chmod(0o755)

    key = tmp_path / "cosign.pub"
    key.write_text("dummy-cosign-pubkey")
    digest = "sha256:" + "b" * 64

    # 1. Successful signature
    code, _, _ = run_verifier_fn("verify_image_signature", "registry.neosecra.com/backend", digest, str(key), extra_path=str(bin_dir))
    assert code == 0

    # 2. Failed signature
    code, _, _ = run_verifier_fn("verify_image_signature", "registry.neosecra.com/fail-signature", digest, str(key), extra_path=str(bin_dir))
    assert code != 0

    # 3. Successful attestation
    code, _, _ = run_verifier_fn("verify_image_attestation", "registry.neosecra.com/backend", digest, str(key), "https://cosign.sigstore.dev/attestation/v1", extra_path=str(bin_dir))
    assert code == 0

    # 4. Failed attestation due to wrong predicate type
    code, _, _ = run_verifier_fn("verify_image_attestation", "registry.neosecra.com/backend", digest, str(key), "invalid-predicate", extra_path=str(bin_dir))
    assert code != 0

    # 5. Failed attestation due to signature invalidity
    code, _, _ = run_verifier_fn("verify_image_attestation", "registry.neosecra.com/fail-attestation", digest, str(key), "https://cosign.sigstore.dev/attestation/v1", extra_path=str(bin_dir))
    assert code != 0


# ============================================================================
# 5. SBOM Integrity & Structural Validation Tests
# ============================================================================
def test_sbom_spdx_pass(tmp_path):
    sbom_file = tmp_path / "sbom.spdx.json"
    spdx_data = {
        "spdxVersion": "SPDX-2.3",
        "dataLicense": "CC0-1.0",
        "SPDXID": "SPDXRef-DOCUMENT",
        "name": "NeoSecra-Platform-SBOM",
        "documentNamespace": "https://update.neosecra.com/sbom/test",
        "creationInfo": {
            "created": "2026-08-31T00:00:00Z",
            "creators": ["Tool: NeoSecra test generator"],
        },
        "packages": []
    }
    content = json.dumps(spdx_data).encode("utf-8")
    sbom_file.write_bytes(content)
    digest = hashlib.sha256(content).hexdigest()

    code, _, _ = run_verifier_fn("verify_sbom_integrity", str(sbom_file), digest, "SPDX-2.3-JSON")
    assert code == 0


def test_sbom_cyclonedx_pass(tmp_path):
    sbom_file = tmp_path / "sbom.cdx.json"
    cdx_data = {
        "bomFormat": "CycloneDX",
        "specVersion": "1.5",
        "version": 1,
        "components": []
    }
    content = json.dumps(cdx_data).encode("utf-8")
    sbom_file.write_bytes(content)
    digest = hashlib.sha256(content).hexdigest()

    code, _, _ = run_verifier_fn("verify_sbom_integrity", str(sbom_file), digest, "CycloneDX-1.5-JSON")
    assert code == 0


def test_sbom_fail_on_checksum_mismatch(tmp_path):
    sbom_file = tmp_path / "sbom.spdx.json"
    sbom_file.write_bytes(b'{"spdxVersion": "SPDX-2.3"}')
    code, _, _ = run_verifier_fn("verify_sbom_integrity", str(sbom_file), "0" * 64, "SPDX-2.3-JSON")
    assert code != 0


def test_sbom_fail_on_invalid_json(tmp_path):
    sbom_file = tmp_path / "broken.json"
    content = b"NOT_JSON"
    sbom_file.write_bytes(content)
    digest = hashlib.sha256(content).hexdigest()

    code, _, _ = run_verifier_fn("verify_sbom_integrity", str(sbom_file), digest, "SPDX-2.3-JSON")
    assert code != 0


def test_sbom_fail_on_declared_format_mismatch(tmp_path):
    sbom_file = tmp_path / "sbom.cdx.json"
    cdx_data = {"bomFormat": "CycloneDX", "specVersion": "1.5"}
    content = json.dumps(cdx_data).encode("utf-8")
    sbom_file.write_bytes(content)
    digest = hashlib.sha256(content).hexdigest()

    code, _, _ = run_verifier_fn("verify_sbom_integrity", str(sbom_file), digest, "SPDX-2.3-JSON")
    assert code != 0
