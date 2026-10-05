"""Execute recovery gates without Docker or customer state."""
import os
from pathlib import Path
import json
import re
import shutil
import subprocess
import sys

import pytest


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "deployment/v1/agent/hotspot-updater.sh"


def function(name):
    source = SOURCE.read_text(encoding="utf-8")
    return re.search(r"(?ms)^" + name + r"\(\) \{.*?^\}", source).group(0)


def source_between(start, end):
    source = SOURCE.read_text(encoding="utf-8")
    return source[source.index(start):source.index(end)]


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
        function("start_previous_stack"),
        function("restore_previous_stack"),
        'restore_previous_stack /releases/0.3.66 /releases/0.3.66/backend/.env',
    ]))
    assert (result.returncode == 0) == radius_ok, result.stderr
    commands = [line for line in result.stdout.splitlines() if line.startswith("compose:")]
    assert commands and all(line.startswith("compose:/releases/0.3.66 /releases/0.3.66/backend/.env ") for line in commands)
    assert commands[0].endswith("build api worker beat admin portal freeradius")
    assert any("up -d postgres redis clickhouse minio createbuckets" in line for line in commands)
    assert ("provenance" in result.stdout) == radius_ok


def previous_stack_script(tmp_path, entrypoint, fail_command=""):
    release = tmp_path / "releases" / "0.3.66"
    (release / "backend").mkdir(parents=True)
    (release / "backend" / ".env").write_text("", encoding="utf-8")
    return "\n".join([
        "set -Eeuo pipefail",
        f"RELEASES_DIR='{release.parent.as_posix()}'; TARGET=0.3.66",
        f"FAIL_COMMAND='{fail_command}'",
        'run_compose() { shift 2; printf "compose:%s\\n" "$*"; [[ "$*" != "$FAIL_COMMAND" ]]; }',
        'compose_env() { printf "%s/backend/.env\\n" "$1"; }',
        'current_tree() { printf "%s/0.3.67\\n" "$RELEASES_DIR"; }',
        "current_version() { echo 0.3.67; }",
        'verify_rollback_auth() { echo "auth:$*"; }',
        'verify_release_rollback_metadata() { echo "metadata:$*"; }',
        "wait_api() { echo api; }",
        "wait_freeradius() { echo radius; }",
        'verify_compose_working_dir() { echo "provenance:$*"; }',
        'atomic_switch_current() { echo "switch:$*"; }',
        'write_state() { echo "state:$*"; }',
        'write_journal() { echo "journal:$*"; }',
        function("start_previous_stack"),
        function("restore_previous_stack"),
        function("rollback_to"),
        ("rollback_to" if entrypoint == "rollback_to" else
         f"restore_previous_stack '{release.as_posix()}' '{release.as_posix()}/backend/.env'"),
    ])


def test_manual_rollback_and_recovery_share_migration_free_compose_sequence(tmp_path):
    results = []
    for entrypoint in ("rollback_to", "restore_previous_stack"):
        sandbox = tmp_path / entrypoint
        sandbox.mkdir()
        result = bash_run(sandbox, previous_stack_script(sandbox, entrypoint))
        assert result.returncode == 0, result.stderr
        results.append(result)
    commands = [
        [line.removeprefix("compose:") for line in result.stdout.splitlines() if line.startswith("compose:")]
        for result in results
    ]
    assert commands[0][0] == "down --remove-orphans"
    assert commands[0][1:] == commands[1] == [
        "build api worker beat admin portal freeradius",
        "up -d postgres redis clickhouse minio createbuckets",
        "up -d --no-deps api worker beat admin portal freeradius",
    ]
    assert all("migrate" not in command.split() for sequence in commands for command in sequence)
    # Dependencies have explicit names; application startup must bypass depends_on.
    assert [command for command in commands[0] if command.startswith("up -d")] == [
        "up -d postgres redis clickhouse minio createbuckets",
        "up -d --no-deps api worker beat admin portal freeradius",
    ]
    lines = results[0].stdout.splitlines()
    assert lines[0] == "auth:0.3.66"
    assert lines[1].startswith("metadata:")
    assert lines[2] == "compose:down --remove-orphans"
    health = lines.index("api")
    assert lines[health + 1] == "radius"
    assert lines[health + 2].startswith("provenance:")
    assert lines[health + 3].startswith("switch:")
    assert lines[health + 4:] == [
        "state:0.3.66",
        "journal:ROLLED_BACK 0.3.67  POINTER_ONLY_ROLLBACK",
    ]


@pytest.mark.parametrize("entrypoint", ["rollback_to", "restore_previous_stack"])
@pytest.mark.parametrize("fail_command", [
    "build api worker beat admin portal freeradius",
    "up -d postgres redis clickhouse minio createbuckets",
    "up -d --no-deps api worker beat admin portal freeradius",
])
def test_previous_stack_start_failure_stops_health_and_state_writes(tmp_path, entrypoint, fail_command):
    result = bash_run(tmp_path, previous_stack_script(tmp_path, entrypoint, fail_command))
    assert result.returncode != 0
    lines = result.stdout.splitlines()
    assert lines[-1] == f"compose:{fail_command}"
    assert "api" not in lines and "radius" not in lines
    assert not any(line.startswith(("provenance:", "switch:", "state:", "journal:")) for line in lines)


def test_forward_update_still_runs_migration(tmp_path):
    result = bash_run(tmp_path, "\n".join([
        "set -Eeuo pipefail",
        "STAGING=/releases/0.3.67; old_tree=/releases/0.3.66; from=0.3.66",
        'compose_env() { printf "%s/backend/.env\\n" "$1"; }',
        'run_compose() { shift 2; printf "compose:%s\\n" "$*"; }',
        "fail_update() { return 1; }",
        source_between("  STAGING_STARTED=1\n", "  start_args="),
    ]))
    assert result.returncode == 0, result.stderr
    assert result.stdout.splitlines() == [
        "compose:build --pull=false api worker beat migrate admin portal freeradius",
        "compose:up -d postgres redis clickhouse minio createbuckets",
        "compose:run --rm migrate",
    ]


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


def test_off_migration_metadata_preserves_empty_fields_and_writes_journal(tmp_path):
    staging = tmp_path / "staging"
    old_tree = tmp_path / "old"
    journal = tmp_path / "journal"
    staging.mkdir()
    old_tree.mkdir()
    journal.mkdir()
    metadata = tmp_path / "release-metadata.json"
    metadata.write_text(json.dumps({
        "migration_required": False,
        "migration_strategy": "off",
        "backward_compatible_with_previous_app": True,
        "rollback_safe_without_db_restore": True,
        "migration_checksum": None,
        "schema_from": None,
        "schema_to": None,
        "estimated_lock_seconds": 0,
        "estimated_temp_space_bytes": 0,
    }), encoding="utf-8")
    progress = tmp_path / "progress.json"
    progress.write_text("{}", encoding="utf-8")

    script = "\n".join([
        "set -euo pipefail",
        f"python3() {{ '{Path(sys.executable).as_posix()}' \"$@\"; }}",
        f"ROOT='{tmp_path.as_posix()}'",
        f"JOURNAL_DIR='{journal.as_posix()}'",
        f"PROGRESS_FILE='{progress.as_posix()}'",
        "TARGET='0.3.75'",
        "NEOSECRA_EDITION_ID='standard'",
        "MIGRATION_REQUIRED=0; MIGRATION_STRATEGY=off",
        "MIGRATION_BACKWARD_COMPATIBLE=1; MIGRATION_ROLLBACK_SAFE=1",
        "MIGRATION_CHECKSUM=''; MIGRATION_SCHEMA_FROM=''; MIGRATION_SCHEMA_TO=''",
        "MIGRATION_LOCK_SECONDS=0; MIGRATION_TEMP_SPACE=0",
        "export MIGRATION_REQUIRED MIGRATION_STRATEGY MIGRATION_BACKWARD_COMPATIBLE MIGRATION_ROLLBACK_SAFE",
        "export MIGRATION_CHECKSUM MIGRATION_SCHEMA_FROM MIGRATION_SCHEMA_TO MIGRATION_LOCK_SECONDS MIGRATION_TEMP_SPACE",
        "migration_required() { return 1; }",
        "atomic_replace() { mv -- \"$1\" \"$2\"; }",
        source_between("load_release_metadata()", "compose_file()"),
        source_between("write_journal()", "write_transaction()"),
        f"load_release_metadata '{metadata.as_posix()}' '{staging.as_posix()}' '{old_tree.as_posix()}'",
        "test \"$MIGRATION_REQUIRED|$MIGRATION_STRATEGY|$MIGRATION_BACKWARD_COMPATIBLE|$MIGRATION_ROLLBACK_SAFE|$MIGRATION_CHECKSUM|$MIGRATION_SCHEMA_FROM|$MIGRATION_SCHEMA_TO|$MIGRATION_LOCK_SECONDS|$MIGRATION_TEMP_SPACE\" = '0|off|1|1||||0|0'",
        "write_journal COMPLETED 0.3.74 '' '' SKIPPED_NO_MIGRATION",
    ])
    result = bash_run(tmp_path, script)
    assert result.returncode == 0, result.stderr
    records = list(journal.glob("upgrade-*.json"))
    assert len(records) == 1
    record = json.loads(records[0].read_text(encoding="utf-8"))
    assert record["migration_required"] is False
    assert record["migration_strategy"] == "off"
    assert record["migration_checksum"] is None
    assert record["schema_from"] is None
    assert record["schema_to"] is None
    assert record["estimated_lock_seconds"] == 0
    assert record["estimated_temp_space_bytes"] == 0
