"""Verify a signed, scoped and time-limited rollback authorization."""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, NoReturn

import yaml


SEMVER_RE = re.compile(r"^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$")
NONCE_RE = re.compile(r"^[A-Za-z0-9._:-]{16,128}$")


def die(message: str, code: int = 4) -> NoReturn:
    print(f"SECURITY VIOLATION: {message}", file=sys.stderr)
    raise SystemExit(code)


def _version(value: object) -> str:
    text = str(value or "").strip()
    normalized = text.lstrip("vV")
    if not SEMVER_RE.fullmatch(normalized):
        die("Rollback target version is invalid")
    return normalized


def _timestamp(value: object) -> datetime:
    text = str(value or "").strip()
    if not text:
        die("Rollback authorization expires_at is required")
    try:
        parsed = datetime.fromisoformat(text.replace("Z", "+00:00"))
    except (TypeError, ValueError) as exc:
        die(f"Rollback authorization expires_at is invalid: {exc}")
    if parsed.tzinfo is None:
        die("Rollback authorization expires_at must include a timezone")
    return parsed.astimezone(timezone.utc)


def _load(path: Path) -> dict[str, Any]:
    try:
        with path.open(encoding="utf-8") as stream:
            value = yaml.safe_load(stream)
    except (OSError, UnicodeError, yaml.YAMLError) as exc:
        die(f"Invalid rollback authorization: {exc}")
    if not isinstance(value, dict):
        die("Rollback authorization must be an object")
    return value


def _expected(name: str, aliases: tuple[str, ...] = ()) -> str:
    for key in (name, *aliases):
        value = str(os.environ.get(key) or "").strip()
        if value:
            return value
    return ""


def _verify_signature(auth: dict[str, Any], auth_path: Path, v1_root: Path) -> None:
    signatures = auth.get("signatures")
    minisig = signatures.get("minisign_signature") if isinstance(signatures, dict) else None
    if not isinstance(minisig, str) or not minisig.strip() or any(
        ord(char) < 0x20 or ord(char) == 0x7F for char in minisig
    ):
        die("Unsigned rollback authorization.")
    pubkey = Path(
        _expected("NEOSECRA_SIGNATURE_PUBKEY")
        or str(v1_root / "ca" / "update-neosecra-com.pub")
    )
    if not pubkey.is_file() or not pubkey.stat().st_size:
        die(f"Trusted public key not found: {pubkey}")
    canonical = dict(auth)
    canonical.pop("signatures", None)
    canonical_json = json.dumps(canonical, separators=(",", ":"), sort_keys=True)
    try:
        with tempfile.TemporaryDirectory(prefix="neosecra-rollback-") as temp_dir:
            temp = Path(temp_dir)
            payload_path = temp / "rollback.json"
            sig_path = temp / "rollback.json.minisig"
            payload_path.write_text(canonical_json, encoding="utf-8")
            sig_path.write_text(
                "untrusted comment: rollback authorization\n"
                + minisig.strip()
                + "\n",
                encoding="utf-8",
            )
            try:
                result = subprocess.run(
                    ["minisign", "-Vm", str(payload_path), "-p", str(pubkey), "-x", str(sig_path), "-q"],
                    capture_output=True,
                    text=True,
                    check=False,
                )
            except OSError as exc:
                die(f"minisign is unavailable: {exc}")
            if result.returncode != 0:
                detail = (result.stderr or "").strip()
                die(f"Invalid rollback authorization signature{': ' + detail if detail else ''}")
    except OSError as exc:
        die(f"Rollback authorization verification failed: {exc}")


def main() -> None:
    if len(sys.argv) != 3:
        die("Usage: python3 verify_rollback_auth.py <auth.json> <target_version>")
    auth_path = Path(sys.argv[1])
    if not auth_path.is_file():
        die("Rollback authorization file missing.")
    auth = _load(auth_path)
    target = _version(sys.argv[2])
    authorized = _version(auth.get("rollback_to"))
    if authorized != target:
        die(f"Rollback authorization is for {authorized}, not {target}")

    # Keep the historical error for a completely unsigned object, but never
    # allow a signed-looking object without a mandatory expiry.
    signatures = auth.get("signatures")
    if not auth.get("expires_at") and not (
        isinstance(signatures, dict) and signatures.get("minisign_signature")
    ):
        die("Unsigned rollback authorization.")
    expires_at = _timestamp(auth.get("expires_at"))
    if datetime.now(timezone.utc) >= expires_at:
        die("Rollback authorization has expired.")

    product = str(auth.get("product") or "").strip().lower()
    channel = str(auth.get("channel") or "").strip().lower()
    edition = str(auth.get("edition") or "").strip().lower()
    nonce = str(auth.get("nonce") or "").strip()
    if not product or not re.fullmatch(r"[a-z0-9][a-z0-9_-]{0,63}", product):
        die("Rollback authorization product binding is invalid")
    if not channel or not re.fullmatch(r"[a-z0-9][a-z0-9_-]{0,127}", channel):
        die("Rollback authorization channel binding is invalid")
    if not edition or not re.fullmatch(r"[a-z0-9][a-z0-9_-]{0,63}", edition):
        die("Rollback authorization edition binding is invalid")
    if not NONCE_RE.fullmatch(nonce):
        die("Rollback authorization nonce is invalid")

    expected_product = _expected("EXPECTED_ROLLBACK_PRODUCT", ("NEOSECRA_EXPECTED_PRODUCT",))
    expected_channel = _expected("EXPECTED_ROLLBACK_CHANNEL", ("NEOSECRA_EXPECTED_CHANNEL",))
    expected_edition = _expected("EXPECTED_ROLLBACK_EDITION", ("NEOSECRA_EXPECTED_EDITION",))
    expected_nonce = _expected("EXPECTED_ROLLBACK_NONCE", ("NEOSECRA_ROLLBACK_NONCE",))
    if expected_product and product != expected_product.lower():
        die("Rollback authorization product binding mismatch")
    if expected_channel and channel != expected_channel.lower():
        die("Rollback authorization channel binding mismatch")
    if expected_edition and edition != expected_edition.lower():
        die("Rollback authorization edition binding mismatch")
    if expected_nonce and nonce != expected_nonce:
        die("Rollback authorization nonce binding mismatch")

    v1_root = Path(os.environ.get("V1_ROOT", "/opt/neosecra/distribution/deployment/v1"))
    _verify_signature(auth, auth_path, v1_root)
    print("Rollback authorization securely verified.")


if __name__ == "__main__":
    main()
