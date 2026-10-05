"""Regression coverage for the Hotspot signed install/update contract."""

from __future__ import annotations

import io
import re
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
    # No shared default: each installation generates its first administrator
    # password and keeps it once in a root-only state file.
    assert not re.search(r'ensure_env DEFAULT_SUPERADMIN_PASSWORD "[^"$]', bootstrap)
    assert 'set_env DEFAULT_SUPERADMIN_PASSWORD "$INITIAL_ADMIN_PASSWORD"' in bootstrap
    assert 'INITIAL_ADMIN_FILE="${STATE_DIR}/initial-admin-password"' in bootstrap
    # Payload permissions are normalised after extraction (umask 077 installer).
    assert 'chmod -R u+rwX,go+rX,go-w "$RELEASE_DIR"' in bootstrap
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
    assert "--single-disk" in bootstrap
    assert "findmnt -T" in bootstrap
    assert "HOTSPOT_PGDATA_SOURCE" in bootstrap
    assert "ARCHIVE_PROVIDER minio" in bootstrap
    assert "keyring" in updater.lower()
    assert 'AGENT_STATE="${ROOT}/state/update-agent"' in installer
    assert 'HEARTBEAT_FILE="${STATE_BRIDGE}/agent-alive"' in installer
    assert 'rmdir -- "$HEARTBEAT_FILE"' in installer
    assert 'heartbeat directory is not empty' in installer
    assert 'heartbeat symlink' in installer
    assert 'ExecStartPre=/usr/bin/test -f ${HEARTBEAT_FILE}' in installer
    assert 'ExecStartPre=/usr/bin/test ! -L ${HEARTBEAT_FILE}' in installer
    assert 'ExecStart=/usr/bin/touch -- ${HEARTBEAT_FILE}' in installer
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


def test_hotspot_bootstrap_provisions_compose_v2_and_verifies_daemon() -> None:
    bootstrap = BOOTSTRAP.read_text(encoding="utf-8")
    assert "apt-get install -y -qq ca-certificates curl python3 coreutils minisign util-linux e2fsprogs findutils gawk openssl tar" in bootstrap
    assert "apt-get install -y -qq docker.io" in bootstrap
    assert "apt-get install -y -qq docker-compose-v2" in bootstrap
    assert "apt-get install -y -qq docker-compose-plugin" in bootstrap
    assert "apt-get install -y -qq docker-compose\n" not in bootstrap
    assert 'systemctl enable --now docker >/dev/null 2>&1 || die' in bootstrap
    assert 'docker info >/dev/null 2>&1 || die' in bootstrap


def test_storage_layout_prefers_blank_data_disk_then_bounds_single_disk() -> None:
    bootstrap = BOOTSTRAP.read_text(encoding="utf-8")
    assert "SINGLE_DISK=0" in bootstrap
    assert "blank_disks=()" in bootstrap
    assert "${#blank_disks[@]} -le 1" in bootstrap
    assert "wipefs -n" in bootstrap
    assert "mkfs.ext4 -q" in bootstrap
    assert "findmnt --fstab -M" in bootstrap
    assert '[[ "$DATA_TOTAL_GB" -ge 900 && "$DATA_FREE_GB" -ge 700 ]]' in bootstrap
    assert '[[ "$DATA_MOUNT_TARGET" == "$DATA_ROOT" ]]' in bootstrap
