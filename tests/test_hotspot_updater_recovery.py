"""Execute recovery gates without Docker or customer state."""
import os
from pathlib import Path
import re
import shutil
import subprocess

import pytest


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "deployment/v1/agent/hotspot-updater.sh"


def function(name):
    source = SOURCE.read_text(encoding="utf-8")
    return re.search(r"(?ms)^" + name + r"\(\) \{.*?^\}", source).group(0)


def bash_run(tmp_path, script):
    bash = str(Path(r"C:\Program Files\Git\bin\bash.exe")) if os.name == "nt" else shutil.which("bash")
    path = tmp_path / "check.sh"
    path.write_text(script, encoding="utf-8", newline="\n")
    return subprocess.run([bash, path.as_posix()], capture_output=True, text=True)


@pytest.mark.parametrize("radius_ok", [True, False])
def test_restore_rebuilds_radius_and_propagates_its_failure(tmp_path, radius_ok):
    result = bash_run(tmp_path, "\n".join([
        "run_compose() { printf 'compose:%s\\n' \"$*\"; }",
        "wait_api() { echo api; }",
        "wait_freeradius() { echo radius; return " + ("0" if radius_ok else "1") + "; }",
        "verify_compose_working_dir() { echo provenance; }",
        function("restore_previous_stack"),
        'restore_previous_stack /releases/0.3.66 /releases/0.3.66/backend/.env',
    ]))
    assert (result.returncode == 0) == radius_ok, result.stderr
    commands = [line for line in result.stdout.splitlines() if line.startswith("compose:")]
    assert commands and all(line.startswith("compose:/releases/0.3.66 /releases/0.3.66/backend/.env ") for line in commands)
    assert commands[0].endswith("build api worker beat admin portal freeradius")
    assert any("up -d postgres redis clickhouse minio createbuckets" in line for line in commands)
    assert ("provenance" in result.stdout) == radius_ok


@pytest.mark.parametrize("state,success", [("running healthy", True), ("restarting unhealthy", False), ("running starting", False)])
def test_radius_gate_rejects_restart_and_starting(tmp_path, state, success):
    result = bash_run(tmp_path, "\n".join([
        "COMPOSE_PROJECT=fixture",
        f"docker() {{ echo '{state}'; }}",
        "sleep() { :; }",
        function("wait_freeradius"),
        "wait_freeradius",
    ]))
    assert (result.returncode == 0) == success


def test_candidate_uses_final_directory_before_compose_and_old_env_on_failure():
    apply = function("apply_update")
    assert apply.index('write_transaction "PREPARED"') < apply.index('mv -- "${STAGING}"')
    assert apply.index('mv -- "${STAGING}" "${RELEASES_DIR}/${TARGET}"') < apply.index('run_compose "${STAGING}"')
    failures = [line for line in apply.splitlines() if 'fail_update "${old_tree}"' in line]
    assert failures and all('"$(compose_env "${old_tree}")"' in line for line in failures)
    assert 'wait_freeradius' in apply and 'verify_compose_working_dir "${STAGING}"' in apply


def test_failed_recovery_preserves_candidate_and_transaction(tmp_path):
    candidate = tmp_path / 'candidate'
    candidate.mkdir()
    result = bash_run(tmp_path, '\n'.join([
        f"STAGING='{candidate.as_posix()}'",
        "STAGING_STARTED=1; ROLLBACK_AUTH=''; TRANSACTION_FILE=/nonexistent/transaction",
        "PROGRESS_CURRENT_STAGE=VERIFYING",
        "restore_previous_stack() { return 1; }",
        "clear_transaction() { echo unexpected-clear; }",
        "write_progress() { :; }",
        "write_journal() { echo \"$*\"; }",
        function('fail_update'),
        "fail_update /old /old/backend/.env 0.3.66 '' failure",
    ]))
    assert result.returncode != 0
    assert candidate.is_dir()
    assert 'unexpected-clear' not in result.stdout
    assert 'PREVIOUS_STACK_RESTORE_FAILED' in result.stdout
    assert 'APP_STACK_RESTORED' not in result.stdout
