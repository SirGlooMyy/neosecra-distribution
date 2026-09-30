import json
import hashlib
import os
import subprocess
import tarfile
from pathlib import Path


from fixtures.publisher import Publisher

ROOT = Path(__file__).resolve().parents[1]
PUBLISH = ROOT / "update-server" / "publish.sh"
REQUIRED = ("postgres", "redis", "backend", "worker", "beat", "frontend", "soc-ai-agent", "nginx", "caddy")


def _lock(path: Path, *, mutable: bool = False, missing: str | None = None) -> None:
    lines = []
    for index, name in enumerate(REQUIRED, 1):
        if name == missing:
            continue
        image_name = "backend" if name in {"backend", "worker", "beat"} else name
        image_index = 3 if name in {"backend", "worker", "beat"} else index
        reference = f"registry.neosecra.com/neosecra-soc-{image_name}:1.0.1"
        digest = "sha256:" + f"{image_index:064x}"
        if mutable and name == "backend":
            lines.append(f"{name}={reference}")
        else:
            lines.append(f"{name}={reference}@{digest}")
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def _fake_minisign(bin_dir: Path) -> None:
    script = bin_dir / "minisign"
    script.write_text(
        """#!/usr/bin/env bash
set -euo pipefail
if [[ \" $* \" == *\" -S \"* ]]; then
  file=\"\"
  while [[ $# -gt 0 ]]; do
    if [[ \"$1\" == \"-m\" ]]; then file=\"$2\"; shift 2; continue; fi
    shift
  done
  printf 'test signature\\n' > \"${file}.minisig\"
fi
exit 0
""",
        encoding="utf-8",
    )
    script.chmod(0o755)


def _write_package(path: Path, lock: Path) -> None:
    payload = {
        "release/images.lock": lock.read_bytes(),
        "release/payload.txt": b"signed package payload\n",
    }
    checksums = "".join(
        f"{hashlib.sha256(content).hexdigest()} *{name}\n"
        for name, content in sorted(payload.items())
    ).encode("utf-8")
    payload["release/checksums.sha256"] = checksums
    with tarfile.open(path, "w:gz") as archive:
        for name, content in sorted(payload.items()):
            member = tarfile.TarInfo(f"soc-1.0.1/{name}")
            member.mode = 0o644
            member.size = len(content)
            archive.addfile(member, __import__("io").BytesIO(content))


def _write_bundle(path: Path, lock: Path, *, missing_reference: str | None = None) -> None:
    rows = {}
    for raw in lock.read_text(encoding="utf-8").splitlines():
        name, value = raw.split("=", 1)
        rows[name] = value.split("@", 1)[0]
    manifests = []
    configs = {}
    for reference in sorted(set(rows.values())):
        if reference == missing_reference:
            continue
        content = json.dumps({"architecture": "amd64", "rootfs": {"type": "layers", "diff_ids": []}}, separators=(",", ":")).encode()
        config_id = hashlib.sha256(content).hexdigest()
        config_name = f"{config_id}.json"
        configs[config_name] = content
        manifests.append({"Config": config_name, "RepoTags": [reference], "Layers": []})
    with tarfile.open(path, "w:gz") as archive:
        manifest = json.dumps(manifests, separators=(",", ":")).encode()
        member = tarfile.TarInfo("manifest.json")
        member.mode = 0o644
        member.size = len(manifest)
        archive.addfile(member, __import__("io").BytesIO(manifest))
        for name, content in sorted(configs.items()):
            member = tarfile.TarInfo(name)
            member.mode = 0o644
            member.size = len(content)
            archive.addfile(member, __import__("io").BytesIO(content))


def _run(tmp_path: Path, lock: Path) -> subprocess.CompletedProcess[str]:
    tmp_path.mkdir(parents=True, exist_ok=True)
    archive = tmp_path / "soc-1.0.1.tar.gz"
    _write_package(archive, lock)
    bundle = tmp_path / "soc-1.0.1-bundle.tar.gz"
    _write_bundle(bundle, lock)
    publisher = Publisher(tmp_path, stub_gates=True)
    return publisher.run(product="soc", channel="beta", archive=archive, bundle=bundle, lock=lock)


def test_soc_publisher_requires_image_lock(tmp_path: Path) -> None:
    archive = tmp_path / "archive.tar.gz"
    archive.write_bytes(b"fixture")
    key = tmp_path / "key"
    key.write_text("fixture\n", encoding="utf-8")
    result = Publisher(tmp_path).run(product="soc", channel="beta", archive=archive)
    assert result.returncode != 0
    assert "--images-lock is required" in result.stdout + result.stderr


def test_soc_publisher_rejects_mutable_or_incomplete_lock(tmp_path: Path) -> None:
    mutable = tmp_path / "mutable.lock"
    _lock(mutable, mutable=True)
    result = _run(tmp_path / "mutable-run", mutable)
    assert result.returncode != 0
    assert "mutable SOC image reference" in result.stdout or "mutable SOC image reference" in result.stderr

    incomplete = tmp_path / "incomplete.lock"
    _lock(incomplete, missing="caddy")
    result = _run(tmp_path / "incomplete-run", incomplete)
    assert result.returncode != 0
    assert "must match compose services exactly" in result.stdout + result.stderr


def test_soc_publisher_emits_immutable_image_metadata(tmp_path: Path) -> None:
    lock = tmp_path / "images.lock"
    _lock(lock)
    run_dir = tmp_path / "valid-run"
    run_dir.mkdir()
    result = _run(run_dir, lock)
    assert result.returncode == 0, result.stdout + result.stderr
    channel = json.loads((run_dir / "www" / "channels" / "soc-beta.json").read_text(encoding="utf-8"))
    assert channel["status"] == "available"
    release = channel["releases"][0]
    assert set(release["images"]) == set(REQUIRED)
    assert all("@" not in meta["reference"] and meta["digest"].startswith("sha256:") for meta in release["images"].values())
    published_archive = run_dir / "www" / "releases" / "soc" / "1.0.1" / "soc-1.0.1.tar.gz"
    published_bundle = run_dir / "www" / "releases" / "soc" / "1.0.1" / "soc-1.0.1-bundle.tar.gz"
    with tarfile.open(published_archive, "r:gz") as package:
        bundle_lock = package.extractfile("soc-1.0.1/release/bundle.lock")
        assert bundle_lock is not None
        lines = bundle_lock.read().decode("utf-8").splitlines()
    assert lines[0] == "format=1"
    assert lines[1] == f"bundle_sha256={hashlib.sha256(published_bundle.read_bytes()).hexdigest()}"
    assert {line.split("=", 1)[0] for line in lines[2:]} == set(REQUIRED)
