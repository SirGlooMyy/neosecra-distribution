"""Execute real rollback/upgrade policy gates in an isolated installation.

Signature/host commands are doubles, not cryptographic acceptance evidence.
No customer env is copied: rollback has an empty synthetic env and stops at
postflight; upgrade stops after policy selection at its missing-env gate.
"""

import hashlib
import io
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tarfile
from datetime import datetime, timedelta, timezone

import pytest
import yaml


ROOT = Path(__file__).resolve().parents[1]
V1 = ROOT / "deployment/v1"


def shell_path(path):
    text = Path(path).resolve().as_posix()
    if os.name == "nt":
        return "/" + text[0].lower() + text[2:]
    return text


def write(path, content):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8", newline="\n")
    path.chmod(0o755)


def manifest(policy):
    data = {"version": "1.0.0"}
    if policy == "none":
        data.update(upgrade={
            "backup_required": False,
            "migration_required": False,
            "migration_strategy": "off",
            "backward_compatible_with_previous_app": True,
            "rollback_safe_without_db_restore": True,
            "migration_checksum": None,
            "schema_from": None,
            "schema_to": None,
            "estimated_lock_seconds": 0,
            "estimated_temp_space_bytes": 0,
        }, rollback={"database_strategy": "none"})
    elif policy == "backup_restore":
        data.update(upgrade={"backup_required": True},
                    rollback={"database_strategy": "backup_restore"})
    # Legacy deliberately has neither policy nor pointer migration metadata.
    return data


@pytest.fixture
def sandbox(tmp_path, monkeypatch):
    if os.name == "nt":
        bash = Path(r"C:\Program Files\Git\bin\bash.exe")
        if not bash.is_file():
            pytest.skip("Git Bash required: C:\\Program Files\\Git\\bin\\bash.exe missing")
    else:
        bash = shutil.which("bash")
        if not bash:
            pytest.skip("Bash is required to execute rollback/upgrade behavior tests")
    for name in list(os.environ):
        if name.startswith(("NEOSECRA_", "EXPECTED_ROLLBACK_", "UPGRADE_", "TEST_")) or name in {
            "BASH_ENV", "ENV", "CURL_CA_BUNDLE", "EXEC_ID", "HEARTBEAT_PID", "V1_ROOT",
        }:
            monkeypatch.delenv(name, raising=False)
    return PolicySandbox(tmp_path, str(bash))


class PolicySandbox:
    def __init__(self, root, bash):
        self.root, self.bash = root, bash
        self.tree = root / "runtime/v1"
        self.install = root / "install"
        self.target = self.install / "releases/1.0.0"
        self.commands = root / "commands.log"
        self.bin = root / "fake-bin"
        self.auth = root / "auth.json"
        self.backup = self.install / "backups/fixture-1.0.0"
        for relative in (
            "upgrade/rollback.sh", "upgrade/upgrade.sh", "upgrade/verify_rollback_auth.py",
            "upgrade/secure_extract.py", "lib/common.sh", "lib/state.sh",
            "lib/manifest.sh", "lib/docker.sh", "agent/artifact-verifier.sh",
        ):
            write(self.tree / relative, (V1 / relative).read_text(encoding="utf-8"))
        if os.name == "nt":
            # Windows cannot fsync directory descriptors. Only this filesystem
            # helper is doubled; auth, metadata and service dispatch stay real.
            with (self.tree / "lib/common.sh").open("a", encoding="utf-8", newline="\n") as stream:
                stream.write('\natomic_replace_file() { chmod "${3:-600}" "$1" && mv -f -- "$1" "$2"; }\n')
        # Recovery locking is outside this contract (fcntl is absent on Windows).
        write(self.tree / "upgrade/recovery.py", "import sys\nprint('fixture-recovery:' + ' '.join(sys.argv[1:]))\n")
        write(self.tree / "backup/backup.sh", '''#!/usr/bin/env bash
set -euo pipefail
printf 'backup:%s\n' "$*" >> "$TEST_COMMAND_LOG"
[[ "$1" == --target ]]
mkdir -p "$2"
printf 'SELECT 1;\n' > "$2/neosecra-2.0.0-db.sql"
''')
        write(self.tree / "VERSION", "2.0.0\n")
        write(self.target / "VERSION", "1.0.0\n")
        write(self.target / "docker-compose.v1.yml", "services: {}\n")
        write(self.target / ".env.v1", "")
        write(self.target / "install/postflight.sh", "#!/usr/bin/env bash\necho fixture-postflight-stop >&2\nexit 42\n")
        write(self.backup / "neosecra-1.0.0-db.sql", "SELECT 1;\n")
        for name, content in {
            "state/installed-version": "2.0.0\n", "state/active-release": "2.0.0\n",
            "state/monotonic.json": '{"version":"2.0.0"}\n',
            "upgrade-journal/existing.json": '{"status":"completed"}\n',
            "releases/2.0.0/VERSION": "2.0.0\n",
        }.items():
            write(self.install / name, content)
        write(self.tree / ".channel_updated", "2026-01-01T00:00:00Z\n")
        write(root / "test.pub", "fixture public key, not a production trust key\n")
        self.env = {
            "TEST_COMMAND_LOG": str(self.commands), "TEST_FAKE_BIN": str(self.bin),
            "TEST_BASH": bash, "TEST_FIXTURES": str(root),
            "NEOSECRA_INSTALL_ROOT": shell_path(self.install),
            "NEOSECRA_SIGNATURE_PUBKEY": str(root / "test.pub"),
            "NEOSECRA_AGENT_LOCK_HELD": "1",
            "NEOSECRA_CHANNEL_URL": "https://fixture.invalid/channel.json",
            "EXPECTED_ROLLBACK_PRODUCT": "assessment",
            "EXPECTED_ROLLBACK_CHANNEL": "assessment-stable",
            "EXPECTED_ROLLBACK_EDITION": "standard",
            "EXPECTED_ROLLBACK_NONCE": "fixture-rollback-nonce-1234",
            "TEMP": str(root), "TMP": str(root), "TMPDIR": shell_path(root),
        }
        write(self.bin / "docker", '''#!/usr/bin/env bash
printf 'docker:%s\n' "$*" >> "$TEST_COMMAND_LOG"
case " $* " in
  *" ps "*) echo fixture-running-container ;;
  *" pg_dump "*) echo 'SELECT 1;' ;;
  *" psql "*) cat >> "$TEST_FIXTURES/restore-input.sql" ;;
esac
''')
        write(self.bin / "minisign", '''#!/usr/bin/env bash
printf 'minisign:%s\n' "$*" >> "$TEST_COMMAND_LOG"
exit "${TEST_MINISIGN_EXIT:-0}"
''')
        for name in ("systemctl", "sudo", "cosign", "pg_restore", "psql", "pg_dump"):
            write(self.bin / name, f'#!/usr/bin/env bash\nprintf "{name}:%s\\n" "$*" >> "$TEST_COMMAND_LOG"\nexit 99\n')
        write(self.bin / "sleep", "#!/usr/bin/env bash\nexit 0\n")
        write(self.bin / "curl", '''#!/usr/bin/env bash
set -euo pipefail
printf 'curl:%s\n' "$*" >> "$TEST_COMMAND_LOG"
destination=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) shift; destination="$1" ;;
    https://fixture.invalid/*) url="$1" ;;
  esac
  shift
done
case "${url:-}" in
  https://fixture.invalid/channel.json) source="$TEST_FIXTURES/channel.json" ;;
  https://fixture.invalid/archive.tar.gz) source="$TEST_FIXTURES/archive.tar.gz" ;;
  https://fixture.invalid/*.minisig) source="$TEST_FIXTURES/fixture.minisig" ;;
  *) echo 'unexpected network request blocked' >&2; exit 99 ;;
esac
if [[ -n "$destination" ]]; then cp -- "$source" "$destination"; else cat -- "$source"; fi
''')
        # Git Bash launches native Python: translate MSYS paths and route its
        # minisign subprocess through the same PATH command double.
        write(root / "python_bridge.py", '''import os, re, runpy, subprocess, sys
def native(value):
    if os.name == 'nt' and re.match(r'^/[a-zA-Z]/', value):
        return value[1] + ':' + value[2:]
    return value
sys.argv = [native(value) for value in sys.argv[1:]]
for name in ('V1_ROOT', 'NEOSECRA_SIGNATURE_PUBKEY', 'TEMP', 'TMP'):
    if name in os.environ:
        os.environ[name] = native(os.environ[name])
original_run = subprocess.run
def run(command, *args, **kwargs):
    if command[0] == 'minisign':
        command = [os.environ['TEST_BASH'], os.path.join(os.environ['TEST_FAKE_BIN'], 'minisign'), *command[1:]]
    return original_run(command, *args, **kwargs)
subprocess.run = run
if sys.argv[0].endswith('verify_rollback_auth.py') and os.environ.get('TEST_AUTH_VERIFIER_EXIT'):
    print('fixture authorization verifier error', file=sys.stderr)
    raise SystemExit(int(os.environ['TEST_AUTH_VERIFIER_EXIT']))
if sys.argv[0] == '-':
    exec(compile(sys.stdin.read(), '<stdin>', 'exec'), {'__name__': '__main__'})
elif sys.argv[0] == '-c':
    code = sys.argv.pop(1)
    exec(compile(code, '<command>', 'exec'), {'__name__': '__main__'})
else:
    runpy.run_path(sys.argv[0], run_name='__main__')
''')
        write(self.bin / "python3", "#!/usr/bin/env bash\nexec " +
              shlex.quote(Path(sys.executable).as_posix()) + " " +
              shlex.quote((root / "python_bridge.py").as_posix()) + ' "$@"\n')
        self.set_policy("none")
        self.valid_auth()
        # MSYS symlinks do not require Windows developer-mode privileges.
        result = self.run_shell('ln -s "$NEOSECRA_INSTALL_ROOT/releases/2.0.0" "$NEOSECRA_INSTALL_ROOT/current"')
        assert result.returncode == 0, result.stderr

    def run_shell(self, script, *arguments):
        prefix = "export PATH=" + shlex.quote(shell_path(self.bin)) + ':"$PATH"\n'
        return subprocess.run(
            [self.bash, "--noprofile", "--norc", "-eu", "-o", "pipefail", "-c",
             prefix + script, "fixture", *arguments],
            env=dict(os.environ, **self.env, MSYS="winsymlinks:sys"),
            cwd=self.root, capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=60,
        )

    def set_policy(self, policy):
        for path in (self.tree, self.target):
            write(path / "release-manifest.yaml", yaml.safe_dump(manifest(policy)))

    def valid_auth(self):
        write(self.auth, json.dumps({
            "rollback_to": "1.0.0", "product": "assessment", "channel": "assessment-stable",
            "edition": "standard", "nonce": "fixture-rollback-nonce-1234",
            "expires_at": (datetime.now(timezone.utc) + timedelta(days=1)).isoformat(),
            "signatures": {"minisign_signature": "fixture-signature"},
        }))

    def rollback(self, *arguments):
        return self.run_shell('bash -eu "$@"', shell_path(self.tree / "upgrade/rollback.sh"),
                              "--to", "1.0.0", "--auth", shell_path(self.auth), *arguments)

    def calls(self):
        return self.commands.read_text(encoding="utf-8") if self.commands.exists() else ""

    def snapshot(self):
        files = {path.relative_to(self.install).as_posix(): path.read_bytes()
                 for path in self.install.rglob("*") if path.is_file() and not path.is_symlink()}
        pointer = self.run_shell('readlink "$NEOSECRA_INSTALL_ROOT/current"')
        assert pointer.returncode == 0, pointer.stderr
        return files, pointer.stdout

    def upgrade(self, policy):
        self.set_policy(policy)
        data = manifest(policy)
        data["version"] = "3.0.0"
        archive = self.root / "archive.tar.gz"
        with tarfile.open(archive, "w:gz") as bundle:
            for name, content in {
                "VERSION": "3.0.0\n", "lib/common.sh": "# fixture\n",
                "upgrade/upgrade.sh": "# fixture\n", "docker-compose.v1.yml": "services: {}\n",
                "release-manifest.yaml": yaml.safe_dump(data),
            }.items():
                payload = content.encode("utf-8")
                member = tarfile.TarInfo("neosecra-distribution-3.0.0/deployment/" + name)
                member.size = len(payload)
                bundle.addfile(member, io.BytesIO(payload))
        release = {"version": "3.0.0", "archive": {
            "url": "https://fixture.invalid/archive.tar.gz",
            "sha256": hashlib.sha256(archive.read_bytes()).hexdigest(),
            "signature_url": "https://fixture.invalid/archive.tar.gz.minisig",
        }}
        if policy == "none":
            release["migration_contract"] = data["upgrade"]
        write(self.root / "channel.json", json.dumps({
            "channel": "assessment-stable", "product": "assessment", "edition": "standard",
            "status": "available", "current_version": "3.0.0",
            "updated": "2026-09-30T00:00:00Z", "releases": [release],
        }) + "\n")
        write(self.root / "fixture.minisig", "fixture-signature\n")
        return self.run_shell('bash -eu "$@"', shell_path(self.tree / "upgrade/upgrade.sh"), "3.0.0")


def assert_rejected_without_mutation(box, result, before, code):
    assert result.returncode == code, result.stdout + result.stderr
    assert "unbound variable" not in result.stderr
    assert box.snapshot() == before
    assert not any(word in box.calls() for word in (" pg_dump ", " psql ", "pg_restore:", " stop", " up ", "backup:"))


@pytest.mark.parametrize("invalid", ["missing", "malformed", "not-object", "unsigned", "wrong-target", "expired", "wrong-product"])
def test_invalid_authorization_is_fail_closed(sandbox, invalid):
    if invalid == "missing":
        sandbox.auth.unlink()
    elif invalid == "malformed":
        write(sandbox.auth, '{"rollback_to":')
    elif invalid == "not-object":
        write(sandbox.auth, "[]")
    else:
        data = json.loads(sandbox.auth.read_text(encoding="utf-8"))
        if invalid == "unsigned":
            del data["signatures"]
        elif invalid == "wrong-target":
            data["rollback_to"] = "9.0.0"
        elif invalid == "expired":
            data["expires_at"] = "2000-01-01T00:00:00Z"
        else:
            data["product"] = "soc"
        write(sandbox.auth, json.dumps(data))
    before = sandbox.snapshot()
    result = sandbox.rollback("--pointer-only")
    assert "Rollback authorization failed" in result.stderr
    assert_rejected_without_mutation(sandbox, result, before, 4)


@pytest.mark.parametrize("failure", ["authorization-verifier", "minisign"])
def test_authorization_verifier_failure_does_not_continue(sandbox, failure):
    sandbox.env["TEST_AUTH_VERIFIER_EXIT" if failure == "authorization-verifier" else "TEST_MINISIGN_EXIT"] = "23"
    before = sandbox.snapshot()
    result = sandbox.rollback("--pointer-only")
    assert "Rollback authorization failed" in result.stderr
    assert_rejected_without_mutation(sandbox, result, before, 4)
    if failure == "minisign":
        assert "minisign:" in sandbox.calls()


@pytest.mark.parametrize("metadata", ["unsafe", "malformed", "missing"])
def test_pointer_metadata_verifier_failure_does_not_return_success(sandbox, metadata):
    path = sandbox.target / "release-manifest.yaml"
    if metadata == "missing":
        path.unlink()
    elif metadata == "malformed":
        write(path, "upgrade: [")
    else:
        data = manifest("none")
        data["upgrade"]["rollback_safe_without_db_restore"] = False
        write(path, yaml.safe_dump(data))
    before = sandbox.snapshot()
    result = sandbox.rollback("--pointer-only")
    assert "not eligible for database-restore-free rollback" in result.stderr
    assert_rejected_without_mutation(sandbox, result, before, 12)


@pytest.mark.parametrize("policy", ["none", "backup_restore", "legacy"])
def test_rollback_reaches_validation_under_nounset(sandbox, policy):
    sandbox.set_policy(policy)
    before = sandbox.snapshot()
    flags = ("--pointer-only",) if policy == "none" else ()
    result = sandbox.rollback(*flags, "--dry-run")
    assert result.returncode == 0, result.stdout + result.stderr
    assert "Rollback authorization securely verified" in result.stdout
    assert "Rollback dry-run complete" in result.stdout
    assert "unbound variable" not in result.stderr
    assert sandbox.snapshot() == before


def test_pointer_only_never_dispatches_database_restore(sandbox):
    result = sandbox.rollback("--pointer-only")
    assert result.returncode == 42, result.stdout + result.stderr
    assert "fixture-postflight-stop" in result.stderr
    calls = sandbox.calls()
    assert "--force-recreate" in calls  # Passed auth/metadata and restarted app.
    assert not any(word in calls for word in ("pg_dump", "psql", "pg_restore", "backup:"))
    assert (sandbox.install / "state/installed-version").read_text() == "2.0.0\n"


@pytest.mark.parametrize("policy", ["backup_restore", "legacy"])
def test_backup_restore_dispatches_safety_backup_and_sql_without_pointer_metadata(sandbox, policy):
    sandbox.set_policy(policy)
    result = sandbox.rollback("--from-backup", shell_path(sandbox.backup))
    assert result.returncode == 42, result.stdout + result.stderr
    assert "fixture-postflight-stop" in result.stderr
    assert "unbound variable" not in result.stderr
    calls = sandbox.calls()
    assert " pg_dump " in calls
    assert calls.count(" psql ") == 2
    sql = (sandbox.root / "restore-input.sql").read_text()
    assert "DROP SCHEMA" in sql and "SELECT 1;" in sql
    assert list((sandbox.install / "backups").glob("*-pre-rollback-2.0.0/pre-rollback-db.sql"))


def test_inconsistent_pointer_manifest_is_rejected(sandbox):
    data = manifest("none")
    data["upgrade"]["backup_required"] = True
    write(sandbox.tree / "release-manifest.yaml", yaml.safe_dump(data))
    before = sandbox.snapshot()
    result = sandbox.rollback("--pointer-only")
    assert "Inconsistent backup/rollback policy" in result.stderr
    assert_rejected_without_mutation(sandbox, result, before, 12)


def test_generic_agent_pointer_only_option_is_rejected_for_backup_policy(sandbox):
    sandbox.set_policy("backup_restore")
    before = sandbox.snapshot()
    result = sandbox.rollback("--pointer-only")
    assert "Backup-restore policy forbids pointer-only rollback" in result.stderr
    assert_rejected_without_mutation(sandbox, result, before, 12)


@pytest.mark.parametrize("policy", ["none", "backup_restore", "legacy"])
def test_upgrade_selects_policy_under_nounset_before_runtime_changes(sandbox, policy):
    before = sandbox.snapshot()
    result = sandbox.upgrade(policy)
    # No customer env: deliberately stop after policy/backup, before promotion.
    assert result.returncode == 4, result.stdout + result.stderr
    assert "Prepared target release context is incomplete" in result.stderr
    assert "unbound variable" not in result.stderr
    assert "Target release 3.0.0 prepared from signed channel payload" in result.stdout
    calls = sandbox.calls()
    assert ("backup:--target" in calls) == (policy != "none")
    assert "minisign:" in calls
    assert not any(word in calls for word in (" psql ", " stop", " up "))
    after = sandbox.snapshot()
    assert after[1] == before[1]
    for name in ("state/installed-version", "state/active-release", "state/monotonic.json"):
        assert after[0][name] == before[0][name]
