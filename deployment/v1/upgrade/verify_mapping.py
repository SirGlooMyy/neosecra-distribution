"""Verify compose services against a signed channel release entry.

The verifier is intentionally independent of Docker. It receives the
resolved ``docker compose config --format json`` document on stdin and emits a
small, line-oriented decision stream consumed by ``upgrade.sh``. Every image
and dependency must have an exact reference and immutable digest; legacy
allow-list handling is restricted to the two explicitly supported product
channels and is still bound to the archive digest and expiry.
"""

from __future__ import annotations

import datetime as dt
import json
import os
import re
import sys
from pathlib import Path
from typing import Any, NoReturn


SEMVER_RE = re.compile(r"^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$")
DIGEST_RE = re.compile(r"^sha256:[0-9a-f]{64}$")
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
SAFE_NAME_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{0,127}$")
LEGACY_CHANNELS = {"assessment-stable", "hotspot-stable"}


def fail(message: str) -> NoReturn:
    print(f"SECURITY VIOLATION: {message}", file=sys.stderr)
    raise SystemExit(4)


def _load_json(raw: str, label: str) -> dict[str, Any]:
    try:
        value = json.loads(raw)
    except (TypeError, ValueError) as exc:
        fail(f"Invalid {label} JSON: {exc}")
    if not isinstance(value, dict):
        fail(f"{label} must be a JSON object")
    return value


def _normal_version(value: object, *, label: str) -> str:
    text = str(value or "").strip()
    normalized = text.lstrip("vV")
    if not SEMVER_RE.fullmatch(normalized):
        fail(f"Invalid {label} version")
    return normalized


def _parse_expiry(value: object) -> dt.datetime:
    text = str(value or "").strip()
    if not text:
        fail("Legacy allowlist expiry is required")
    try:
        parsed = dt.datetime.fromisoformat(text.replace("Z", "+00:00"))
    except (TypeError, ValueError) as exc:
        fail(f"Invalid legacy allowlist expiry: {exc}")
    if parsed.tzinfo is None:
        fail("Legacy allowlist expiry must include a timezone")
    return parsed.astimezone(dt.timezone.utc)


def _archive_sha256(release: dict[str, Any]) -> str:
    archive = release.get("archive")
    if isinstance(archive, dict):
        value = archive.get("sha256")
    else:
        value = release.get("sha256")
    return str(value or "").strip().lower()


def _validate_reference(value: object, label: str) -> str:
    if not isinstance(value, str):
        fail(f"{label} reference is missing")
    ref = value.strip()
    if not ref or ref != value or any(ord(ch) < 0x20 or ord(ch) == 0x7F for ch in ref):
        fail(f"{label} reference is invalid")
    if "@" in ref or ref.lower() != ref:
        fail(f"{label} reference must be an unpinned lowercase image reference")
    if ref.endswith(":latest"):
        fail(f"{label} reference must not use latest")
    return ref


def _validate_digest(value: object, label: str) -> str:
    digest = str(value or "").strip()
    if not DIGEST_RE.fullmatch(digest):
        fail(f"{label} digest is not an immutable sha256 digest")
    return digest


def _release_entry(channel: dict[str, Any], target: str) -> tuple[dict[str, Any], str, str]:
    channel_name = str(channel.get("channel") or "").strip().lower()
    product = str(channel.get("product_code") or channel.get("product") or "").strip().lower()
    if not channel_name or not SAFE_NAME_RE.fullmatch(channel_name):
        fail("Channel identity is missing or invalid")
    if not product or not SAFE_NAME_RE.fullmatch(product):
        fail("Product identity is missing or invalid")
    status = str(channel.get("status") or "").strip().lower()
    if status not in {"available", "ready"}:
        fail(f"Channel status is not promotable: {status or 'missing'}")
    edition = str(channel.get("edition") or "").strip().lower()
    if not edition or not SAFE_NAME_RE.fullmatch(edition):
        fail("Channel edition is missing or invalid")
    expected_channel = str(os.environ.get("EXPECTED_CHANNEL") or "").strip().lower()
    if expected_channel and channel_name != expected_channel:
        fail(f"Channel binding mismatch: expected {expected_channel}, got {channel_name}")
    expected_product = str(os.environ.get("EXPECTED_PRODUCT") or "").strip().lower()
    if expected_product and product != expected_product:
        fail(f"Product binding mismatch: expected {expected_product}, got {product}")

    releases = channel.get("releases")
    if not isinstance(releases, list):
        fail("Channel releases must be an array")
    target_norm = _normal_version(target, label="target")
    matches = []
    for item in releases:
        if not isinstance(item, dict):
            fail("Channel release entry is invalid")
        if _normal_version(item.get("version"), label="release") == target_norm:
            matches.append(item)
    if len(matches) != 1:
        fail(f"Target {target_norm} is not uniquely present in the channel")
    current = channel.get("current_version")
    if status == "available":
        current_norm = _normal_version(current, label="current")
        if not any(_normal_version(item.get("version"), label="release") == current_norm for item in releases):
            fail("Channel current_version is not present in releases")
    minimum = channel.get("minimum_current_version")
    if minimum not in (None, ""):
        minimum_norm = _normal_version(minimum, label="minimum_current")
        installed = os.environ.get("CURRENT_VERSION", "").strip()
        if installed:
            installed_norm = _normal_version(installed, label="installed")
            if tuple(map(int, re.match(r"^(\d+)\.(\d+)\.(\d+)", installed_norm).groups())) < tuple(map(int, re.match(r"^(\d+)\.(\d+)\.(\d+)", minimum_norm).groups())):
                fail(f"Installed version {installed_norm} is below channel minimum {minimum_norm}")
    return matches[0], channel_name, product


def _legacy_check(
    channel: dict[str, Any],
    release: dict[str, Any],
    channel_name: str,
    product: str,
    target: str,
    *,
    has_image_mapping: bool = False,
) -> bool:
    if channel_name not in LEGACY_CHANNELS:
        return False
    # The two legacy channels may carry newer releases with a complete image
    # map.  Those releases must use the strict digest/signature path below;
    # the allowlist is only a compatibility escape hatch for old entries that
    # predate image metadata.
    if has_image_mapping:
        return False
    path_value = str(os.environ.get("LEGACY_ALLOWLIST") or "").strip()
    if not path_value:
        fail(f"Legacy channel {channel_name} requires an allowlist")
    path = Path(path_value)
    if not path.is_file():
        fail("Legacy allowlist is missing")
    try:
        with path.open(encoding="utf-8") as stream:
            allowlist = json.load(stream)
    except (OSError, ValueError) as exc:
        fail(f"Invalid legacy allowlist: {exc}")
    if not isinstance(allowlist, dict):
        fail("Legacy allowlist must be a JSON object")
    entry = allowlist.get(channel_name)
    if not isinstance(entry, dict) or str(entry.get("product") or "").strip().lower() != product:
        fail("Legacy allowlist product binding mismatch")
    releases = entry.get("releases")
    if not isinstance(releases, dict):
        fail("Legacy allowlist releases must be an object")
    target_norm = _normal_version(target, label="target")
    release_policy = None
    for version, policy in releases.items():
        if _normal_version(version, label="allowlist") == target_norm:
            release_policy = policy
            break
    if not isinstance(release_policy, dict):
        fail(f"Legacy release {target_norm} is not allow-listed")

    allowed_sha = str(release_policy.get("archive_sha256") or "").strip().lower()
    if not SHA256_RE.fullmatch(allowed_sha):
        fail("Legacy allowlist archive digest is invalid")
    release_sha = _archive_sha256(release)
    if release_sha and (not SHA256_RE.fullmatch(release_sha) or release_sha != allowed_sha):
        fail("Legacy release archive digest does not match allowlist")
    supplied_sha = str(os.environ.get("ARCHIVE_SHA256") or "").strip().lower()
    if supplied_sha and supplied_sha != allowed_sha:
        fail("Legacy archive digest does not match the verified payload")

    expires_at = _parse_expiry(release_policy.get("expires_at"))
    if dt.datetime.now(dt.timezone.utc) >= expires_at:
        fail("Legacy allowlist entry has expired")
    print(f"AUDIT_LOG Legacy policy applied for {channel_name} {target_norm}")
    return True


def _image_sets(release: dict[str, Any], product: str) -> tuple[dict[str, Any], dict[str, Any]]:
    images = release.get("images")
    dependencies = release.get("dependencies")
    if images is None and dependencies is None and isinstance(release.get("components"), dict):
        component = release["components"].get(product)
        if isinstance(component, dict):
            images = component.get("images")
            dependencies = component.get("dependencies")
    images = {} if images is None else images
    dependencies = {} if dependencies is None else dependencies
    if not isinstance(images, dict) or not isinstance(dependencies, dict):
        fail("Release images and dependencies must be objects")
    if set(images).intersection(dependencies):
        fail("A service cannot be both an application image and a dependency")
    return images, dependencies


def main() -> None:
    channel = _load_json(os.environ.get("CHANNEL_JSON", ""), "channel")
    target = os.environ.get("TARGET", "")
    if not target:
        fail("Target version is required")
    try:
        compose = json.load(sys.stdin)
    except (OSError, ValueError) as exc:
        fail(f"Invalid compose JSON: {exc}")
    if not isinstance(compose, dict):
        fail("Compose config must be a JSON object")
    services = compose.get("services")
    if not isinstance(services, dict) or not services:
        fail("No services found in compose config")
    for service_name, service in services.items():
        if not isinstance(service_name, str) or not SAFE_NAME_RE.fullmatch(service_name):
            fail("Compose contains an invalid service name")
        if not isinstance(service, dict):
            fail(f"Compose service {service_name} is invalid")

    release, channel_name, product = _release_entry(channel, target)
    images, dependencies = _image_sets(release, product)
    legacy = _legacy_check(
        channel,
        release,
        channel_name,
        product,
        target,
        has_image_mapping=bool(images or dependencies),
    )

    # A legacy release may be explicitly allow-listed only when no image map
    # exists. It is still bound to product/channel/version/digest/expiry above;
    # any supplied image/dependency map is checked strictly.
    if legacy and not images and not dependencies:
        return
    if not images and not dependencies:
        fail("Release has no image/dependency mapping")

    manifest_services = set(images) | set(dependencies)
    compose_services = set(services)
    if manifest_services != compose_services:
        fail("Compose services do not exactly match the release image mapping")

    seen_digests: dict[str, tuple[str, str]] = {}
    for service_name in sorted(compose_services):
        service = services[service_name]
        raw_ref = service.get("image")
        if not isinstance(raw_ref, str) or not raw_ref.strip():
            fail(f"Compose service {service_name} has no image")
        compose_ref = raw_ref.strip()
        if compose_ref != raw_ref:
            fail(f"Compose service {service_name} image reference contains whitespace")
        base_ref, at, pinned = compose_ref.partition("@")
        base_ref = _validate_reference(base_ref, f"Compose service {service_name}")
        # A manifest digest is not enough on its own: Compose must resolve the
        # exact immutable reference as well.  Accepting a tag-only compose
        # value would allow a mutable registry tag to be promoted after the
        # manifest was signed.
        if at != "@" or not DIGEST_RE.fullmatch(pinned):
            fail(
                f"Compose service {service_name} must use an immutable "
                "@sha256:<64-hex> image reference"
            )

        section = images if service_name in images else dependencies
        label = f"{service_name} {'image' if service_name in images else 'dependency'}"
        metadata = section.get(service_name)
        if not isinstance(metadata, dict):
            fail(f"{label} metadata is invalid")
        expected_ref = _validate_reference(metadata.get("reference"), label)
        expected_digest = _validate_digest(metadata.get("digest"), label)
        if base_ref != expected_ref:
            fail(f"{label} reference does not match compose")
        if pinned != expected_digest:
            fail(f"{label} compose digest does not match the release")
        if service_name in images:
            if expected_digest in seen_digests:
                previous_service, previous_ref = seen_digests[expected_digest]
                allowed_shared = {previous_service, service_name} <= {"backend", "worker", "beat"}
                if not allowed_shared or previous_ref != expected_ref:
                    fail(f"Duplicate application image digest for {service_name}")
            else:
                seen_digests[expected_digest] = (service_name, expected_ref)
            print(f"ENFORCE {service_name} {base_ref} {expected_digest}")
        else:
            print(f"DEPENDENCY {service_name} {base_ref} {expected_digest}")


if __name__ == "__main__":
    main()
