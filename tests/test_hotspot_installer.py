"""Run the installer against a fake filesystem and mocked host operations."""

from __future__ import annotations

import os
import shlex
import shutil
import subprocess
from pathlib import Path

import pytest


ROOT = Path(__file__).resolve().parents[1]
V1 = ROOT / "deployment" / "v1"
STABLE = "https://update.neosecra.com/channels/hotspot-stable.json"
CANDIDATE = "https://update.neosecra.com/channels/hotspot-candidate.json"


@pytest.mark.parametrize(
    "existing,override,url,channel",
    [
        (f"UPGRADE_CHANNEL_URL={CANDIDATE}\nUPGRADE_RELEASE_CHANNEL=hotspot-stable\n",
         None, CANDIDATE, "hotspot-candidate"),
        (f"UPGRADE_CHANNEL_URL={CANDIDATE}\n", STABLE, STABLE, "hotspot-stable"),
        (None, None, STABLE, "hotspot-stable"),
        ("UPGRADE_CHANNEL_PUBLIC_KEY=/unused/key\n", None, STABLE, "hotspot-stable"),
        (f'UPGRADE_CHANNEL_URL="{CANDIDATE}"\r\n',
         None, CANDIDATE, "hotspot-candidate"),
        (f"UPGRADE_CHANNEL_URL='{CANDIDATE}'",
         None, CANDIDATE, "hotspot-candidate"),
        (None, CANDIDATE + "?source=installer", CANDIDATE + "?source=installer",
         "hotspot-candidate"),
    ],
    ids=["reinstall-candidate", "explicit-stable", "first-install", "missing-url",
         "quoted-crlf", "no-final-newline", "query-string"],
)
def test_installer_channel_precedence(tmp_path: Path, existing, override, url, channel):
    bash = (r"C:\Program Files\Git\bin\bash.exe" if os.name == "nt"
            else shutil.which("bash"))
    assert bash, "Bash is required for installer acceptance tests"

    # Stage actual payload files; only the test copy redirects /etc and bypasses
    # the root check. Production path selection and security guards stay intact.
    payload = tmp_path / "payload"
    for relative in (
        "agent/install-hotspot-agent.sh", "agent/update-agent.sh",
        "agent/artifact-verifier.sh", "agent/hotspot-updater.sh",
        "upgrade/secure_extract.py", "upgrade/verify_rollback_auth.py",
        "upgrade/recovery.py", "lib/common.sh", "lib/manifest.sh", "lib/state.sh",
    ):
        destination = payload / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(V1 / relative, destination)
    shutil.copytree(V1 / "ca", payload / "ca")
    installer = payload / "agent/install-hotspot-agent.sh"
    source = installer.read_text(encoding="utf-8")
    root_guard = '[[ $EUID -eq 0 ]] || { echo "Run as root (sudo)" >&2; exit 1; }'
    assert root_guard in source
    source = source.replace(root_guard, ": # Test-only root-check bypass")
    source = source.replace("/etc/", "${TEST_ROOT}/etc/")
    installer.write_text(source, encoding="utf-8", newline="\n")

    env_file = tmp_path / "etc/neosecra/hotspot-update-agent.env"
    env_file.parent.mkdir(parents=True)
    (tmp_path / "etc/systemd/system").mkdir(parents=True)
    if existing is not None:
        # This unrelated entry would create a marker if the env were sourced.
        env_file.write_text('UNRELATED=$(touch "$TEST_ROOT/executed")\n' + existing,
                            encoding="utf-8", newline="\n")

    runner = tmp_path / "run.sh"
    runner.write_text("\n".join([
        "set -Eeuo pipefail",
        f"TEST_ROOT=$(cd {shlex.quote(tmp_path.as_posix())} && pwd)",
        "export TEST_ROOT",
        "install() {",
        "  local args=() directory=0",
        "  while [[ $# -gt 0 ]]; do",
        '    case "$1" in -m|-o|-g) shift; shift ;; -d) directory=1; shift ;;',
        '      *) args+=("$1"); shift ;; esac',
        "  done",
        '  if [[ "$directory" -eq 1 ]]; then mkdir -p "${args[@]}";',
        '  else cp "${args[@]}"; fi',
        "}",
        "chown() { :; }",
        "chmod() { :; }",
        "systemctl() { :; }",
        'args=(--hotspot-root "$TEST_ROOT/hotspot")',
        "args+=(--channel-url " + shlex.quote(override) + ")" if override is not None else ":",
        'source "$TEST_ROOT/payload/agent/install-hotspot-agent.sh" "${args[@]}"',
    ]) + "\n", encoding="utf-8", newline="\n")
    result = subprocess.run([bash, runner.as_posix()], capture_output=True, text=True,
                            cwd=ROOT, timeout=60)
    assert result.returncode == 0, result.stdout + result.stderr
    assert not (tmp_path / "executed").exists(), "Existing env must not be executed"
    values = dict(line.split("=", 1) for line in env_file.read_text().splitlines()
                  if line and not line.startswith("#"))
    assert values["UPGRADE_CHANNEL_URL"] == url
    assert values["UPGRADE_RELEASE_CHANNEL"] == channel
    assert f"  channel: {url} (release channel: {channel})" in result.stdout.splitlines()
    # All other generated env values retain the installer's existing contract.
    install_root = values["NEOSECRA_INSTALL_ROOT"]
    agent_root = install_root + "/update-agent"
    assert {key: value for key, value in values.items() if not key.startswith("UPGRADE_CHANNEL")
            and key != "UPGRADE_RELEASE_CHANNEL"} == {
        "NEOSECRA_INSTALL_ROOT": install_root,
        "NEOSECRA_PRODUCT": "neosecra-hotspot",
        "NEOSECRA_EDITION_ID": "standard",
        "NEOSECRA_PROJECT": "neosecra-hotspot",
        "NEOSECRA_COMPOSE_PROJECT": "neosecra-hotspot",
        "NEOSECRA_BACKUP_ROOT": install_root + "/backups",
        "NEOSECRA_UPDATE_DB_BACKUP": "off",
        "NEOSECRA_SECURE_EXTRACT": agent_root + "/secure_extract.py",
        "NEOSECRA_ROLLBACK_VERIFIER": agent_root + "/verify_rollback_auth.py",
    }
    assert values["UPGRADE_CHANNEL_PUBLIC_KEY"] == agent_root + "/ca"
    assert (tmp_path / "hotspot/update-agent/ca/update-neosecra-com.pub").is_file()
