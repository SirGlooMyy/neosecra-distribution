"""Execute real rollback/upgrade policy gates in an isolated installation.

Signature/host commands are doubles, not cryptographic acceptance evidence.
No customer env is copied: rollback has an empty synthetic env and stops at
postflight; upgrade stops after policy selection at its missing-env gate.
"""

import hashlib
import gzip
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
            "BACKUP_AGE_IDENTITY_FILE", "BACKUP_AGE_RECIPIENT", "BACKUP_AGE_RECIPIENTS_FILE",
            "BACKUP_ALLOW_PLAINTEXT", "ROLLBACK_DB_WAIT_TIMEOUT", "ROLLBACK_DB_WAIT_INTERVAL",
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
            "agent/update-agent.sh", "backup/backup.sh",
        ):
            write(self.tree / relative, (V1 / relative).read_text(encoding="utf-8"))
        if os.name == "nt":
            # Windows cannot fsync directory descriptors. Only this filesystem
            # helper is doubled; auth, metadata and service dispatch stay real.
            with (self.tree / "lib/common.sh").open("a", encoding="utf-8", newline="\n") as stream:
                stream.write('\natomic_replace_file() { chmod "${3:-600}" "$1" && mv -f -- "$1" "$2"; }\n')
        # Recovery locking is outside this contract (fcntl is absent on Windows).
        write(self.tree / "upgrade/recovery.py", "import sys\nprint('fixture-recovery:' + ' '.join(sys.argv[1:]))\n")
        # Execute the real fail-closed backup; only its external commands are fake.
        backup_source = (self.tree / "backup/backup.sh").read_text(encoding="utf-8")
        backup_source = backup_source.replace('TARGET=""; AUTO=0',
                                              'printf "backup-invoked:%s\\n" "$*" >> "$TEST_COMMAND_LOG"\n'
                                              'TEST_BACKUP_ARGS="$*"\nTARGET=""; AUTO=0')
        write(self.tree / "backup/backup.sh", backup_source +
              '\nprintf "backup:%s\\n" "$TEST_BACKUP_ARGS" >> "$TEST_COMMAND_LOG"\n')
        write(self.tree / "docker-compose.v1.yml", "services: {}\n")
        write(self.tree / ".env.v1", "")
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
            "BACKUP_AGE_RECIPIENT": "fixture-public-recipient",
            "ROLLBACK_DB_WAIT_TIMEOUT": "2", "ROLLBACK_DB_WAIT_INTERVAL": "1",
            "TEMP": str(root), "TMP": str(root), "TMPDIR": shell_path(root),
        }
        write(self.bin / "docker", '''#!/usr/bin/env bash
printf 'docker:%s\n' "$*" >> "$TEST_COMMAND_LOG"
case " $* " in
  *" ps "*)
    if [[ "${TEST_STACK_RUNNING:-1}" == 1 || -f "$TEST_FIXTURES/postgres-started" ]]; then
      echo fixture-running-container
    fi ;;
  *" up -d postgres "*)
    [[ "${TEST_POSTGRES_UP_EXIT:-0}" == 0 ]] || exit "$TEST_POSTGRES_UP_EXIT"
    touch "$TEST_FIXTURES/postgres-started" ;;
  *" pg_isready "*)
    count_file="$TEST_FIXTURES/ready-count"
    count=$(cat "$count_file" 2>/dev/null || echo 0)
    count=$((count + 1))
    printf '%s\n' "$count" > "$count_file"
    if [[ "${TEST_PG_READY_HANG:-0}" == 1 ]]; then /usr/bin/sleep 10; fi
    [[ "${TEST_PG_READY_EXIT:-0}" == 0 && "$count" -ge "${TEST_PG_READY_AFTER:-1}" ]] ;;
  *" pg_dump "*)
    [[ "${TEST_PG_DUMP_EXIT:-0}" == 0 ]] || exit "$TEST_PG_DUMP_EXIT"
    [[ "${TEST_PG_DUMP_EMPTY:-0}" == 1 ]] || echo 'SELECT 1;' ;;
  *" psql "*) "$TEST_FAKE_BIN/psql" "$@" ;;
esac
''')
        write(self.bin / "psql", '''#!/usr/bin/env bash
printf 'psql:call\n' >> "$TEST_COMMAND_LOG"
cat >> "$TEST_FIXTURES/psql-input.log"
if [[ $(grep -c '^psql:call' "$TEST_COMMAND_LOG") -gt 1 ]]; then
  exit "${TEST_PSQL_REPLAY_EXIT:-0}"
fi
exit "${TEST_PSQL_EXIT:-0}"
''')
        write(self.bin / "age", '''#!/usr/bin/env bash
printf 'age:%s\n' "$*" >> "$TEST_COMMAND_LOG"
if [[ "$1" == -d ]]; then
  [[ "${TEST_AGE_DECRYPT_EXIT:-0}" == 0 ]] || exit "$TEST_AGE_DECRYPT_EXIT"
  if [[ "${TEST_AGE_FAIL_REPLAY:-0}" == 1 ]] && [[ $(grep -c '^age:-d ' "$TEST_COMMAND_LOG") -gt 1 ]]; then
    exit 23
  fi
  { IFS= read -r marker; [[ "$marker" == fixture-age ]] || exit 23; cat; } < "$4"
else
  [[ "${TEST_AGE_ENCRYPT_EXIT:-0}" == 0 ]] || exit "$TEST_AGE_ENCRYPT_EXIT"
  printf 'fixture-age\n'
  cat
fi
''')
        write(self.bin / "minisign", '''#!/usr/bin/env bash
printf 'minisign:%s\n' "$*" >> "$TEST_COMMAND_LOG"
exit "${TEST_MINISIGN_EXIT:-0}"
''')
        for name in ("systemctl", "sudo", "cosign", "pg_restore", "pg_dump", "logger"):
            write(self.bin / name, f'#!/usr/bin/env bash\nprintf "{name}:%s\\n" "$*" >> "$TEST_COMMAND_LOG"\nexit 99\n')
        write(self.bin / "sleep", '#!/usr/bin/env bash\nif [[ "${TEST_REAL_SLEEP:-0}" == 1 ]]; then /usr/bin/sleep "$@"; fi\n')
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
    code = sys.stdin.read()
    # Keep the real pointer switch; only its final POSIX directory fsync is
    # unavailable on Windows. No policy/auth/database code is bypassed.
    if not (os.name == 'nt' and 'os.open(sys.argv[1], os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))' in code):
        exec(compile(code, '<stdin>', 'exec'), {'__name__': '__main__'})
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

    def encrypted_backup(self):
        self.set_policy("backup_restore")
        self.identity = self.root / "fixture-identity"
        # Synthetic identity, never a real private key.
        write(self.identity, "fixture-identity\n")
        self.identity.chmod(0o600)
        self.env["BACKUP_AGE_IDENTITY_FILE"] = shell_path(self.identity)
        self.encrypted_dump = self.backup / "neosecra-1.0.0-db.sql.gz.age"
        self.encrypted_dump.write_bytes(b"fixture-age\n" + gzip.compress(b"SELECT 11;\n"))
        if os.name == "nt":
            # Exercise encryption/service dispatch on Windows with a known-safe
            # synthetic mode. Real POSIX permission tests are explicitly skipped.
            write(self.bin / "stat", '''#!/usr/bin/env bash
if [[ "${@: -1}" == "$BACKUP_AGE_IDENTITY_FILE" ]]; then echo 600;
else /usr/bin/stat "$@"; fi
''')

    def complete_postflight(self):
        write(self.target / "install/postflight.sh", "#!/usr/bin/env bash\nexit 0\n")

    def calls(self):
        return self.commands.read_text(encoding="utf-8") if self.commands.exists() else ""

    def snapshot(self):
        files = {path.relative_to(self.install).as_posix(): path.read_bytes()
                 for path in self.install.rglob("*") if path.is_file() and not path.is_symlink()}
        pointer = self.run_shell('readlink "$NEOSECRA_INSTALL_ROOT/current"')
        assert pointer.returncode == 0, pointer.stderr
        return files, pointer.stdout

    def upgrade(self, policy):
        # This pre-existing test covers policy selection at the missing-env
        # gate, not backup execution; keep its original isolation boundary.
        self.tree.joinpath(".env.v1").unlink()
        write(self.tree / "backup/backup.sh", '''#!/usr/bin/env bash
set -euo pipefail
printf 'backup:%s\n' "$*" >> "$TEST_COMMAND_LOG"
[[ "$1" == --target ]]
mkdir -p "$2"
printf 'fixture encrypted backup\n' > "$2/neosecra-2.0.0-db.sql.gz.age"
''')
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
    assert "backup:--target" in calls
    assert " pg_dump " in calls
    assert calls.count(" psql ") == 2
    sql = (sandbox.root / "psql-input.log").read_text()
    assert "DROP SCHEMA" in sql and "SELECT 1;" in sql
    assert "legacy plaintext database backup" in result.stderr
    assert list((sandbox.install / "backups").glob("*-pre-rollback-2.0.0/neosecra-*-db.sql.gz.age"))
    assert not list((sandbox.install / "backups").glob("*-pre-rollback-2.0.0/*.sql"))


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


def test_encrypted_rollback_streams_sql_and_creates_encrypted_safety_backup(sandbox):
    sandbox.encrypted_backup()
    sandbox.complete_postflight()
    result = sandbox.rollback()
    assert result.returncode == 0, result.stdout + result.stderr
    calls = sandbox.calls()
    assert calls.count("age:-d ") == 2  # Preflight and strict replay.
    assert "backup:--target" in calls
    assert calls.index("backup:--target") < calls.index(" stop")
    assert calls.count(" psql -v ON_ERROR_STOP=1 ") == 2
    sql = (sandbox.root / "psql-input.log").read_text()
    assert "DROP SCHEMA" in sql and "SELECT 11;" in sql
    assert "SELECT 1;" not in sql  # Encrypted dump wins over the legacy fixture.
    safety = list((sandbox.install / "backups").glob("*-pre-rollback-2.0.0"))
    assert len(safety) == 1
    assert list(safety[0].glob("*-db.sql.gz.age"))
    assert list(safety[0].glob("*-config.tar.gz.age"))
    assert not list(safety[0].rglob("*.sql"))
    assert not list(sandbox.tree.rglob("*.sql"))
    assert not list(sandbox.target.rglob("*.sql"))
    assert (sandbox.install / "state/installed-version").read_text() == "1.0.0\n"
    pointer = sandbox.run_shell('readlink "$NEOSECRA_INSTALL_ROOT/current"')
    assert pointer.stdout.strip().endswith("/releases/1.0.0")


def test_stopped_stack_starts_current_database_then_backs_up_and_restores(sandbox):
    sandbox.encrypted_backup()
    sandbox.complete_postflight()
    sandbox.env.update(TEST_STACK_RUNNING="0", TEST_PG_READY_AFTER="2")
    result = sandbox.rollback()
    assert result.returncode == 0, result.stdout + result.stderr
    calls = sandbox.calls()
    start = calls.index(" up -d postgres")
    ready = calls.index(" pg_isready ")
    invoked = calls.index("backup-invoked:--target")
    completed = calls.index("backup:--target")
    stopped = calls.index(" stop")
    restored = calls.index(" psql ")
    assert start < ready < invoked < completed < stopped < restored
    assert calls[:invoked].count(" pg_isready ") == 2
    assert calls.count(" pg_dump ") == 1
    startup = next(line for line in calls.splitlines() if " up -d postgres" in line)
    assert f"--project-directory {shell_path(sandbox.tree)} " in startup
    assert f"-f {shell_path(sandbox.tree / 'docker-compose.v1.yml')} " in startup
    assert str(sandbox.target.as_posix()) not in startup
    assert calls.count("age:-d ") == 2
    sql = (sandbox.root / "psql-input.log").read_text()
    assert "DROP SCHEMA" in sql and "SELECT 11;" in sql
    assert (sandbox.install / "state/installed-version").read_text() == "1.0.0\n"
    safety = list((sandbox.install / "backups").glob("*-pre-rollback-2.0.0"))
    assert len(safety) == 1
    assert list(safety[0].glob("*-db.sql.gz.age"))
    assert list(safety[0].glob("*-config.tar.gz.age"))
    assert not list(safety[0].rglob("*.sql"))
    assert not list(safety[0].rglob("*.PLAINTEXT.*"))


@pytest.mark.parametrize("failure", ["startup", "not-ready", "hung-probe"])
def test_stopped_stack_database_failure_prevents_backup_shutdown_and_schema_reset(sandbox, failure):
    sandbox.encrypted_backup()
    sandbox.env.update(TEST_STACK_RUNNING="0", ROLLBACK_DB_WAIT_TIMEOUT="1", TEST_REAL_SLEEP="1")
    if failure == "startup":
        sandbox.env["TEST_POSTGRES_UP_EXIT"] = "23"
    elif failure == "not-ready":
        sandbox.env["TEST_PG_READY_EXIT"] = "1"
    else:
        sandbox.env["TEST_PG_READY_HANG"] = "1"
    before = sandbox.snapshot()
    result = sandbox.rollback()
    assert result.returncode == 12, result.stdout + result.stderr
    assert "Database service could not be started for the safety backup; nothing was changed" in result.stderr
    calls = sandbox.calls()
    assert calls.count(" up -d postgres") == 1
    assert not any(word in calls for word in ("backup-invoked:", " stop", " psql ", "--force-recreate"))
    assert sandbox.snapshot() == before
    assert (sandbox.root / "postgres-started").exists() == (failure != "startup")
    assert not (sandbox.root / "psql-input.log").exists()


@pytest.mark.parametrize("failure", ["recipient", "pg-dump", "empty-dump", "encryption"])
def test_stopped_stack_safety_backup_failure_prevents_shutdown_and_schema_reset(sandbox, failure):
    sandbox.encrypted_backup()
    sandbox.env.update(TEST_STACK_RUNNING="0", BACKUP_ALLOW_PLAINTEXT="1")
    if failure == "recipient":
        del sandbox.env["BACKUP_AGE_RECIPIENT"]
    elif failure == "pg-dump":
        sandbox.env["TEST_PG_DUMP_EXIT"] = "23"
    elif failure == "empty-dump":
        sandbox.env["TEST_PG_DUMP_EMPTY"] = "1"
    else:
        sandbox.env["TEST_AGE_ENCRYPT_EXIT"] = "23"
    before = sandbox.snapshot()
    result = sandbox.rollback()
    assert result.returncode == 12, result.stdout + result.stderr
    assert "Encrypted safety backup failed" in result.stderr
    calls = sandbox.calls()
    assert calls.index(" up -d postgres") < calls.index("backup-invoked:--target")
    assert not any(word in calls for word in ("backup:--target", " stop", " psql ", "--force-recreate"))
    assert sandbox.snapshot() == before
    assert (sandbox.root / "postgres-started").exists()
    assert not (sandbox.root / "psql-input.log").exists()
    assert not list((sandbox.install / "backups").glob("*-pre-rollback-2.0.0/*"))


@pytest.mark.parametrize("running", ["0", "1"])
@pytest.mark.parametrize("encrypted", [False, True])
def test_safety_backup_cannot_be_skipped_or_plaintext(sandbox, running, encrypted):
    if encrypted:
        sandbox.encrypted_backup()
    else:
        sandbox.set_policy("backup_restore")
    sandbox.complete_postflight()
    sandbox.env.update(TEST_STACK_RUNNING=running, BACKUP_ALLOW_PLAINTEXT="1")
    result = sandbox.rollback()
    assert result.returncode == 0, result.stdout + result.stderr
    calls = sandbox.calls()
    assert calls.index("backup-invoked:--target") < calls.index(" pg_dump ")
    assert calls.index("backup:--target") < calls.index(" stop") < calls.index(" psql ")
    safety = list((sandbox.install / "backups").glob("*-pre-rollback-2.0.0"))
    assert len(safety) == 1
    assert list(safety[0].glob("*-db.sql.gz.age"))
    assert list(safety[0].glob("*-config.tar.gz.age"))
    assert "encrypted: age" in (safety[0] / "MANIFEST").read_text()
    assert not list(safety[0].rglob("*.PLAINTEXT.*"))
    assert not list(safety[0].rglob("*.sql"))
    if running == "1":
        assert " up -d postgres" not in calls[:calls.index("backup-invoked:--target")]
        assert " pg_isready " not in calls


@pytest.mark.parametrize("failure", ["unset", "zero", "over-limit", "invalid"])
def test_database_readiness_uses_bounded_defaults_and_rejects_invalid_timeout(sandbox, failure):
    sandbox.encrypted_backup()
    sandbox.env["TEST_STACK_RUNNING"] = "0"
    if failure == "unset":
        del sandbox.env["ROLLBACK_DB_WAIT_TIMEOUT"]
        del sandbox.env["ROLLBACK_DB_WAIT_INTERVAL"]
        sandbox.complete_postflight()
        result = sandbox.rollback()
        assert result.returncode == 0, result.stdout + result.stderr
    else:
        sandbox.env["ROLLBACK_DB_WAIT_TIMEOUT"] = {"zero": "0", "over-limit": "61", "invalid": "bad"}[failure]
        before = sandbox.snapshot()
        result = sandbox.rollback()
        assert result.returncode == 12, result.stdout + result.stderr
        assert sandbox.snapshot() == before
        assert "backup-invoked:" not in sandbox.calls()
        assert " stop" not in sandbox.calls()


@pytest.mark.parametrize("failure", ["unset-identity", "missing-identity", "missing-age", "decrypt", "gzip", "empty"])
def test_encrypted_preflight_failure_changes_nothing(sandbox, failure):
    sandbox.encrypted_backup()
    if failure == "unset-identity":
        del sandbox.env["BACKUP_AGE_IDENTITY_FILE"]
    elif failure == "missing-identity":
        sandbox.identity.unlink()
    elif failure == "missing-age":
        sandbox.bin.joinpath("age").unlink()
        # Mask a host age binary without changing unrelated command discovery.
        with (sandbox.tree / "lib/common.sh").open("a", encoding="utf-8", newline="\n") as stream:
            stream.write('\ncommand() { if [[ "$1" == -v && "${2:-}" == age ]]; then return 1; fi; builtin command "$@"; }\n')
    elif failure == "decrypt":
        sandbox.env["TEST_AGE_DECRYPT_EXIT"] = "23"
    elif failure == "gzip":
        sandbox.encrypted_dump.write_bytes(b"fixture-age\ninvalid gzip")
    else:
        sandbox.encrypted_dump.write_bytes(b"fixture-age\n" + gzip.compress(b""))
    before = sandbox.snapshot()
    assert_rejected_without_mutation(sandbox, sandbox.rollback(), before, 12)


@pytest.mark.skipif(os.name == "nt", reason="Windows does not enforce POSIX identity modes/symlinks")
@pytest.mark.parametrize("unsafe", ["mode-0644", "symlink"])
def test_unsafe_identity_is_rejected_before_mutation(sandbox, unsafe):
    sandbox.encrypted_backup()
    if unsafe == "mode-0644":
        sandbox.identity.chmod(0o644)
    else:
        destination = sandbox.identity.with_name("fixture-identity-target")
        sandbox.identity.rename(destination)
        sandbox.identity.symlink_to(destination)
    before = sandbox.snapshot()
    assert_rejected_without_mutation(sandbox, sandbox.rollback(), before, 12)


@pytest.mark.skipif(os.name == "nt", reason="Windows does not enforce POSIX identity mode 0600")
def test_real_mode_0600_identity_accepts_encrypted_rollback(sandbox):
    sandbox.encrypted_backup()
    result = sandbox.rollback("--dry-run")
    assert result.returncode == 0, result.stdout + result.stderr


@pytest.mark.parametrize("encrypted", [False, True])
def test_missing_recipient_refuses_safety_backup_without_mutation(sandbox, encrypted):
    sandbox.env["TEST_STACK_RUNNING"] = "1"
    if encrypted:
        sandbox.encrypted_backup()
    else:
        sandbox.set_policy("backup_restore")
    del sandbox.env["BACKUP_AGE_RECIPIENT"]
    sandbox.env["BACKUP_ALLOW_PLAINTEXT"] = "1"  # Rollback must override this exception.
    before = sandbox.snapshot()
    result = sandbox.rollback()
    assert "No age recipient configured" in result.stderr
    assert_rejected_without_mutation(sandbox, result, before, 12)
    assert "backup-invoked:--target" in sandbox.calls()
    assert not (sandbox.root / "psql-input.log").exists()


@pytest.mark.parametrize("running", ["0", "1"])
def test_encrypted_dry_run_validates_without_safety_backup_or_mutation(sandbox, running):
    sandbox.encrypted_backup()
    del sandbox.env["BACKUP_AGE_RECIPIENT"]
    before = sandbox.snapshot()
    sandbox.env["TEST_STACK_RUNNING"] = running
    result = sandbox.rollback("--dry-run")
    assert result.returncode == 0, result.stdout + result.stderr
    assert sandbox.calls().count("age:-d ") == 1
    assert sandbox.snapshot() == before
    assert not any(word in sandbox.calls() for word in (" psql ", " stop", " up ", "backup:", "backup-invoked:"))


def test_encrypted_dry_run_fails_closed_on_bad_ciphertext(sandbox):
    sandbox.encrypted_backup()
    sandbox.env["TEST_AGE_DECRYPT_EXIT"] = "23"
    before = sandbox.snapshot()
    assert_rejected_without_mutation(sandbox, sandbox.rollback("--dry-run"), before, 12)


@pytest.mark.parametrize("failure", ["age", "gunzip", "psql"])
def test_replay_pipeline_failure_is_not_reported_as_success(sandbox, failure):
    sandbox.encrypted_backup()
    sandbox.complete_postflight()
    if failure == "age":
        sandbox.env["TEST_AGE_FAIL_REPLAY"] = "1"
    elif failure == "gunzip":
        write(sandbox.bin / "gunzip", '''#!/usr/bin/env bash
count_file="$TEST_FIXTURES/gunzip-count"
count=$(cat "$count_file" 2>/dev/null || echo 0)
count=$((count + 1))
printf '%s\n' "$count" > "$count_file"
if [[ "$count" -gt 1 ]]; then cat >/dev/null; exit 23; fi
/usr/bin/gunzip "$@"
''')
    else:
        sandbox.env["TEST_PSQL_REPLAY_EXIT"] = "23"
    result = sandbox.rollback()
    assert result.returncode == 1, result.stdout + result.stderr
    assert "Database restore pipeline failed" in result.stderr
    assert "--force-recreate" not in sandbox.calls()
    assert (sandbox.install / "state/installed-version").read_text() == "2.0.0\n"


def test_auto_selection_uses_newest_backup_for_target(sandbox):
    sandbox.encrypted_backup()
    newer = sandbox.install / "backups/newer-1.0.0"
    newer.mkdir()
    (newer / sandbox.encrypted_dump.name).write_bytes(b"fixture-age\n" + gzip.compress(b"SELECT 22;\n"))
    os.utime(sandbox.backup, (1000, 1000))
    os.utime(newer, (2000, 2000))
    result = sandbox.rollback()
    assert result.returncode == 42, result.stdout + result.stderr
    assert "SELECT 22;" in (sandbox.root / "psql-input.log").read_text()


def test_explicit_from_backup_restores_upgrade_backup_directory(sandbox):
    sandbox.encrypted_backup()
    source = sandbox.install / "backups/pre-upgrade-selected"
    source.mkdir()
    (source / sandbox.encrypted_dump.name).write_bytes(b"fixture-age\n" + gzip.compress(b"SELECT 33;\n"))
    result = sandbox.rollback("--from-backup", shell_path(source))
    assert result.returncode == 42, result.stdout + result.stderr
    assert "SELECT 33;" in (sandbox.root / "psql-input.log").read_text()


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
