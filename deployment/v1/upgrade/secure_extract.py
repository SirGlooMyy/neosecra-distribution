#!/usr/bin/env python3
"""Bounded, fail-closed extraction for signed distribution artifacts.

The updater receives archives from a signed channel, but a valid signature does
not make a tar member safe to extract.  This module validates every member
before writing it and only permits regular files and directories below the
expected release/bundle layout.  It deliberately does not follow archive
links, overwrite existing files, or honour archive ownership/mode bits.
"""

from __future__ import annotations

import os
import re
import stat
import subprocess
import sys
import tarfile
from pathlib import Path, PurePosixPath
from typing import NoReturn


MAX_MEMBERS = 10_000
MAX_MEMBER_BYTES = 2 * 1024 * 1024 * 1024
MAX_TOTAL_BYTES = 4 * 1024 * 1024 * 1024
MAX_COMPRESSED_BYTES = 2 * 1024 * 1024 * 1024
SAFE_COMPONENT = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
SEMVER = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?$")


def _safe_component(part: str, parts: list[str]) -> bool:
    """Allow only the non-sensitive Hotspot env template required by contract."""
    if SAFE_COMPONENT.fullmatch(part):
        return True
    if part == "__init__.py":
        return True
    return (
        part == ".env.example"
        and len(parts) == 3
        and parts[0].startswith("neosecra-hotspot-")
        and parts[1] == "backend"
    )


def fail(message: str) -> NoReturn:
    print(f"SECURITY VIOLATION: {message}", file=sys.stderr)
    raise SystemExit(4)


def _safe_member_name(raw: str) -> tuple[str, list[str]]:
    if not isinstance(raw, str) or not raw or "\x00" in raw:
        fail("archive member name is invalid")
    if "\\" in raw or any(ord(char) < 0x20 or ord(char) == 0x7F for char in raw):
        fail(f"archive member name contains unsafe characters: {raw!r}")
    if raw.startswith("/") or raw.startswith("~"):
        fail(f"archive member uses an absolute path: {raw!r}")
    # Tar paths are POSIX paths even when the host is not.  Reject rather than
    # normalise '.', '..', or duplicate separators because normalisation could
    # make two distinct members collide.
    parts = raw.split("/")
    if any(part in {"", ".", ".."} for part in parts):
        fail(f"archive member contains traversal or empty components: {raw!r}")
    if any(not _safe_component(part, parts) for part in parts):
        fail(f"archive member component is unsafe: {raw!r}")
    normal = str(PurePosixPath(*parts))
    if normal != raw:
        fail(f"archive member path is not canonical: {raw!r}")
    return normal, parts


def _open_tar(path: Path) -> tuple[tarfile.TarFile, subprocess.Popen[bytes] | None, object | None]:
    try:
        return tarfile.open(path, mode="r:*"), None, None
    except tarfile.ReadError:
        # Python's stdlib has no zstandard decoder.  Use the installed zstd
        # binary only for decompression, while keeping all member validation in
        # this process.  Missing zstd is a hard failure, never a fallback to
        # unsafe `tar -x` behaviour.
        if not shutil_which("zstd"):
            fail("unsupported archive compression (zstd decoder is unavailable)")
        proc = subprocess.Popen(
            ["zstd", "--decompress", "--stdout", "--", str(path)],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        assert proc.stdout is not None
        try:
            return tarfile.open(fileobj=proc.stdout, mode="r|"), proc, proc.stderr
        except tarfile.ReadError:
            proc.kill()
            proc.wait()
            fail("archive is not a readable tar stream")


def shutil_which(command: str) -> str | None:
    for directory in os.environ.get("PATH", "").split(os.pathsep):
        candidate = Path(directory) / command
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return str(candidate)
    return None


def _ensure_parent(root: Path, relative: Path) -> Path:
    parent = root.joinpath(*relative.parts[:-1])
    parent.mkdir(parents=True, exist_ok=True)
    # Refuse a pre-existing symlink in the destination path.  The destination
    # is a private staging directory, nevertheless this prevents a future
    # caller from turning a race into an arbitrary write.
    cursor = root
    for part in relative.parts[:-1]:
        cursor = cursor / part
        if cursor.is_symlink() or not cursor.is_dir():
            fail(f"archive extraction encountered an unsafe parent: {relative}")
    return parent


def _write_regular(root: Path, relative: Path, member: tarfile.TarInfo, archive: tarfile.TarFile) -> None:
    parent = _ensure_parent(root, relative)
    target = parent / relative.name
    if target.exists() or target.is_symlink():
        fail(f"archive extraction would overwrite an existing path: {relative}")
    source = archive.extractfile(member)
    if source is None:
        fail(f"archive regular member has no data: {relative}")
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        fd = os.open(target, flags, 0o600)
        with os.fdopen(fd, "wb") as output:
            while True:
                chunk = source.read(1024 * 1024)
                if not chunk:
                    break
                output.write(chunk)
            output.flush()
            os.fsync(output.fileno())
        # Keep only normal executable/read bits.  Ownership and special bits
        # from an untrusted archive are never applied.
        os.chmod(target, stat.S_IRUSR | stat.S_IWUSR | (member.mode & 0o555))
    except OSError as exc:
        try:
            target.unlink(missing_ok=True)
        except OSError:
            pass
        fail(f"archive extraction failed for {relative}: {exc}")


def _extract_members(archive: tarfile.TarFile, destination: Path) -> list[str]:
    seen: set[str] = set()
    top_levels: set[str] = set()
    total_bytes = 0
    member_count = 0
    for member in archive:
        member_count += 1
        if member_count > MAX_MEMBERS:
            fail("archive contains too many members")
        # Some tar writers emit a harmless `.` directory marker before the
        # real root.  It carries no payload; every other dot/empty/traversal
        # component remains rejected by _safe_member_name.
        if member.isdir() and member.name in {".", "./"}:
            continue
        name, parts = _safe_member_name(member.name)
        if name in seen:
            fail(f"archive contains a duplicate member: {name}")
        seen.add(name)
        top_levels.add(parts[0])
        if member.size < 0 or member.size > MAX_MEMBER_BYTES:
            fail(f"archive member is too large: {name}")
        total_bytes += member.size
        if total_bytes > MAX_TOTAL_BYTES:
            fail("archive expands beyond the bounded extraction limit")
        if member.issym() or member.islnk() or member.isdev() or member.isfifo():
            fail(f"archive member type is not permitted: {name}")
        relative = Path(*parts)
        if member.isdir():
            directory = destination / relative
            if directory.is_symlink() or (directory.exists() and not directory.is_dir()):
                fail(f"archive extraction would overwrite an existing path: {relative}")
            # Some valid tar writers omit an explicit parent directory and a
            # later directory member then arrives after a file created below
            # it.  An existing real directory is safe to reuse; duplicate
            # member names were already rejected above.
            directory.mkdir(parents=True, exist_ok=True)
            os.chmod(directory, 0o700)
        elif member.isreg():
            _write_regular(destination, relative, member, archive)
        else:
            fail(f"archive member type is not permitted: {name}")
    if not seen:
        fail("archive is empty")
    return sorted(top_levels)


def _finish_zstd(proc: subprocess.Popen[bytes] | None, stderr: object | None) -> None:
    if proc is None:
        return
    return_code = proc.wait()
    if return_code != 0:
        detail = b""
        if hasattr(stderr, "read"):
            detail = stderr.read()  # type: ignore[union-attr]
        fail(f"zstd decompression failed: {detail.decode(errors='replace')[:200]}")


def _prepare_destination(destination: Path) -> None:
    """Require a private empty directory, while allowing callers to pre-create it."""
    if destination.is_symlink():
        fail("extraction destination must not be a symlink")
    if destination.exists():
        if not destination.is_dir():
            fail("extraction destination is not a directory")
        try:
            next(destination.iterdir())
        except StopIteration:
            return
        fail("extraction destination must be empty")
    destination.mkdir(parents=True, exist_ok=False)


def extract_release(archive_path: str, destination: str, target: str) -> None:
    archive = Path(archive_path)
    destination_path = Path(destination)
    target_text = str(target).strip().lstrip("vV")
    if not archive.is_file() or archive.is_symlink():
        fail("release archive is not a regular file")
    if archive.stat().st_size > MAX_COMPRESSED_BYTES:
        fail("release archive exceeds the compressed size limit")
    if not SEMVER.fullmatch(target_text):
        fail("release target version is invalid")
    _prepare_destination(destination_path)
    tar, proc, stderr = _open_tar(archive)
    try:
        top_levels = _extract_members(tar, destination_path)
    finally:
        tar.close()
        _finish_zstd(proc, stderr)
    if len(top_levels) != 1:
        fail("release archive must contain exactly one top-level root")
    expected_prefix = f"neosecra-distribution-{target_text}"
    root = top_levels[0]
    if root != expected_prefix and not root.startswith(expected_prefix + "-"):
        fail(f"release archive root does not match target {target_text}: {root}")
    payload = destination_path / root / "deployment"
    required = ("VERSION", "lib/common.sh", "upgrade/upgrade.sh", "docker-compose.v1.yml")
    if not payload.is_dir():
        fail("release archive is missing deployment/")
    for marker in required:
        candidate = payload / marker
        if not candidate.is_file() or candidate.is_symlink():
            fail(f"release archive is missing deployment/{marker}")
    version = (payload / "VERSION").read_text(encoding="utf-8").strip()
    if version.lstrip("vV") != target_text:
        fail("release archive VERSION is not bound to the signed target")


def extract_bundle(archive_path: str, destination: str) -> None:
    archive = Path(archive_path)
    destination_path = Path(destination)
    if not archive.is_file() or archive.is_symlink():
        fail("docker bundle is not a regular file")
    if archive.stat().st_size > MAX_COMPRESSED_BYTES:
        fail("docker bundle exceeds the compressed size limit")
    _prepare_destination(destination_path)
    tar, proc, stderr = _open_tar(archive)
    try:
        top_levels = _extract_members(tar, destination_path)
    finally:
        tar.close()
        _finish_zstd(proc, stderr)
    if top_levels != ["images"]:
        fail("docker bundle must contain exactly one images/ root")
    images = destination_path / "images"
    members = sorted(path for path in images.iterdir() if path.is_file())
    if not members:
        fail("docker bundle contains no image archives")
    for image in members:
        if image.suffix != ".tar" or not SAFE_COMPONENT.fullmatch(image.name):
            fail(f"docker bundle contains an unexpected member: {image.name}")
    for child in images.iterdir():
        if child.is_dir() or child.is_symlink():
            fail("docker bundle contains nested directories or links")


def extract_hotspot(archive_path: str, destination: str, target: str) -> None:
    """Extract and validate a Hotspot source release."""
    archive = Path(archive_path)
    destination_path = Path(destination)
    target_text = str(target).strip().lstrip("vV")
    if not archive.is_file() or archive.is_symlink():
        fail("Hotspot archive is not a regular file")
    if archive.stat().st_size > MAX_COMPRESSED_BYTES:
        fail("Hotspot archive exceeds the compressed size limit")
    if not SEMVER.fullmatch(target_text):
        fail("Hotspot target version is invalid")
    _prepare_destination(destination_path)
    tar, proc, stderr = _open_tar(archive)
    try:
        top_levels = _extract_members(tar, destination_path)
    finally:
        tar.close()
        _finish_zstd(proc, stderr)
    if len(top_levels) != 1:
        fail("Hotspot archive must contain exactly one top-level root")
    expected_prefix = f"neosecra-hotspot-{target_text}"
    root = top_levels[0]
    if root != expected_prefix and not root.startswith(expected_prefix + "-"):
        fail(f"Hotspot archive root does not match target {target_text}: {root}")
    payload = destination_path / root
    required = ("docker-compose.yml", "backend/.env.example", "backend", "frontend/admin", "frontend/portal")
    for marker in required:
        candidate = payload / marker
        if not candidate.exists() or candidate.is_symlink():
            fail(f"Hotspot archive is missing {marker}")
    if not (payload / "docker-compose.yml").is_file() or not (payload / "backend/.env.example").is_file():
        fail("Hotspot release metadata is incomplete")


def main() -> None:
    if len(sys.argv) < 4 or sys.argv[1] not in {"release", "hotspot", "bundle"}:
        fail("Usage: secure_extract.py release|hotspot|bundle <archive> <destination> [target]")
    mode, archive, destination = sys.argv[1:4]
    if mode in {"release", "hotspot"}:
        if len(sys.argv) != 5:
            fail(f"{mode} extraction requires a target version")
        if mode == "release":
            extract_release(archive, destination, sys.argv[4])
        else:
            extract_hotspot(archive, destination, sys.argv[4])
    else:
        if len(sys.argv) != 4:
            fail("bundle extraction takes exactly archive and destination")
        extract_bundle(archive, destination)


if __name__ == "__main__":
    main()
