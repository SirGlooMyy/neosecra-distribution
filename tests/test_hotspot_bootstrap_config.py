"""Behavioral checks for the customer-facing Hotspot config preflight."""

from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

import pytest


ROOT = Path(__file__).resolve().parents[1]
BOOTSTRAP = ROOT / "update-server" / "bootstrap-hotspot.sh"
BASH = Path(r"C:\Program Files\Git\bin\bash.exe")


def _config(**changes: str) -> str:
    values = {
        "PORTAL_PUBLIC_BASE_URL": "https://hotspot.customer.example/approval",
        "PORTAL_APP_BASE_URL": "https://hotspot.customer.example",
        "CORS_ORIGINS": "https://hotspot.customer.example",
        "SMS_PROVIDER": "http",
        "SMS_HTTP_URL": "https://sms.customer.example/send",
        "TUBITAK_TSA_REQUIRED": "true",
        "TUBITAK_TSA_URL": "https://tsa.customer.example",
        "TUBITAK_TSA_CA_BUNDLE": "/app/ca/customer-tsa-chain.pem",
        "ARCHIVE_ENCRYPTION_ENABLED": "true",
        "ARCHIVE_MINIO_OBJECT_LOCK_REQUIRED": "true",
        "CLICKHOUSE_ENABLED": "true",
        "UPGRADE_CHANNEL_VERIFY_SSL": "true",
    }
    values.update(changes)
    return "".join(f"{key}={value}\n" for key, value in values.items())


def _check(tmp_path: Path, content: str, *extra_args: str) -> subprocess.CompletedProcess[str]:
    config = tmp_path / "customer.env"
    config.write_text(content, encoding="utf-8")
    return subprocess.run(
        [str(BASH), str(BOOTSTRAP), "--config", str(config), "--check-config", *extra_args],
        cwd=ROOT,
        env={
            **os.environ,
            "PATH": f"{Path(sys.executable).parent}{os.pathsep}{os.environ.get('PATH', '')}",
            "HOTSPOT_ENVIRONMENT": "development",
        },
        capture_output=True,
        text=True,
        check=False,
    )


def test_valid_customer_config_passes_offline_even_with_host_override(tmp_path: Path) -> None:
    result = _check(tmp_path, _config())
    assert result.returncode == 0, result.stderr
    assert "PASS" in result.stdout


def test_candidate_channel_requires_explicit_allowlisted_identity(tmp_path: Path) -> None:
    candidate = _check(tmp_path, _config(), "--channel", "hotspot-candidate")
    assert candidate.returncode == 0, candidate.stderr

    invalid = _check(tmp_path, _config(), "--channel", "another-product")
    assert invalid.returncode == 2
    assert "Desteklenmeyen Hotspot kanali" in invalid.stderr


def test_deferred_portal_and_sms_configuration_passes_preflight(tmp_path: Path) -> None:
    content = _config(
        PORTAL_PUBLIC_BASE_URL="",
        PORTAL_APP_BASE_URL="",
        CORS_ORIGINS="",
        SMS_PROVIDER="console",
        SMS_HTTP_URL="",
    )
    result = _check(tmp_path, content)
    assert result.returncode == 0, result.stderr


def test_ip_only_generated_config_can_be_reused_for_recovery(tmp_path: Path) -> None:
    content = _config(
        PORTAL_PUBLIC_BASE_URL="",
        PORTAL_APP_BASE_URL="",
        CORS_ORIGINS="http://192.168.2.135:35174,http://192.168.2.135:35175",
        SMS_PROVIDER="console",
        SMS_HTTP_URL="",
    )
    result = _check(tmp_path, content, "--server-ip", "192.168.2.135")
    assert result.returncode == 0, result.stderr


def test_ip_only_install_requires_explicit_valid_address() -> None:
    script = BOOTSTRAP.read_text(encoding="utf-8")
    assert 'cp -- "$RELEASE_DIR/backend/.env.example" "$ENV_FILE"' in script
    assert 'set_env SERVER_HOST_IP "$SERVER_IP"' in script
    assert 'set_env RADIUS_LISTENER_HOST "$SERVER_IP"' in script
    # The admin panel moved to HTTPS 443 in 0.3.127; new installs write that origin.
    assert 'set_env CORS_ORIGINS "https://${SERVER_IP}"' in script
    assert 'r"^[A-Za-z0-9_][A-Za-z0-9._-]{0,127}$"' in script
    assert "os.chmod(target, 0o755)" in script
    assert "0o755 if (member.mode & 0o111) else 0o644" in script
    assert 'chown 65532:65532 "${DATA_ROOT}/minio"' in script
    assert 'local destination="$1" content="$2" tmp' in script


@pytest.mark.parametrize(
    ("change", "message"),
    [
        ({"PORTAL_PUBLIC_BASE_URL": "https://user:secret@example.com"}, "credential-free HTTPS"),
        ({"SMS_HTTP_URL": "http://sms.customer.example/send"}, "credential-free HTTPS"),
        ({"CORS_ORIGINS": "*"}, "wildcard"),
        ({"ARCHIVE_MINIO_OBJECT_LOCK_REQUIRED": "false"}, "must be true"),
        ({"TUBITAK_TSA_CA_BUNDLE": "relative.pem"}, "absolute container path"),
    ],
)
def test_unsafe_customer_values_fail_before_install(
    tmp_path: Path, change: dict[str, str], message: str
) -> None:
    result = _check(tmp_path, _config(**change))
    assert result.returncode == 2
    assert message in result.stderr


def test_runtime_contract_pins_production_and_populates_compose_minio_credentials() -> None:
    script = BOOTSTRAP.read_text(encoding="utf-8")
    assert "export HOTSPOT_ENVIRONMENT=production" in script
    assert "export HOTSPOT_ENFORCE_LICENSED_OPERATIONS=true" in script
    assert 'set_env MINIO_ACCESS_KEY "$MINIO_ACCESS"' in script
    assert 'set_env MINIO_SECRET_KEY "$MINIO_SECRET"' in script


def _run_sysctl_function(
    tmp_path: Path, *, install_fails: bool, sysctl_fails: bool
) -> tuple[subprocess.CompletedProcess[str], Path]:
    text = BOOTSTRAP.read_text(encoding="utf-8")
    body = text.split("configure_udp_receive_buffer() {", 1)[1].split("\n}\n", 1)[0]
    function = "configure_udp_receive_buffer() {" + body + "\n}\n"
    calls = tmp_path / "calls.log"
    log = calls.as_posix()
    # Shell functions shadow the real install/sysctl so nothing touches the host.
    install_stub = (
        f'install() {{ echo "install $*" >> "{log}"; return 1; }}\n'
        if install_fails
        else f'install() {{ echo "install $*" >> "{log}"; return 0; }}\n'
    )
    sysctl_stub = f'sysctl() {{ echo "sysctl $*" >> "{log}"; return {1 if sysctl_fails else 0}; }}\n'
    script = tmp_path / "run.sh"
    script.write_text(
        "set -Eeuo pipefail\n"
        "umask 077\n"
        "info() { printf 'INFO %s\n' \"$@\"; }\n"
        "warn() { printf 'WARN %s\n' \"$@\" >&2; }\n"
        f'TMP_DIR="{tmp_path.as_posix()}"\n'
        f"{install_stub}{sysctl_stub}{function}"
        "configure_udp_receive_buffer\n"
        "echo DONE\n",
        encoding="utf-8",
        newline="\n",
    )
    result = subprocess.run(
        [str(BASH), str(script)],
        capture_output=True,
        text=True,
        check=False,
    )
    return result, calls


def test_bootstrap_sysctl_step_writes_both_keys_with_mode_0644(tmp_path: Path) -> None:
    result, calls = _run_sysctl_function(tmp_path, install_fails=False, sysctl_fails=False)
    assert result.returncode == 0, result.stderr
    assert "DONE" in result.stdout and "WARN" not in result.stderr
    log = calls.read_text(encoding="utf-8")
    assert "install -m 0644 " in log and "/etc/sysctl.d/60-neosecra-hotspot.conf" in log
    assert "sysctl -q -p /etc/sysctl.d/60-neosecra-hotspot.conf" in log
    staged = (tmp_path / "60-neosecra-hotspot.conf").read_text(encoding="utf-8")
    keys = [line for line in staged.splitlines() if line and not line.startswith("#")]
    assert keys == ["net.core.rmem_max = 33554432", "net.core.rmem_default = 1048576"]


def test_bootstrap_sysctl_step_tolerates_unwritable_sysctl(tmp_path: Path) -> None:
    result, _ = _run_sysctl_function(tmp_path, install_fails=False, sysctl_fails=True)
    assert result.returncode == 0, result.stderr
    assert "DONE" in result.stdout and "WARN" in result.stderr


def test_bootstrap_sysctl_step_tolerates_unwritable_sysctl_directory(tmp_path: Path) -> None:
    result, _ = _run_sysctl_function(tmp_path, install_fails=True, sysctl_fails=False)
    assert result.returncode == 0, result.stderr
    assert "DONE" in result.stdout and "WARN" in result.stderr
