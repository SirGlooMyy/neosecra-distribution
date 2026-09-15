"""Regression coverage for the Hotspot signed install/update contract."""

from __future__ import annotations

import io
import subprocess
import sys
import tarfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
EXTRACTOR = ROOT / "deployment" / "v1" / "upgrade" / "secure_extract.py"
BOOTSTRAP = ROOT / "update-server" / "bootstrap-hotspot.sh"
UPDATER = ROOT / "deployment" / "v1" / "agent" / "hotspot-updater.sh"
INSTALLER = ROOT / "deployment" / "v1" / "agent" / "install-hotspot-agent.sh"
PUBLISH = ROOT / "update-server" / "publish.sh"


def _run_extractor(archive: Path, destination: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(EXTRACTOR), "hotspot", str(archive), str(destination), "0.3.26"],
        capture_output=True,
        text=True,
        check=False,
    )


def _member(name: str, content: bytes = b"x") -> tarfile.TarInfo:
    info = tarfile.TarInfo(name)
    info.size = len(content)
    info.mode = 0o600
    return info


def test_secure_extractor_rejects_multiple_roots(tmp_path: Path) -> None:
    archive = tmp_path / "multi-root.tar.gz"
    with tarfile.open(archive, "w:gz") as bundle:
        for name in ("neosecra-hotspot-0.3.26/docker-compose.yml", "other/root.txt"):
            content = b"{}"
            bundle.addfile(_member(name, content), io.BytesIO(content))

    result = _run_extractor(archive, tmp_path / "extract")
    assert result.returncode == 4
    assert "exactly one top-level root" in result.stderr


def test_secure_extractor_rejects_duplicate_members(tmp_path: Path) -> None:
    archive = tmp_path / "duplicate.tar.gz"
    with tarfile.open(archive, "w:gz") as bundle:
        for _ in range(2):
            content = b"{}"
            bundle.addfile(_member("neosecra-hotspot-0.3.26/docker-compose.yml", content), io.BytesIO(content))

    result = _run_extractor(archive, tmp_path / "extract")
    assert result.returncode == 4
    assert "duplicate" in result.stderr


def test_hotspot_scripts_keep_monotonic_and_recovery_guards() -> None:
    updater = UPDATER.read_text(encoding="utf-8")
    installer = INSTALLER.read_text(encoding="utf-8")
    publisher = PUBLISH.read_text(encoding="utf-8")
    bootstrap = BOOTSTRAP.read_text(encoding="utf-8")

    assert "Hotspot downgrade is not permitted" in updater
    assert "hotspot-upgrade.transaction.json" in updater
    assert "recover_interrupted_transaction" in updater
    assert "ensure_env_value" in updater
    assert 'CLICKHOUSE_PASSWORD "$(random_hex 32)"' in updater
    assert "COMPOSE_CONFIG_FAILED" in updater
    assert 'run --rm migrate' in updater
    assert 'start_args=(up -d --remove-orphans api worker beat admin portal freeradius)' in updater
    assert 'DEFAULT_SUPERADMIN_PASSWORD "Neosecra123!"' in bootstrap
    assert "validate_channel_monotonic" in publisher
    assert "immutable release violation" in publisher
    assert "ensure_env POSTGRES_PASSWORD" in bootstrap
    assert "ensure_env CLICKHOUSE_PASSWORD" in bootstrap
    assert "ensure_env CLICKHOUSE_USER default" in bootstrap
    assert 'python3 - "$TMP_DIR/channel.json"' in bootstrap
    assert 'python3 - "$TMP_DIR/hotspot.tar.gz"' in bootstrap
    assert 'python3 "$TMP_DIR/channel.json"' not in bootstrap
    assert 'python3 "$TMP_DIR/hotspot.tar.gz"' not in bootstrap
    assert 'set_env VERSION "$VERSION"' in bootstrap
    assert "--data-root" in bootstrap
    assert "findmnt -T" in bootstrap
    assert "HOTSPOT_PGDATA_SOURCE" in bootstrap
    assert "ARCHIVE_PROVIDER minio" in bootstrap
    assert "keyring" in updater.lower()
    assert 'AGENT_STATE="${ROOT}/state/update-agent"' in installer
    assert "--backup-root" in installer
    assert "NEOSECRA_BACKUP_ROOT" in installer
    assert "Database backup/restore is unsupported" in updater
    assert "normal Hotspot updates are backup-free" in updater
    assert "BACKING_UP" not in updater
    assert "pg_dump" not in updater
    assert "restore_database" not in updater
    assert 'NEOSECRA_UPDATE_DB_BACKUP=off' in installer
    assert "Environment=DOCKER_CONFIG=${AGENT_STATE}/docker-config" in installer
    assert "Environment=BUILDX_CONFIG=${AGENT_STATE}/buildx" in installer
    assert 'active-release' in updater
    assert "public_key_source_valid" in (ROOT / "deployment" / "v1" / "agent" / "update-agent.sh").read_text(encoding="utf-8")
    assert 'base="upgrade-progress.json"' in (ROOT / "deployment" / "v1" / "agent" / "update-agent.sh").read_text(encoding="utf-8")
    assert "release-metadata" in (ROOT / "deployment" / "v1" / "agent" / "update-agent.sh").read_text(encoding="utf-8")
    assert '${CHANNEL_RELEASE_METADATA_JSON:-{}}' not in (
        ROOT / "deployment" / "v1" / "agent" / "update-agent.sh"
    ).read_text(encoding="utf-8")
    assert "get.docker.com" not in bootstrap
