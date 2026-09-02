import json
import os
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PUBLISH = ROOT / "update-server" / "publish.sh"
REQUIRED = ("postgres", "redis", "backend", "worker", "beat", "frontend", "soc-ai-agent", "nginx", "caddy")


def _lock(path: Path, *, mutable: bool = False, missing: str | None = None) -> None:
    lines = []
    for index, name in enumerate(REQUIRED, 1):
        if name == missing:
            continue
        reference = f"registry.neosecra.com/neosecra-soc-{name}:1.0.1"
        digest = "sha256:" + f"{index:064x}"
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


def _run(tmp_path: Path, lock: Path) -> subprocess.CompletedProcess[str]:
    tmp_path.mkdir(parents=True, exist_ok=True)
    archive = tmp_path / "soc-1.0.1.tar.gz"
    archive.write_bytes(b"signed archive fixture")
    bundle = tmp_path / "soc-1.0.1-bundle.tar.gz"
    bundle.write_bytes(b"signed docker bundle fixture")
    key = tmp_path / "signing.key"
    key.write_text("test-only signing adapter\n", encoding="utf-8")
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir(exist_ok=True)
    _fake_minisign(bin_dir)
    www = tmp_path / "www"
    env = os.environ.copy()
    env["PATH"] = f"{bin_dir}:{env['PATH']}"
    return subprocess.run(
        [
            "bash",
            str(PUBLISH),
            "--product",
            "soc",
            "--channel",
            "beta",
            "--version",
            "1.0.1",
            "--archive",
            str(archive),
            "--bundle",
            str(bundle),
            "--images-lock",
            str(lock),
            "--key",
            str(key),
            "--www",
            str(www),
        ],
        cwd=ROOT,
        env=env,
        capture_output=True,
        text=True,
    )


def test_soc_publisher_requires_image_lock(tmp_path: Path) -> None:
    archive = tmp_path / "archive.tar.gz"
    archive.write_bytes(b"fixture")
    key = tmp_path / "key"
    key.write_text("fixture\n", encoding="utf-8")
    result = subprocess.run(
        [
            "bash",
            str(PUBLISH),
            "--product",
            "soc",
            "--channel",
            "beta",
            "--version",
            "1.0.1",
            "--archive",
            str(archive),
            "--key",
            str(key),
        ],
        cwd=ROOT,
        capture_output=True,
        text=True,
    )
    assert result.returncode != 0
    assert "--images-lock is required" in result.stdout


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
