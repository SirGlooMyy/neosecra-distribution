"""Generate a deterministic, integrity-checked air-gap install plan.

The installer only prepares a plan; it never creates a license, signs an
artifact, or executes the generated shell.  All values copied into that plan
are validated and shell-quoted before writing.  Existing output is preserved
and never silently overwritten.
"""

from __future__ import annotations

import argparse
import base64
import binascii
import json
import os
import re
import shlex
import socket
import stat
import tempfile
from pathlib import Path
from typing import Any, NoReturn

try:
    import nacl.exceptions
    import nacl.signing
except ImportError:  # pragma: no cover - exercised on minimal hosts
    nacl = None


SEMVER_RE = re.compile(r"^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$")
DIGEST_RE = re.compile(r"^sha256:[0-9a-f]{64}$")
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
PRODUCT_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,63}$")
TENANT_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$")


def die(msg: str, code: int = 4) -> NoReturn:
    print(f"AIRGAP ERROR: {msg}", file=os.sys.stderr)
    raise SystemExit(code)


def _safe_text(value: object, label: str, *, max_len: int = 512) -> str:
    if not isinstance(value, str):
        die(f"{label} must be a string")
    if not value or len(value) > max_len or any(ord(ch) < 0x20 or ord(ch) == 0x7F for ch in value):
        die(f"{label} is invalid")
    return value


def _b64url(value: object, label: str) -> bytes:
    text = _safe_text(value, label, max_len=4096)
    if not re.fullmatch(r"[A-Za-z0-9_-]+={0,2}", text) or "=" in text[:-2]:
        die(f"{label} is not valid base64url")
    padded = text + "=" * (-len(text) % 4)
    try:
        return base64.urlsafe_b64decode(padded.encode("ascii"))
    except (binascii.Error, UnicodeEncodeError) as exc:
        die(f"{label} is not valid base64url: {exc}")


def decode_and_verify_license(license_path: str, pubkey_path: str, expected_tenant: str) -> dict[str, Any]:
    if nacl is None:
        die("PyNaCl is required for Ed25519 license verification")
    tenant = _safe_text(expected_tenant, "tenant")
    if not TENANT_RE.fullmatch(tenant):
        die("Expected tenant ID is invalid")
    license_file = Path(license_path)
    pubkey_file = Path(pubkey_path)
    if not license_file.is_file():
        die(f"License not found: {license_path}")
    if not pubkey_file.is_file():
        die(f"License Authority public key not found: {pubkey_path}")
    try:
        envelope = json.loads(license_file.read_text(encoding="utf-8"))
        pubkey_text = pubkey_file.read_text(encoding="utf-8").strip()
    except (OSError, UnicodeError, ValueError) as exc:
        die(f"Failed to read license material: {exc}")
    if not isinstance(envelope, dict):
        die("License envelope must be a JSON object")
    if envelope.get("schema_version") != 1 or envelope.get("algorithm") != "Ed25519":
        die("Unsupported license envelope schema or algorithm")
    key_id = envelope.get("key_id")
    if not isinstance(key_id, str) or not re.fullmatch(r"[A-Za-z0-9._:-]{1,128}", key_id):
        die("License key_id is invalid")
    payload_b64 = _safe_text(envelope.get("payload"), "License payload", max_len=65536)
    signature_b64 = _safe_text(envelope.get("signature"), "License signature", max_len=4096)
    payload_bytes = _b64url(payload_b64, "License payload")
    signature_bytes = _b64url(signature_b64, "License signature")
    if len(payload_bytes) == 0 or len(signature_bytes) != 64:
        die("License payload or signature length is invalid")
    public_bytes = _b64url(pubkey_text, "License public key")
    if len(public_bytes) != 32:
        die("License public key length is invalid")
    try:
        verify_key = nacl.signing.VerifyKey(public_bytes)
        # Canonical license protocol signs the unpadded base64url payload.
        verify_key.verify(payload_b64.encode("ascii"), signature_bytes)
    except nacl.exceptions.BadSignatureError:
        # Keep the operator-facing reason stable without exposing payloads or
        # signature material in logs.
        die("SECURITY VIOLATION: License signature verification failed (Tampered!)")
    except (ValueError, TypeError) as exc:
        die(f"SECURITY VIOLATION: License signature verification failed: {type(exc).__name__}")
    try:
        entitlement = json.loads(payload_bytes.decode("utf-8"))
    except (UnicodeDecodeError, ValueError) as exc:
        die(f"License payload JSON is invalid: {exc}")
    if not isinstance(entitlement, dict):
        die("License entitlement must be a JSON object")
    if entitlement.get("tenant_id") != tenant:
        die(f"Tenant mismatch: License is for {entitlement.get('tenant_id')}, expected {tenant}")
    modules = entitlement.get("modules")
    if not isinstance(modules, list) or any(not isinstance(module, str) or not PRODUCT_RE.fullmatch(module) for module in modules):
        die("License modules are invalid")
    return entitlement


def check_port(port: object) -> bool:
    if not isinstance(port, int) or isinstance(port, bool) or not 1 <= port <= 65535:
        die(f"Invalid required port: {port}")
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        try:
            sock.bind(("0.0.0.0", port))
            return True
        except OSError:
            return False


def check_disk(required_mb: object, path: Path) -> None:
    if not isinstance(required_mb, int) or isinstance(required_mb, bool) or required_mb < 0:
        die("required_disk_mb must be a non-negative integer")
    try:
        path.mkdir(parents=True, exist_ok=True)
        _, _, free = os.statvfs(path).f_bsize, 0, 0
        free_bytes = os.statvfs(path).f_bavail * os.statvfs(path).f_frsize
    except OSError as exc:
        die(f"Cannot inspect install directory: {exc}")
    free_mb = free_bytes / (1024 * 1024)
    if free_mb < required_mb:
        die(f"Insufficient disk space. Required: {required_mb}MB, Free: {free_mb:.1f}MB")


def sanitize_product_name(value: object) -> str:
    product = _safe_text(value, "product", max_len=64).strip().lower()
    if not PRODUCT_RE.fullmatch(product):
        die(f"SECURITY VIOLATION: Invalid product name '{product}'. Path traversal blocked.")
    return product


def _safe_install_dir(value: object) -> str:
    raw = _safe_text(value, "install-dir", max_len=512)
    path = Path(raw)
    if not path.is_absolute() or any(part in {".", ".."} for part in path.parts):
        die("install-dir must be an absolute, normalized path")
    return str(path)


def _validate_component(product: str, component: object) -> dict[str, Any]:
    if not isinstance(component, dict):
        die(f"Package manifest component '{product}' is invalid")
    version = _safe_text(component.get("version"), f"{product}.version", max_len=64)
    if not SEMVER_RE.fullmatch(version):
        die(f"Package manifest component '{product}' has an invalid version")
    digest = _safe_text(component.get("digest"), f"{product}.digest", max_len=80)
    if not DIGEST_RE.fullmatch(digest):
        die(f"Package manifest component '{product}' has an invalid image digest")
    tar_sha = _safe_text(component.get("tar_sha256"), f"{product}.tar_sha256", max_len=80).lower()
    if not SHA256_RE.fullmatch(tar_sha):
        die(f"Package manifest component '{product}' has an invalid tar_sha256")
    for key in ("sbom", "attestation"):
        value = _safe_text(component.get(key), f"{product}.{key}", max_len=4096)
        if not value.strip():
            die(f"Package manifest component '{product}' has an empty {key}")
    required_disk = component.get("required_disk_mb", 1024)
    if not isinstance(required_disk, int) or isinstance(required_disk, bool) or required_disk < 0:
        die(f"{product}.required_disk_mb must be a non-negative integer")
    for port in component.get("required_ports", []):
        if not isinstance(port, int) or isinstance(port, bool) or not 1 <= port <= 65535:
            die(f"{product}.required_ports contains an invalid port")
    result = dict(component)
    result.update({"version": version, "digest": digest, "tar_sha256": tar_sha, "required_disk_mb": required_disk})
    return result


def _write_exclusive(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    try:
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o700)
    except FileExistsError:
        die(f"Refusing to overwrite existing plan: {path}")
    except OSError as exc:
        die(f"Cannot create install plan: {exc}")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(path, stat.S_IRWXU)
    except OSError as exc:
        try:
            path.unlink(missing_ok=True)
        except OSError:
            pass
        die(f"Cannot write install plan: {exc}")


def main() -> None:
    parser = argparse.ArgumentParser(description="NeoSecra Multi-Product Air-gap Installer")
    parser.add_argument("--manifest", required=True, help="Path to package manifest JSON")
    parser.add_argument("--license", required=True, help="Path to .vlicense file")
    parser.add_argument("--pubkey", required=True, help="Path to Ed25519 public key file")
    parser.add_argument("--tenant", required=True, help="Expected tenant ID")
    parser.add_argument("--products", required=True, help="Comma-separated list of products to install")
    parser.add_argument("--plan-out", default="airgap_plan.sh", help="Output bash script plan")
    parser.add_argument("--install-dir", default="/opt/neosecra", help="Base installation directory")
    args = parser.parse_args()

    requested_products = sorted({sanitize_product_name(item.strip()) for item in args.products.split(",") if item.strip()})
    if not requested_products:
        die("At least one product must be requested")
    install_dir = _safe_install_dir(args.install_dir)
    plan_out = Path(_safe_text(args.plan_out, "plan-out", max_len=512))
    if not plan_out.is_absolute():
        plan_out = Path.cwd() / plan_out
    if any(part in {".", ".."} for part in plan_out.parts):
        die("plan-out must not contain traversal components")

    entitlement = decode_and_verify_license(args.license, args.pubkey, args.tenant)
    allowed_modules = entitlement.get("modules", [])
    for product in requested_products:
        if product not in allowed_modules:
            die(f"License entitlement error: Product '{product}' is not allowed by this license.")

    manifest_path = Path(args.manifest)
    if not manifest_path.is_file():
        die(f"Package manifest not found: {args.manifest}")
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, ValueError) as exc:
        die(f"Invalid package manifest JSON: {exc}")
    if not isinstance(manifest, dict) or not isinstance(manifest.get("components"), dict):
        die("Package manifest components object is required")
    components = manifest["components"]
    compatibility = manifest.get("compatibility_lock", {})
    if compatibility is not None and not isinstance(compatibility, dict):
        die("compatibility_lock must be an object")

    validated: dict[str, dict[str, Any]] = {}
    total_disk = 0
    ports: list[int] = []
    for product in requested_products:
        if product not in components:
            die(f"Missing artifact error: Product '{product}' is not present in the package manifest.")
        component = _validate_component(product, components[product])
        expected_version = compatibility.get(product) if isinstance(compatibility, dict) else None
        if expected_version is not None and expected_version != component["version"]:
            die(f"Incompatible version error: Product '{product}' version {component['version']} does not match compatibility lock {expected_version}.")
        validated[product] = component
        total_disk += component["required_disk_mb"]
        ports.extend(component.get("required_ports", []))

    check_disk(total_disk, Path(install_dir))
    for port in ports:
        if not check_port(port):
            die(f"Preflight error: Required port {port} is already in use.")
    if not shutil_which("docker") or not shutil_which("sha256sum"):
        die("Preflight error: docker and sha256sum are required.")

    q = shlex.quote
    plan = ["#!/usr/bin/env bash", "set -Eeuo pipefail", "echo 'NeoSecra Air-Gap Multi-Product Install Plan'", "echo '==========================================='"]
    for product in requested_products:
        component = validated[product]
        version = component["version"]
        digest = component["digest"]
        tar_hash = component["tar_sha256"]
        image_tar = f"images/{product}-{version}.tar"
        release_dir = f"{install_dir}/{product}/releases/{version}"
        image_ref = component.get("image_reference") or component.get("reference") or f"registry.neosecra.com/{product}:{version}"
        image_ref = _safe_text(image_ref, f"{product}.image_reference", max_len=512)
        plan.extend(
            [
                f"echo {q(f'Installing {product} (v{version})')}",
                f"mkdir -p {q(release_dir)}",
                f"if docker image inspect {q(image_ref + '@' + digest)} >/dev/null 2>&1; then",
                f"  echo {q(f'  Image {digest} already loaded.')}",
                "else",
                f"  if [[ ! -f {q(image_tar)} ]]; then echo {q(f'Error: Missing image archive {image_tar}')} >&2; exit 4; fi",
                "  echo '  Verifying SHA256 integrity...'",
                f"  actual_hash=$(sha256sum {q(image_tar)} | awk '{{print $1}}')",
                f"  if [[ \"$actual_hash\" != {q(tar_hash)} ]]; then",
                f"    echo 'SECURITY VIOLATION: Artifact hash mismatch for {image_tar}!' >&2",
                f"    echo \"Expected: {tar_hash}, Got: $actual_hash\" >&2",
                "    exit 4",
                "  fi",
                "  echo '  Loading image air-gapped...'",
                f"  docker load --quiet -i {q(image_tar)}",
                "fi",
                "echo '  Linking current release...'",
                f"ln -sfn {q(release_dir)} {q(f'{install_dir}/{product}/current')}",
            ]
        )
    plan.extend(["echo 'All requested profiles installed successfully.'", "exit 0"])
    _write_exclusive(plan_out, "\n".join(plan) + "\n")
    print(f"Install plan generated securely at {plan_out}.")


def shutil_which(command: str) -> str | None:
    # Keep the dependency surface tiny while retaining shutil.which semantics.
    for directory in os.environ.get("PATH", "").split(os.pathsep):
        candidate = Path(directory) / command
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return str(candidate)
    return None


if __name__ == "__main__":
    main()
