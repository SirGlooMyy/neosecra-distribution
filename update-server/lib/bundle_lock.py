#!/usr/bin/env python3
"""Build the package-authenticated product offline bundle lock.

The Docker save archive is the only source of configuration IDs used by the
offline consumer.  This helper deliberately requires every images.lock
reference to appear as an exact RepoTag in manifest.json and verifies each
configuration JSON hash before it writes the package lock.
"""

from __future__ import annotations

import argparse
import copy
import hashlib
import io
import gzip
from contextlib import ExitStack
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import subprocess
import tarfile
import tempfile
import re


SERVICES = ()
SHARED_SERVICES = ()
DIGEST_RE = re.compile(r"^sha256:[0-9a-f]{64}$")


def fail(message: str) -> "NoReturn":
    raise SystemExit(f"[ERROR] {message}")


def safe_member_name(name: str) -> str:
    if not name or "\\" in name:
        fail(f"unsafe archive member path: {name!r}")
    path = PurePosixPath(name)
    if path.is_absolute() or any(part in {"", ".", ".."} for part in path.parts):
        fail(f"unsafe archive member path: {name!r}")
    return path.as_posix()


def compression_suffix(path: Path) -> str:
    name = path.name.lower()
    for suffix in (".tar.gz", ".tgz", ".tar.bz2", ".tbz2", ".tar.xz", ".txz", ".tar.zst", ".tzst", ".tar"):
        if name.endswith(suffix):
            return suffix
    return ""


class TarReader:
    def __init__(self, path: Path):
        self.path = path
        self._temporary: Path | None = None
        self._tar: tarfile.TarFile | None = None

    def __enter__(self) -> tarfile.TarFile:
        suffix = compression_suffix(self.path)
        if suffix in {".tar.zst", ".tzst"}:
            zstd = shutil.which("zstd") or shutil.which("unzstd")
            if not zstd:
                fail("zstd is required to inspect .tar.zst Docker bundles")
            handle = tempfile.NamedTemporaryFile(prefix="neosecra-bundle-", suffix=".tar", delete=False)
            self._temporary = Path(handle.name)
            try:
                with handle:
                    result = subprocess.run(
                        [zstd, "-q", "-d", "-c", str(self.path)],
                        stdout=handle,
                        stderr=subprocess.PIPE,
                        check=False,
                    )
                if result.returncode != 0:
                    fail(f"could not decompress Docker bundle: {result.stderr.decode(errors='replace').strip()}")
                self._tar = tarfile.open(self._temporary, "r:")
            except BaseException:
                self.close()
                raise
        else:
            try:
                self._tar = tarfile.open(self.path, "r:*")
            except (OSError, tarfile.TarError) as exc:
                fail(f"could not read tar archive {self.path}: {exc}")
        return self._tar

    def close(self) -> None:
        if self._tar is not None:
            self._tar.close()
            self._tar = None
        if self._temporary is not None:
            self._temporary.unlink(missing_ok=True)
            self._temporary = None

    def __exit__(self, exc_type, exc, tb) -> None:
        self.close()


def member_bytes(tar: tarfile.TarFile, member: tarfile.TarInfo) -> bytes:
    if not member.isfile() or member.issym() or member.islnk():
        fail(f"Docker bundle member is not a regular file: {member.name}")
    stream = tar.extractfile(member)
    if stream is None:
        fail(f"Docker bundle member could not be read: {member.name}")
    return stream.read()


def parse_images_lock(path: Path) -> dict[str, str]:
    rows: dict[str, str] = {}
    for lineno, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            fail(f"invalid images.lock line {lineno}")
        name, value = (part.strip() for part in line.split("=", 1))
        if name in rows or name not in SERVICES or value.count("@") != 1:
            fail(f"invalid or duplicate images.lock entry at line {lineno}")
        reference, digest = value.rsplit("@", 1)
        if not reference or not DIGEST_RE.fullmatch(digest):
            fail(f"images.lock entry is not immutable at line {lineno}")
        rows[name] = value
    if set(rows) != set(SERVICES):
        fail("images.lock must contain exactly the registered services")
    for group in SHARED_SERVICES:
        if len({rows[name] for name in group}) != 1:
            fail("registered shared services must share one images.lock reference")
    return rows


def config_id_from_name(name: str) -> str | None:
    path = PurePosixPath(name)
    base = path.name
    if base.endswith(".json"):
        base = base[:-5]
    if base.startswith("sha256:"):
        digest = base[7:]
    elif re.fullmatch(r"[0-9a-f]{64}", base):
        digest = base
    elif len(path.parts) >= 2 and path.parts[-2] == "sha256" and re.fullmatch(r"[0-9a-f]{64}", base):
        digest = base
    else:
        return None
    return f"sha256:{digest}"


def bundle_configurations(bundle: Path, image_rows: dict[str, str]) -> dict[str, str]:
    with TarReader(bundle) as tar:
        members: dict[str, tarfile.TarInfo] = {}
        for member in tar.getmembers():
            name = safe_member_name(member.name)
            if name in members:
                fail(f"Docker bundle contains duplicate member: {name}")
            members[name] = member
            if member.issym() or member.islnk() or (not member.isdir() and not member.isfile()):
                fail(f"Docker bundle contains unsafe member: {name}")

        manifests = [member for member in members.values() if PurePosixPath(member.name).name == "manifest.json"]
        if len(manifests) != 1:
            fail("Docker bundle must contain exactly one manifest.json")
        try:
            manifest = json.loads(member_bytes(tar, manifests[0]).decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            fail(f"Docker bundle manifest.json is invalid: {exc}")
        if not isinstance(manifest, list) or not manifest:
            fail("Docker bundle manifest.json must be a non-empty array")

        tag_to_config: dict[str, str] = {}
        for entry in manifest:
            if not isinstance(entry, dict) or not isinstance(entry.get("RepoTags"), list):
                continue
            config_name = entry.get("Config")
            if not isinstance(config_name, str):
                fail("Docker bundle manifest entry has no Config")
            config_name = safe_member_name(config_name)
            config_member = members.get(config_name)
            if config_member is None:
                matches = [member for name, member in members.items() if PurePosixPath(name).name == PurePosixPath(config_name).name]
                if len(matches) != 1:
                    fail(f"Docker bundle config is missing or ambiguous: {config_name}")
                config_member = matches[0]
                config_name = safe_member_name(config_member.name)
            config_id = config_id_from_name(config_name)
            if config_id is None:
                fail(f"Docker bundle config name is not a sha256 ID: {config_name}")
            config_bytes = member_bytes(tar, config_member)
            if hashlib.sha256(config_bytes).hexdigest() != config_id[7:]:
                fail(f"Docker bundle config content does not match its ID: {config_name}")
            tags = entry["RepoTags"]
            for tag in tags:
                if not isinstance(tag, str) or not tag:
                    fail("Docker bundle contains an invalid RepoTag")
                previous = tag_to_config.get(tag)
                if previous is not None and previous != config_id:
                    fail(f"Docker bundle RepoTag maps to multiple configs: {tag}")
                tag_to_config[tag] = config_id

    result: dict[str, str] = {}
    for service in SERVICES:
        reference = image_rows[service].rsplit("@", 1)[0]
        config_id = tag_to_config.get(reference)
        if config_id is None:
            fail(f"Docker bundle is missing the images.lock RepoTag for {service}: {reference}")
        result[service] = config_id
    for group in SHARED_SERVICES:
        if len({result[name] for name in group}) != 1:
            fail("Docker bundle shared configuration IDs do not match")
    return result


def package_member_data(archive: Path) -> tuple[list[tuple[tarfile.TarInfo, bytes | None]], str, str, bytes]:
    with TarReader(archive) as tar:
        members: list[tuple[tarfile.TarInfo, bytes | None]] = []
        seen: set[str] = set()
        for member in tar.getmembers():
            name = safe_member_name(member.name)
            if name in seen:
                fail(f"package archive contains duplicate member: {name}")
            seen.add(name)
            if member.issym() or member.islnk() or (not member.isdir() and not member.isfile()):
                fail(f"package archive contains unsafe member: {name}")
            data = member_bytes(tar, member) if member.isfile() else None
            members.append((copy.copy(member), data))

    image_paths = [member.name for member, _ in members if PurePosixPath(member.name).parts[-2:] == ("release", "images.lock")]
    checksum_paths = [member.name for member, _ in members if PurePosixPath(member.name).parts[-2:] == ("release", "checksums.sha256")]
    if len(image_paths) != 1 or len(checksum_paths) != 1:
        fail("product package must contain exactly one release/images.lock and checksums.sha256")
    image_path = image_paths[0]
    prefix = image_path[: -(len("release/images.lock"))].rstrip("/")
    checksum_path = checksum_paths[0]
    if checksum_path != f"{prefix}/release/checksums.sha256" if prefix else checksum_path != "release/checksums.sha256":
        fail("product package release files do not share one package root")
    image_data = next(data for member, data in members if member.name == image_path)
    if image_data is None:
        fail("release/images.lock is not a regular file")
    checksum_data = next(data for member, data in members if member.name == checksum_path)
    if checksum_data is None:
        fail("release/checksums.sha256 is not a regular file")
    return members, prefix, checksum_path, image_data


def package_image_rows(image_data: bytes) -> dict[str, str]:
    temporary = tempfile.NamedTemporaryFile(prefix="neosecra-images-lock-", delete=False)
    path = Path(temporary.name)
    try:
        with temporary:
            temporary.write(image_data)
        return parse_images_lock(path)
    finally:
        path.unlink(missing_ok=True)


def rewrite_package(archive: Path, output: Path, generated_lock: bytes, expected_rows: dict[str, str]) -> None:
    members, prefix, checksum_path, image_data = package_member_data(archive)
    if package_image_rows(image_data) != expected_rows:
        fail("package release/images.lock does not exactly match the publisher input")
    lock_path = f"{prefix}/release/bundle.lock" if prefix else "release/bundle.lock"
    data_by_name = {member.name: data for member, data in members}
    existing = data_by_name.get(lock_path)
    if existing is not None and existing != generated_lock:
        fail("package already contains a different release/bundle.lock")
    data_by_name[lock_path] = generated_lock

    payload_names = []
    for member, data in members:
        if data is None:
            continue
        if member.name == checksum_path:
            continue
        relative = member.name[len(prefix) + 1 :] if prefix else member.name
        payload_names.append((relative, data))
    if lock_path not in {member.name for member, _ in members}:
        relative = lock_path[len(prefix) + 1 :] if prefix else lock_path
        payload_names.append((relative, generated_lock))
    payload_names.sort(key=lambda item: item[0])
    checksum_bytes = "".join(
        f"{hashlib.sha256(data).hexdigest()} *{relative}\n" for relative, data in payload_names
    ).encode("utf-8")
    data_by_name[checksum_path] = checksum_bytes

    if existing == generated_lock and data_by_name[checksum_path] == next(data for member, data in members if member.name == checksum_path):
        shutil.copyfile(archive, output)
        return
    suffix = compression_suffix(archive)
    output.parent.mkdir(parents=True, exist_ok=True)
    if suffix in {".tar.zst", ".tzst"}:
        zstd = shutil.which("zstd") or shutil.which("unzstd")
        if not zstd:
            fail("zstd is required to rewrite .tar.zst product packages")
        with tempfile.TemporaryDirectory(prefix="neosecra-package-") as temp_dir:
            raw_tar = Path(temp_dir) / "package.tar"
            write_tar(members, data_by_name, raw_tar, "")
            with output.open("wb") as stream:
                result = subprocess.run([zstd, "-q", "-c", str(raw_tar)], stdout=stream, stderr=subprocess.PIPE, check=False)
            if result.returncode != 0:
                fail(f"could not compress product package: {result.stderr.decode(errors='replace').strip()}")
    else:
        write_tar(members, data_by_name, output, suffix)


def write_tar(members: list[tuple[tarfile.TarInfo, bytes | None]], data_by_name: dict[str, bytes], output: Path, suffix: str) -> None:
    mode = {".tar.gz": "w:gz", ".tgz": "w:gz", ".tar.bz2": "w:bz2", ".tbz2": "w:bz2", ".tar.xz": "w:xz", ".txz": "w:xz"}.get(suffix, "w:")
    with ExitStack() as stack:
        if mode == "w:gz":
            stream = stack.enter_context(output.open("wb"))
            compressed = stack.enter_context(gzip.GzipFile(filename="", mode="wb", fileobj=stream, mtime=0))
            tar = stack.enter_context(tarfile.open(fileobj=compressed, mode="w:"))
        else:
            tar = stack.enter_context(tarfile.open(output, mode))
        for original, data in members:
            member = copy.copy(original)
            if member.isfile():
                replacement = data_by_name.get(member.name)
                if replacement is None:
                    fail(f"missing package payload while rewriting: {member.name}")
                member.size = len(replacement)
                tar.addfile(member, io.BytesIO(replacement))
            else:
                tar.addfile(member)
        known = {member.name for member, _ in members}
        lock_names = [name for name in data_by_name if name not in known]
        for name in sorted(lock_names):
            payload = data_by_name[name]
            member = tarfile.TarInfo(name)
            member.mode = 0o644
            member.mtime = 0
            member.size = len(payload)
            tar.addfile(member, io.BytesIO(payload))


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--registry", type=Path, required=True)
    parser.add_argument("--bundle", type=Path, required=True)
    parser.add_argument("--images-lock", type=Path, required=True)
    parser.add_argument("--archive", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    global SERVICES, SHARED_SERVICES
    contract = json.loads(args.registry.read_text(encoding="utf-8"))["images_lock"]
    SERVICES = tuple(contract["services"])
    SHARED_SERVICES = tuple(contract["shared_services"])
    if not args.bundle.is_file() or args.bundle.is_symlink():
        fail("Docker bundle is missing or unsafe")
    if not args.archive.is_file() or args.archive.is_symlink():
        fail("product package archive is missing or unsafe")
    if args.output.resolve() == args.archive.resolve():
        fail("package rewrite output must be separate from the input archive")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    image_rows = parse_images_lock(args.images_lock)
    configs = bundle_configurations(args.bundle, image_rows)
    bundle_sha = hashlib.sha256(args.bundle.read_bytes()).hexdigest()
    lines = ["format=1", f"bundle_sha256={bundle_sha}"]
    lines.extend(f"{service}={image_rows[service]}|{configs[service]}" for service in SERVICES)
    rewrite_package(args.archive, args.output, ("\n".join(lines) + "\n").encode("utf-8"), image_rows)


if __name__ == "__main__":
    main()
