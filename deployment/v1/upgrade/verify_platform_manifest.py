"""Fail-closed verification for the signed platform release manifest."""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, NoReturn

import jsonschema
import yaml
from jsonschema import Draft7Validator, FormatChecker


def die(message: str, code: int = 4) -> NoReturn:
    print(f"SECURITY VIOLATION: {message}", file=sys.stderr)
    raise SystemExit(code)


def _load_document(path: Path) -> dict[str, Any]:
    try:
        with path.open(encoding="utf-8") as stream:
            value = yaml.safe_load(stream)
    except (OSError, UnicodeError, yaml.YAMLError) as exc:
        die(f"Invalid platform manifest: {exc}")
    if not isinstance(value, dict):
        die("Platform manifest must be a JSON/YAML object")
    return value


def _schema_path(v1_root: Path) -> Path:
    candidates = []
    configured = str(os.environ.get("NEOSECRA_PLATFORM_SCHEMA") or "").strip()
    if configured:
        candidates.append(Path(configured))
    # Source checkout: deployment/v1 -> ../../schemas. Installed payloads may
    # carry the schema beside v1 or under v1/schemas.
    candidates.extend(
        (
            v1_root.parent.parent / "schemas" / "platform-release-manifest.schema.json",
            v1_root.parent / "schemas" / "platform-release-manifest.schema.json",
            v1_root / "schemas" / "platform-release-manifest.schema.json",
            Path(__file__).resolve().parents[3] / "schemas" / "platform-release-manifest.schema.json",
        )
    )
    for candidate in candidates:
        if candidate.is_file():
            return candidate
    die("Platform manifest schema is missing")


def _parse_timestamp(value: object, field: str) -> datetime:
    text = str(value or "").strip()
    if not text:
        die(f"Platform manifest {field} is required")
    try:
        parsed = datetime.fromisoformat(text.replace("Z", "+00:00"))
    except (TypeError, ValueError) as exc:
        die(f"Platform manifest {field} is invalid: {exc}")
    if parsed.tzinfo is None:
        die(f"Platform manifest {field} must include a timezone")
    return parsed.astimezone(timezone.utc)


def _read_state(path: Path) -> dict[str, Any] | None:
    if not path.exists():
        return None
    try:
        with path.open(encoding="utf-8") as stream:
            value = json.load(stream)
    except (OSError, UnicodeError, ValueError) as exc:
        die(f"Release state is malformed: {exc}")
    if not isinstance(value, dict):
        die("Release state must be a JSON object")
    if value.get("released_at") is not None:
        _parse_timestamp(value.get("released_at"), "state.released_at")
    if not value.get("platform_version") or not value.get("channel"):
        die("Release state is incomplete")
    return value


def _verify_signature(manifest: dict[str, Any], manifest_path: Path, v1_root: Path) -> None:
    signatures = manifest.get("signatures")
    if not isinstance(signatures, dict):
        die("Unsigned platform manifest: signatures block is missing")
    minisig = signatures.get("minisign_signature")
    if not isinstance(minisig, str) or not minisig.strip() or any(
        ord(char) < 0x20 or ord(char) == 0x7F for char in minisig
    ):
        die("Unsigned platform manifest: minisign signature is missing")

    pubkey_value = str(
        os.environ.get("NEOSECRA_SIGNATURE_PUBKEY")
        or (v1_root / "ca" / "update-neosecra-com.pub")
    ).strip()
    pubkey = Path(pubkey_value)
    if not pubkey.is_file() or not pubkey.stat().st_size:
        die(f"Trusted public key not found: {pubkey}")

    canonical = dict(manifest)
    canonical.pop("signatures", None)
    canonical_json = json.dumps(canonical, separators=(",", ":"), sort_keys=True)
    try:
        with tempfile.TemporaryDirectory(prefix="neosecra-manifest-") as temp_dir:
            temp = Path(temp_dir)
            canonical_path = temp / "manifest.json"
            sig_path = temp / "manifest.json.minisig"
            canonical_path.write_text(canonical_json, encoding="utf-8")
            sig_path.write_text(
                "untrusted comment: signature from neosecra\n"
                + minisig.strip()
                + "\n",
                encoding="utf-8",
            )
            try:
                result = subprocess.run(
                    ["minisign", "-Vm", str(canonical_path), "-p", str(pubkey), "-x", str(sig_path), "-q"],
                    capture_output=True,
                    text=True,
                    check=False,
                )
            except OSError as exc:
                die(f"minisign is unavailable: {exc}")
            if result.returncode != 0:
                detail = (result.stderr or "").strip()
                die(f"Invalid platform manifest signature{': ' + detail if detail else ''}")
    except OSError as exc:
        die(f"Platform manifest signature verification failed: {exc}")


def _validate_and_verify(manifest_path: Path, v1_root: Path) -> tuple[dict[str, Any], datetime]:
    manifest = _load_document(manifest_path)
    schema_path = _schema_path(v1_root)
    try:
        with schema_path.open(encoding="utf-8") as stream:
            schema = json.load(stream)
        Draft7Validator(schema, format_checker=FormatChecker()).validate(manifest)
    except (OSError, UnicodeError, ValueError, jsonschema.SchemaError) as exc:
        die(f"Platform manifest schema could not be loaded: {exc}")
    except jsonschema.ValidationError as exc:
        die(f"Manifest schema validation failed: {exc.message}")

    released_at = _parse_timestamp(manifest.get("released_at"), "released_at")
    _verify_signature(manifest, manifest_path, v1_root)
    expected_channel = str(os.environ.get("EXPECTED_CHANNEL") or "").strip()
    if expected_channel and manifest.get("channel") != expected_channel:
        die(f"Channel binding mismatch. Expected {expected_channel}, got {manifest.get('channel')}")
    expected_version = str(os.environ.get("EXPECTED_PLATFORM_VERSION") or "").strip()
    if expected_version and manifest.get("platform_version") != expected_version:
        die(
            f"Platform version binding mismatch. Expected {expected_version}, "
            f"got {manifest.get('platform_version')}"
        )
    return manifest, released_at


def _commit_state(path: Path, manifest: dict[str, Any], released_at: datetime) -> None:
    current = _read_state(path)
    if current:
        previous = _parse_timestamp(current.get("released_at"), "state.released_at")
        if released_at < previous:
            die("Downgrade/Replay attack detected: manifest is older than accepted state")
    state = {
        "platform_version": manifest["platform_version"],
        "released_at": released_at.isoformat().replace("+00:00", "Z"),
        "channel": manifest["channel"],
    }
    path.parent.mkdir(parents=True, exist_ok=True)
    temp_path = path.with_name(f"{path.name}.new.{os.getpid()}")
    try:
        with temp_path.open("w", encoding="utf-8") as stream:
            json.dump(state, stream, sort_keys=True, separators=(",", ":"))
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temp_path, 0o600)
        os.replace(temp_path, path)
    except OSError as exc:
        try:
            temp_path.unlink(missing_ok=True)
        except OSError:
            pass
        die(f"Release state commit failed: {exc}")


def main() -> None:
    if len(sys.argv) != 3 or sys.argv[1] not in {"--verify", "--commit"}:
        die("Usage: python3 verify_platform_manifest.py [--verify|--commit] <manifest.json>")
    manifest_path = Path(sys.argv[2])
    if not manifest_path.is_file():
        die(f"Manifest not found: {manifest_path}")
    v1_root = Path(os.environ.get("V1_ROOT", "/opt/neosecra/distribution/deployment/v1"))
    manifest, released_at = _validate_and_verify(manifest_path, v1_root)
    state_file = v1_root / ".release_state.json"
    current = _read_state(state_file)
    if current and released_at < _parse_timestamp(current.get("released_at"), "state.released_at"):
        die("Downgrade/Replay attack detected: manifest is older than accepted state")
    if sys.argv[1] == "--commit":
        _commit_state(state_file, manifest, released_at)
        print("Atomic state commit successful.")
    else:
        print("Manifest securely verified.")


if __name__ == "__main__":
    main()
