"""Exercise post-update cleanup against disposable trees and fake Docker."""
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

import pytest


SOURCE = Path(__file__).resolve().parents[1] / "deployment/v1/agent/hotspot-updater.sh"


def function(name):
    return re.search(
        r"(?ms)^" + name + r"\(\) \{.*?^\}", SOURCE.read_text(encoding="utf-8")
    ).group(0)


def run_cleanup(tmp_path, current="0.3.6", previous="0.3.1", setup="", docker_status=(0, 0), extra=""):
    releases = tmp_path / "releases"
    releases.mkdir()
    for version in ("0.3.1", "0.3.2", "0.3.3", "0.3.4", "0.3.5", "0.3.6", "backup-x"):
        (releases / version).mkdir()
        (releases / version / "sentinel").write_text(version, encoding="utf-8")
    (tmp_path / "state").mkdir()
    (tmp_path / "outside").mkdir()
    (tmp_path / "outside" / "sentinel").write_text("untouched", encoding="utf-8")
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    if docker_status is None:
        # Hide any host Docker executable without hiding realpath/rm/Python.
        docker_setup = 'command() { if [[ "$*" == "-v docker" ]]; then return 1; fi; builtin command "$@"; }'
    else:
        (bin_dir / "docker").write_text(
            '#!/usr/bin/env bash\nprintf "%s\\n" "$*" >> "$ROOT/docker.calls"\n'
            f'if [[ "$1" == image ]]; then exit {docker_status[0]}; fi\n'
            f'exit {docker_status[1]}\n', encoding="utf-8", newline="\n",
        )
        docker_setup = 'chmod +x "$ROOT/bin/docker"; export PATH="$ROOT/bin:$PATH"'
    script = "\n".join([
        "set -Eeuo pipefail",
        f"python3() {{ '{Path(sys.executable).as_posix()}' \"$@\"; }}",
        f"export ROOT=\"$(cd '{tmp_path.as_posix()}' && pwd -P)\"",
        'RELEASES_DIR="$ROOT/releases"; CURRENT_LINK="$ROOT/current"',
        'TRANSACTION_FILE="$ROOT/state/hotspot-upgrade.transaction.json"',
        f'ln -s -- "$RELEASES_DIR/{current}" "$CURRENT_LINK"',
        docker_setup,
        function("version_lt"),
        function("prune_after_update"),
        setup,
        f"prune_after_update '{previous}'",
        'printf "cleanup_exit=%s\\n" "$?"',
        extra,
        'for candidate in "$RELEASES_DIR"/*; do',
        '  if [[ -d "$candidate" && ! -L "$candidate" ]]; then printf "remaining:%s\\n" "${candidate##*/}"; fi',
        'done',
    ])
    path = tmp_path / "check.sh"
    path.write_text(script, encoding="utf-8", newline="\n")
    bash = r"C:\Program Files\Git\bin\bash.exe" if os.name == "nt" else shutil.which("bash")
    env = os.environ.copy()
    if os.name == "nt":
        # MSYS symlinks work without Windows native-symlink privileges.
        env["MSYS"] = "winsymlinks:sys"
    result = subprocess.run([bash, path.as_posix()], capture_output=True, text=True, env=env)
    assert result.returncode == 0, result.stderr
    assert "cleanup_exit=0" in result.stdout
    assert (tmp_path / "outside" / "sentinel").read_text(encoding="utf-8") == "untouched"
    return result, {
        line.removeprefix("remaining:") for line in result.stdout.splitlines()
        if line.startswith("remaining:")
    }


@pytest.mark.parametrize("current,previous,kept", [
    ("0.3.6", "0.3.1", {"0.3.1", "0.3.4", "0.3.5", "0.3.6"}),
    ("0.3.1", "0.3.2", {"0.3.1", "0.3.2", "0.3.4", "0.3.5", "0.3.6"}),
    ("0.3.2", "0.3.1", {"0.3.1", "0.3.2", "0.3.4", "0.3.5", "0.3.6"}),
    ("0.3.6", "0.3.5", {"0.3.4", "0.3.5", "0.3.6"}),
])
def test_preserves_newest_current_previous_and_non_version(tmp_path, current, previous, kept):
    result, remaining = run_cleanup(tmp_path, current, previous)
    assert remaining == kept | {"backup-x"}
    assert f"Cleanup: removed_releases={6 - len(kept)}" in result.stdout
    assert (tmp_path / "docker.calls").read_text().splitlines() == [
        "image prune -f", "builder prune -f --keep-storage 2GB",
    ]


def test_numeric_order_and_nested_current_target_are_protected(tmp_path):
    result, remaining = run_cleanup(
        tmp_path, previous="0.3.2", setup='''
mkdir "$RELEASES_DIR/0.3.9" "$RELEASES_DIR/0.3.10" "$RELEASES_DIR/1.0.0"
mkdir "$RELEASES_DIR/0.3.1/nested"
rm -- "$CURRENT_LINK"
ln -s -- "$RELEASES_DIR/0.3.1/nested" "$CURRENT_LINK"
''',
    )
    assert remaining == {"0.3.1", "0.3.2", "0.3.9", "0.3.10", "1.0.0", "backup-x"}
    assert "removed_releases=4" in result.stdout


@pytest.mark.parametrize("status", [None, (1, 0), (0, 1), (1, 1)])
def test_docker_missing_or_failing_is_warning_only(tmp_path, status):
    result, remaining = run_cleanup(tmp_path, docker_status=status)
    assert "Warning:" in result.stderr
    assert remaining == {"0.3.1", "0.3.4", "0.3.5", "0.3.6", "backup-x"}
    if status is not None:
        assert (tmp_path / "docker.calls").read_text().splitlines() == [
            "image prune -f", "builder prune -f --keep-storage 2GB",
        ]


def test_version_named_symlink_and_internal_symlink_do_not_escape(tmp_path):
    result, remaining = run_cleanup(tmp_path, setup='''
ln -s -- "$ROOT/outside" "$RELEASES_DIR/0.0.1"
ln -s -- "$ROOT/outside" "$RELEASES_DIR/0.3.2/outside"
''', extra='test -L "$RELEASES_DIR/0.0.1"')
    assert "removed_releases=2" in result.stdout
    assert "0.3.2" not in remaining


@pytest.mark.parametrize("setup", [
    # Any surviving transaction, including corrupt/linked metadata, blocks tree pruning.
    'printf \'{"old_tree":"%s/0.3.2"}\' "$RELEASES_DIR" > "$TRANSACTION_FILE"',
    'printf broken > "$TRANSACTION_FILE"',
    'ln -s -- "$ROOT/missing" "$TRANSACTION_FILE"',
    'rm -- "$CURRENT_LINK"; ln -s -- "$ROOT/outside" "$CURRENT_LINK"',
    'rm -- "$CURRENT_LINK"; ln -s -- "$ROOT/missing" "$CURRENT_LINK"',
    'mv -- "$RELEASES_DIR" "$ROOT/real-releases"; ln -s -- "$ROOT/real-releases" "$RELEASES_DIR"',
    'version_lt() { return 2; }',
])
def test_uncertain_paths_or_version_order_skip_only_release_step(tmp_path, setup):
    result, remaining = run_cleanup(tmp_path, setup=setup)
    assert remaining == {"0.3.1", "0.3.2", "0.3.3", "0.3.4", "0.3.5", "0.3.6", "backup-x"}
    assert "Warning: release cleanup skipped" in result.stderr
    assert "removed_releases=0" in result.stdout
    assert len((tmp_path / "docker.calls").read_text().splitlines()) == 2


@pytest.mark.parametrize("previous", ["../outside", "0.3.99", ""])
def test_invalid_or_missing_previous_release_prevents_tree_deletion(tmp_path, previous):
    result, remaining = run_cleanup(tmp_path, previous=previous)
    assert len(remaining) == 7
    assert "Warning: release cleanup skipped" in result.stderr


def test_delete_failure_does_not_stop_other_steps(tmp_path):
    result, remaining = run_cleanup(tmp_path, setup='''
rm() { if [[ "$*" == *"/0.3.2" ]]; then return 1; fi; command rm "$@"; }
''')
    assert remaining == {"0.3.1", "0.3.2", "0.3.4", "0.3.5", "0.3.6", "backup-x"}
    assert "Warning: release cleanup failed for 0.3.2" in result.stderr
    assert "removed_releases=1" in result.stdout
    assert len((tmp_path / "docker.calls").read_text().splitlines()) == 2


@pytest.mark.parametrize("change", [
    'printf broken > "$TRANSACTION_FILE"',
    'rm -- "$CURRENT_LINK"; ln -s -- "$RELEASES_DIR/0.3.2" "$CURRENT_LINK"',
])
def test_protected_paths_changed_during_sort_stop_deletion(tmp_path, change):
    # Change a protected pointer after the initial checks, before any deletion.
    setup = function("version_lt").replace("version_lt()", "original_version_lt()")
    setup += '\nversion_lt() {\n' + change + '\noriginal_version_lt "$@";\n}'
    result, remaining = run_cleanup(tmp_path, setup=setup)
    assert len(remaining) == 7
    assert "Warning: release cleanup stopped; protected paths changed" in result.stderr
    assert "removed_releases=0" in result.stdout
    assert len((tmp_path / "docker.calls").read_text().splitlines()) == 2


def test_less_than_three_versions_is_safe_under_nounset(tmp_path):
    result, remaining = run_cleanup(tmp_path, setup='''
command rm -rf -- "$RELEASES_DIR/0.3.2" "$RELEASES_DIR/0.3.3" "$RELEASES_DIR/0.3.4" "$RELEASES_DIR/0.3.5"
''')
    assert remaining == {"0.3.1", "0.3.6", "backup-x"}
    assert "removed_releases=0" in result.stdout


def test_cleanup_follows_commit_and_never_runs_during_rollback_or_recovery(tmp_path):
    apply = function("apply_update")
    commit = apply[apply.index('  atomic_switch_current "${RELEASES_DIR}/${TARGET}"'):]
    assert commit.index("atomic_switch_current") < commit.index("write_state") < commit.index("clear_transaction")
    assert commit.index("clear_transaction") < commit.index('write_journal "COMPLETED"') < commit.index("prune_after_update")
    for name in ("rollback_to", "recover_interrupted_transaction", "recover_previous", "fail_update", "cleanup"):
        assert "prune_after_update" not in function(name)
    # Even an unexpected cleanup failure cannot change the committed update outcome.
    script = "\n".join([
        "set -Eeuo pipefail; RELEASES_DIR=/fixture/releases; TARGET=0.3.6; from=0.3.1; migration_status=OFF",
        "atomic_switch_current() { :; }; write_state() { :; }; clear_transaction() { :; }",
        "write_progress() { :; }; write_journal() { echo \"journal:$1\"; }",
        "prune_after_update() { return 9; }",
        "finish_update() {", commit,
        "finish_update",
    ])
    path = tmp_path / "check.sh"
    path.write_text(script, encoding="utf-8", newline="\n")
    bash = r"C:\Program Files\Git\bin\bash.exe" if os.name == "nt" else shutil.which("bash")
    result = subprocess.run([bash, path.as_posix()], capture_output=True, text=True)
    assert result.returncode == 0, result.stderr
    assert result.stdout.strip() == "journal:COMPLETED"
    assert "Warning: post-update cleanup failed" in result.stderr
