"""P5 — distribution backup/restore scripts: encryption, permissions, verify-first restore.

Covers scripts/backup.sh + scripts/restore.sh (standalone customer flow) and
deployment/v1/backup/{backup,restore}.sh (+ the deployment/backup wrappers).

No real Postgres/Docker/age: fake `docker`, `pg_dump` and `age` are put on
PATH. The fake age is a reversible stub (header line + payload) that records argv.
Scripts run through bash (Git Bash on Windows); skipped when bash is unavailable.
"""
from __future__ import annotations

import gzip
import hashlib
import http.server
import io
import os
import shutil
import subprocess
import tarfile
import threading
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS_BACKUP = ROOT / "scripts" / "backup.sh"
SCRIPTS_RESTORE = ROOT / "scripts" / "restore.sh"
V1_DIR = ROOT / "deployment" / "v1"
V1_BACKUP = V1_DIR / "backup" / "backup.sh"
V1_RESTORE = V1_DIR / "backup" / "restore.sh"
WRAP_BACKUP = ROOT / "deployment" / "backup" / "backup.sh"
WRAP_RESTORE = ROOT / "deployment" / "backup" / "restore.sh"

RECIPIENT = "age1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq"
SECRET_MARKER = "ghcr-token-sentinel-5521"
ENV_MARKER = "POSTGRES_PASSWORD=env-sentinel-8841"
SQL_MARKER = "totp_secret_marker_7731"
HEADER = b"FAKEAGE1\n"


def _find_bash() -> str | None:
    override = os.environ.get("BASH_EXE")
    if override and Path(override).exists():
        return override
    if os.name == "nt":
        git_bash = Path(r"C:\Program Files\Git\bin\bash.exe")
        return str(git_bash) if git_bash.exists() else None
    return shutil.which("bash")


BASH = _find_bash()
pytestmark = pytest.mark.skipif(BASH is None, reason="bash (Git Bash on Windows) is not available")
POSIX_MODES = os.name != "nt"


def posix(p: Path | str) -> str:
    p = str(p)
    if os.name == "nt" and len(p) > 1 and p[1] == ":":
        return "/" + p[0].lower() + p[2:].replace("\\", "/")
    return p


FAKE_AGE = r"""#!/usr/bin/env bash
echo "age $*" >> "${FAKE_LOG:-/dev/null}"
mode=enc; infile=""
while [ $# -gt 0 ]; do
  case "$1" in
    -d) mode=dec ;;
    -r|-R|-i) shift ;;
    -*) ;;
    *) infile="$1" ;;
  esac
  shift
done
[ -n "$infile" ] && exec < "$infile"
if [ "$mode" = enc ]; then
  printf 'FAKEAGE1\n'; cat
else
  IFS= read -r h
  [ "$h" = "FAKEAGE1" ] || { echo "age: fake: bad header / no identity matched" >&2; exit 1; }
  cat
fi
"""

FAKE_PG_DUMP = r"""#!/usr/bin/env bash
echo "pg_dump $*" >> "${FAKE_LOG:-/dev/null}"
case "${FAKE_PG_DUMP_MODE:-ok}" in
  ok)    printf 'PGDMP-fake %s\n' "totp_secret_marker_7731" ;;
  fail)  printf 'PGDMP-partial\n'; echo "pg_dump: error: connection refused" >&2; exit 1 ;;
  empty) exit 0 ;;
esac
"""

FAKE_DOCKER = r"""#!/usr/bin/env bash
echo "docker $*" >> "${FAKE_LOG:-/dev/null}"
[ "$1" = "compose" ] || exit 0
shift
while [ $# -gt 0 ]; do
  case "$1" in
    -f|-p|--project-name|--project-directory|--env-file) shift 2 ;;
    *) break ;;
  esac
done
sub="${1:-}"; shift || true
case "$sub" in
  ps) echo cid123 ;;
  exec)
    all="$*"
    case "$all" in
      *pg_dump*) pg_dump $all; exit $? ;;
      *pg_restore*) cat > "${FAKE_RESTORE_OUT:?}" ;;
      *) cat > /dev/null ;;
    esac ;;
  *) : ;;
esac
exit 0
"""


class Env:
    def __init__(self, tmp: Path):
        self.tmp = tmp
        self.bin = tmp / "bin"
        self.bin.mkdir()
        self.log = tmp / "calls.log"
        self.restore_out = tmp / "restore-stdin.dump"
        self.identity = tmp / "identity.txt"
        for name, body in (("age", FAKE_AGE), ("pg_dump", FAKE_PG_DUMP), ("docker", FAKE_DOCKER)):
            self.install(name, body)
        self.identity.write_text("AGE-SECRET-KEY-FAKE-FOR-TESTS\n", newline="\n")
        if POSIX_MODES:
            self.identity.chmod(0o600)

    def install(self, name: str, body: str) -> None:
        f = self.bin / name
        f.write_bytes(body.replace("\r\n", "\n").encode())
        f.chmod(0o755)

    def remove(self, name: str) -> None:
        (self.bin / name).unlink()

    def env(self, **extra: str) -> dict[str, str]:
        e = {k: v for k, v in os.environ.items()
             if not k.startswith(("BACKUP_", "NEOSECRA_", "FAKE_", "PG"))}
        e["PATH"] = str(self.bin) + os.pathsep + e.get("PATH", "")
        e["FAKE_LOG"] = posix(self.log)
        e["FAKE_RESTORE_OUT"] = posix(self.restore_out)
        e.update(extra)
        return e

    def run(self, script: Path, *args: str, stdin: str = "", **env: str):
        return subprocess.run([BASH, posix(script), *args], env=self.env(**env),
                              input=stdin, capture_output=True, text=True, timeout=180)

    def calls(self) -> str:
        return self.log.read_text() if self.log.exists() else ""


def _real_age_present() -> bool:
    for d in os.environ.get("PATH", "").split(os.pathsep):
        if d and ((Path(d) / "age").exists() or (Path(d) / "age.exe").exists()):
            return True
    return False


def _unwrap(raw: bytes) -> bytes:
    assert raw.startswith(HEADER), "artifact was not passed through age"
    return raw[len(HEADER):]


def _tar_members(archive_gz: bytes) -> dict[str, bytes]:
    out: dict[str, bytes] = {}
    with tarfile.open(fileobj=io.BytesIO(archive_gz), mode="r:gz") as t:
        for m in t.getmembers():
            if m.isfile():
                out[m.name.lstrip("./")] = t.extractfile(m).read()
    return out


# =========================================================== scripts/backup.sh

class Std:
    """Standalone customer flow (scripts/backup.sh, scripts/restore.sh)."""

    def __init__(self, env: Env):
        self.e = env
        t = env.tmp
        self.home = t / "home"
        dep = self.home / "current" / "deployment"
        dep.mkdir(parents=True)
        (dep / "docker-compose.v1.yml").write_text("services: {}\n")
        (dep / ".env.v1").write_text("POSTGRES_USER=neosecra\nPOSTGRES_DB=neosecra_assessment\n" + ENV_MARKER + "\n")
        (dep / "VERSION").write_text("1.2.3\n")
        (self.home / "upgrade-journal").mkdir()
        (self.home / "upgrade-journal" / "j1.json").write_text("{}\n")
        self.secrets = t / "secrets"
        self.secrets.mkdir()
        (self.secrets / "ghcr-token").write_text(SECRET_MARKER + "\n")
        self.base = t / "backups"

    def base_env(self, **extra: str) -> dict[str, str]:
        d = dict(NEOSECRA_HOME=posix(self.home), BACKUP_BASE=posix(self.base),
                 NEOSECRA_SECRETS_DIR=posix(self.secrets),
                 NEOSECRA_BACKUP_LOCK=posix(self.e.tmp / "lock"),
                 NEOSECRA_BACKUP_MIN_DISK_MB="1")
        d.update(extra)
        return d

    def backup(self, **extra: str):
        return self.e.run(SCRIPTS_BACKUP, **self.base_env(**extra))

    def restore(self, *args: str, **extra: str):
        extra.setdefault("BACKUP_AGE_IDENTITY_FILE", posix(self.e.identity))
        return self.e.run(SCRIPTS_RESTORE, *args, **self.base_env(**extra))

    def files(self) -> list[Path]:
        return sorted(self.base.rglob("*")) if self.base.exists() else []

    def make_encrypted(self) -> Path:
        r = self.backup(BACKUP_AGE_RECIPIENT=RECIPIENT)
        assert r.returncode == 0, r.stderr
        (f,) = [p for p in self.files() if p.name.endswith(".tar.gz.age")]
        return f


@pytest.fixture()
def env(tmp_path: Path) -> Env:
    return Env(tmp_path)


@pytest.fixture()
def std(env: Env) -> Std:
    return Std(env)


def test_static_markers_all_scripts():
    for p in (SCRIPTS_BACKUP, V1_BACKUP):
        t = p.read_text()
        assert "umask 077" in t and "set -x" not in t
        assert "chmod 0700" in t and "chmod 0600" in t
        assert ".partial" in t and "pipefail" in t
        assert "BACKUP_AGE_RECIPIENT" in t and "BACKUP_AGE_RECIPIENTS_FILE" in t
        assert "BACKUP_ALLOW_PLAINTEXT" in t and ".PLAINTEXT" in t
        assert "mktemp" in t
    for p in (SCRIPTS_RESTORE, V1_RESTORE):
        t = p.read_text()
        assert "umask 077" in t and "set -x" not in t
        assert "--confirm" in t and "--legacy-plaintext" in t
        assert "BACKUP_AGE_IDENTITY_FILE" in t and "age -d -i" in t
        assert "sha256sum" in t


@pytest.mark.parametrize("script", [SCRIPTS_BACKUP, SCRIPTS_RESTORE, V1_BACKUP, V1_RESTORE,
                                    WRAP_BACKUP, WRAP_RESTORE])
def test_bash_syntax(script: Path):
    r = subprocess.run([BASH, "-n", posix(script)], capture_output=True, text=True)
    assert r.returncode == 0, r.stderr


def test_std_no_recipient_fails_closed(std: Std):
    r = std.backup()
    assert r.returncode != 0
    assert "recipient" in r.stderr.lower()
    assert std.files() == []
    assert "docker" not in std.e.calls()


def test_std_age_missing_fails(std: Std):
    if _real_age_present():
        pytest.skip("a real age binary is on PATH; cannot simulate a missing age")
    std.e.remove("age")
    r = std.backup(BACKUP_AGE_RECIPIENT=RECIPIENT)
    assert r.returncode != 0
    assert std.files() == []


def test_std_plaintext_exception(std: Std):
    r = std.backup(BACKUP_ALLOW_PLAINTEXT="1")
    assert r.returncode == 0, r.stderr
    assert "NOT ENCRYPTED" in r.stderr
    (f,) = [p for p in std.files() if p.name.endswith(".tar.gz")]
    assert ".PLAINTEXT" in f.name
    members = _tar_members(f.read_bytes())
    assert any(k.endswith(".dump") and not k.endswith(".age") for k in members)


def test_std_stream_failure_leaves_nothing(std: Std):
    r = std.backup(BACKUP_AGE_RECIPIENT=RECIPIENT, FAKE_PG_DUMP_MODE="fail")
    assert r.returncode != 0
    assert std.files() == [], [p.name for p in std.files()]


def test_std_empty_dump_refused(std: Std):
    r = std.backup(BACKUP_AGE_RECIPIENT=RECIPIENT, FAKE_PG_DUMP_MODE="empty")
    assert r.returncode != 0
    assert std.files() == []


@pytest.mark.parametrize("missing", ["secrets", "env", "journal"])
def test_std_incomplete_inputs_refused(std: Std, missing: str):
    if missing == "secrets":
        shutil.rmtree(std.secrets)
    elif missing == "env":
        (std.home / "current" / "deployment" / ".env.v1").unlink()
    else:
        shutil.rmtree(std.home / "upgrade-journal")
    r = std.backup(BACKUP_AGE_RECIPIENT=RECIPIENT)
    assert r.returncode != 0
    assert "refusing" in r.stderr.lower()
    assert not [p for p in std.files() if p.is_file()], [p.name for p in std.files()]
    assert not any(p.name.startswith(".staging") for p in std.files())


def test_std_success_secrets_only_inside_encrypted_archive(std: Std):
    f = std.make_encrypted()
    sha = Path(str(f) + ".sha256").read_text().split()
    assert sha[0] == hashlib.sha256(f.read_bytes()).hexdigest() and sha[1] == f.name
    raw = f.read_bytes()
    assert raw.startswith(HEADER)
    for marker in (SECRET_MARKER, ENV_MARKER, SQL_MARKER):
        assert marker.encode() not in raw
    members = _tar_members(_unwrap(raw))
    assert members["secrets/ghcr-token"].decode().strip() == SECRET_MARKER
    assert ENV_MARKER.encode() in members["env.v1"]
    (dump_name,) = [k for k in members if k.startswith("neosecra-db-")]
    assert dump_name.endswith(".dump.age")                       # dump encrypted while streaming
    assert SQL_MARKER.encode() in _unwrap(members[dump_name])
    # no leftovers: staging dir, partial files
    left = [p.name for p in std.files()]
    assert all(not n.startswith(".staging") and not n.endswith(".partial") for n in left), left
    assert f"age -r {RECIPIENT}" in std.e.calls()
    assert SECRET_MARKER not in std.e.calls() and "env-sentinel" not in std.e.calls()


def test_std_recipients_file(std: Std):
    rf = std.e.tmp / "recipients.txt"
    rf.write_text(RECIPIENT + "\n", newline="\n")
    r = std.backup(BACKUP_AGE_RECIPIENTS_FILE=posix(rf))
    assert r.returncode == 0, r.stderr
    assert "-R " in std.e.calls()


@pytest.mark.skipif(not POSIX_MODES, reason="POSIX permission bits are not meaningful on Windows")
def test_std_permissions_and_tightening(std: Std):
    std.base.mkdir()
    std.base.chmod(0o755)
    old = std.base / "neosecra-backup-20200101-000000.tar.gz"
    old.write_bytes(b"x")
    old.chmod(0o644)
    r = std.backup(BACKUP_AGE_RECIPIENT=RECIPIENT)
    assert r.returncode == 0, r.stderr
    assert "tightening" in r.stderr
    assert oct(std.base.stat().st_mode & 0o777) == "0o700"
    for p in std.files():
        assert oct(p.stat().st_mode & 0o777) == "0o600", p.name


def test_std_restore_default_is_verify_only(std: Std):
    f = std.make_encrypted()
    std.e.log.write_text("")
    r = std.restore(str(posix(f)))
    assert r.returncode == 0, r.stderr
    assert "Verify-only" in r.stderr
    c = std.e.calls()
    assert "pg_restore" not in c and " stop " not in c and " up " not in c
    assert not std.e.restore_out.exists()


def test_std_restore_bad_hash_no_writes(std: Std):
    f = std.make_encrypted()
    Path(str(f) + ".sha256").write_text("0" * 64 + "  " + f.name + "\n")
    r = std.restore(posix(f), "--confirm", "--yes")
    assert r.returncode != 0 and "MISMATCH" in r.stderr
    assert not std.e.restore_out.exists()
    assert " stop " not in std.e.calls()


def test_std_restore_undecryptable_no_writes(std: Std):
    f = std.make_encrypted()
    f.write_bytes(b"NOTAGE\n" + f.read_bytes())
    Path(str(f) + ".sha256").write_text(hashlib.sha256(f.read_bytes()).hexdigest() + "  " + f.name + "\n")
    r = std.restore(posix(f), "--confirm", "--yes")
    assert r.returncode != 0
    assert not std.e.restore_out.exists()
    assert " stop " not in std.e.calls()


def test_std_restore_yes_without_confirm_never_writes(std: Std):
    f = std.make_encrypted()
    r = std.restore(posix(f), "--yes")
    assert r.returncode == 0
    assert not std.e.restore_out.exists()
    assert " stop " not in std.e.calls()


def _restore_confirm(std: Std, *args: str):
    """Run a --confirm restore; the script's final smoke check curls
    127.0.0.1:$FRONTEND_PORT/api/v1/health, so serve a 200 on a free port."""

    class _Health(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            self.send_response(200)
            self.end_headers()

        def log_message(self, *a):
            pass

    srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), _Health)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    envf = std.home / "current" / "deployment" / ".env.v1"
    envf.write_text(envf.read_text() + f"FRONTEND_PORT={srv.server_address[1]}\n")
    try:
        return std.restore(*args, "--confirm", "--yes")
    finally:
        srv.shutdown()


def test_std_restore_confirm_streams_decrypted_dump(std: Std):
    f = std.make_encrypted()
    r = _restore_confirm(std, posix(f))
    assert r.returncode == 0, r.stderr
    assert SQL_MARKER in std.e.restore_out.read_text()
    assert "pg_restore" in std.e.calls()
    assert SECRET_MARKER not in r.stdout + r.stderr


def test_std_restore_requires_identity(std: Std):
    f = std.make_encrypted()
    r = std.restore(posix(f), "--confirm", "--yes", BACKUP_AGE_IDENTITY_FILE="")
    assert r.returncode != 0 and "BACKUP_AGE_IDENTITY_FILE" in r.stderr
    assert not std.e.restore_out.exists()


@pytest.mark.skipif(not POSIX_MODES, reason="POSIX permission bits are not meaningful on Windows")
def test_std_restore_rejects_loose_identity(std: Std):
    f = std.make_encrypted()
    std.e.identity.chmod(0o644)
    r = std.restore(posix(f), "--confirm", "--yes")
    assert r.returncode != 0 and "0600" in r.stderr
    assert not std.e.restore_out.exists()


def test_std_restore_legacy_plaintext_needs_flag(std: Std):
    # old format: plain tar.gz + hash-only .sha256 (pre-P5 backups)
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as t:
        data = b"PGDMP-legacy\n"
        ti = tarfile.TarInfo("./neosecra-db-20200101-000000.dump")
        ti.size = len(data)
        t.addfile(ti, io.BytesIO(data))
    legacy = std.e.tmp / "neosecra-backup-20200101-000000.tar.gz"
    legacy.write_bytes(buf.getvalue())
    Path(str(legacy) + ".sha256").write_text(hashlib.sha256(legacy.read_bytes()).hexdigest() + "\n")

    r = std.restore(posix(legacy))
    assert r.returncode != 0 and "--legacy-plaintext" in r.stderr

    ok = std.restore(posix(legacy), "--legacy-plaintext")
    assert ok.returncode == 0, ok.stderr
    assert not std.e.restore_out.exists()

    w = _restore_confirm(std, posix(legacy), "--legacy-plaintext")
    assert w.returncode == 0, w.stderr
    assert std.e.restore_out.read_bytes() == b"PGDMP-legacy\n"


# ===================================================== deployment/v1/backup

class V1:
    """Copy of deployment/{backup,v1/backup,v1/lib} in a scratch tree (scripts source ../lib)."""

    def __init__(self, env: Env):
        self.e = env
        self.root = env.tmp / "deployment"
        v1 = self.root / "v1"
        shutil.copytree(V1_DIR / "lib", v1 / "lib")
        (v1 / "backup").mkdir(parents=True)
        (self.root / "backup").mkdir()
        for src, dst in ((V1_BACKUP, v1 / "backup" / "backup.sh"),
                         (V1_RESTORE, v1 / "backup" / "restore.sh"),
                         (WRAP_BACKUP, self.root / "backup" / "backup.sh"),
                         (WRAP_RESTORE, self.root / "backup" / "restore.sh")):
            dst.write_bytes(src.read_bytes().replace(b"\r\n", b"\n"))
            dst.chmod(0o755)
        (v1 / "VERSION").write_text("1.2.3\n")
        (v1 / "release-manifest.yaml").write_text("version: 1.2.3\n")
        (v1 / "docker-compose.v1.yml").write_text("services: {}\n")
        (v1 / ".env.v1").write_text("POSTGRES_USER=neosecra\nPOSTGRES_DB=neosecra_assessment\n" + ENV_MARKER + "\n")
        self.v1 = v1
        self.target = env.tmp / "target"

    def base_env(self, **extra: str) -> dict[str, str]:
        d = dict(NEOSECRA_INSTALL_ROOT=posix(self.e.tmp / "install"))
        d.update(extra)
        return d

    def backup(self, wrapper: bool = False, **extra: str):
        s = self.root / "backup" / "backup.sh" if wrapper else self.v1 / "backup" / "backup.sh"
        return self.e.run(s, "--target", posix(self.target), **self.base_env(**extra))

    def restore(self, *args: str, wrapper: bool = False, **extra: str):
        extra.setdefault("BACKUP_AGE_IDENTITY_FILE", posix(self.e.identity))
        s = self.root / "backup" / "restore.sh" if wrapper else self.v1 / "backup" / "restore.sh"
        return self.e.run(s, "--target", posix(self.target), *args, **self.base_env(**extra))

    def files(self) -> list[Path]:
        return sorted(self.target.rglob("*")) if self.target.exists() else []

    def make_encrypted(self, **kw) -> None:
        r = self.backup(BACKUP_AGE_RECIPIENT=RECIPIENT, **kw)
        assert r.returncode == 0, r.stdout + r.stderr


@pytest.fixture()
def v1(env: Env) -> V1:
    return V1(env)


def test_v1_no_recipient_fails_closed(v1: V1):
    r = v1.backup()
    assert r.returncode != 0
    assert "recipient" in (r.stderr + r.stdout).lower()
    assert v1.files() == []
    assert "pg_dump" not in v1.e.calls()


def test_v1_age_missing_fails(v1: V1):
    if _real_age_present():
        pytest.skip("a real age binary is on PATH; cannot simulate a missing age")
    v1.e.remove("age")
    r = v1.backup(BACKUP_AGE_RECIPIENT=RECIPIENT)
    assert r.returncode != 0
    assert v1.files() == []


def test_v1_plaintext_exception(v1: V1):
    r = v1.backup(BACKUP_ALLOW_PLAINTEXT="1")
    assert r.returncode == 0, r.stdout + r.stderr
    assert "NOT ENCRYPTED" in r.stderr
    names = [p.name for p in v1.files()]
    assert "neosecra-1.2.3-db.PLAINTEXT.sql.gz" in names
    assert "neosecra-1.2.3-config.PLAINTEXT.tar.gz" in names


def test_v1_stream_failure_leaves_nothing(v1: V1):
    r = v1.backup(BACKUP_AGE_RECIPIENT=RECIPIENT, FAKE_PG_DUMP_MODE="fail")
    assert r.returncode != 0
    assert [p for p in v1.files() if p.is_file()] == []


def test_v1_missing_env_refused_and_cleaned(v1: V1):
    (v1.v1 / ".env.v1").unlink()
    r = v1.backup(BACKUP_AGE_RECIPIENT=RECIPIENT)
    assert r.returncode != 0
    assert [p for p in v1.files() if p.is_file()] == [], [p.name for p in v1.files()]
    assert not any(p.name.startswith(".staging") for p in v1.files())


def test_v1_success_env_only_inside_encrypted_bundle(v1: V1):
    v1.make_encrypted()
    names = {p.name for p in v1.files()}
    db, cfg = "neosecra-1.2.3-db.sql.gz.age", "neosecra-1.2.3-config.tar.gz.age"
    assert {db, cfg, db + ".sha256", cfg + ".sha256", "MANIFEST"} <= names
    assert not any(n.endswith(".partial") or n.startswith(".staging") for n in names)
    assert "env.v1" not in names                                   # no loose secret file anymore
    for n in (db, cfg):
        raw = (v1.target / n).read_bytes()
        sha = (v1.target / (n + ".sha256")).read_text().split()
        assert sha[0] == hashlib.sha256(raw).hexdigest() and sha[1] == n
        assert raw.startswith(HEADER)
    manifest = (v1.target / "MANIFEST").read_text()
    assert "encrypted: age" in manifest and "env-sentinel" not in manifest
    cfg_members = _tar_members(_unwrap((v1.target / cfg).read_bytes()))
    assert ENV_MARKER.encode() in cfg_members["env.v1"]
    assert SQL_MARKER.encode() in gzip.decompress(_unwrap((v1.target / db).read_bytes()))
    for p in v1.files():
        assert ENV_MARKER.encode() not in p.read_bytes() and "env-sentinel" not in v1.e.calls()
    if POSIX_MODES:
        assert oct(v1.target.stat().st_mode & 0o777) == "0o700"
        for p in v1.files():
            assert oct(p.stat().st_mode & 0o777) == "0o600", p.name


def test_v1_wrapper_delegates_to_canonical(v1: V1):
    r = v1.backup(wrapper=True, BACKUP_AGE_RECIPIENT=RECIPIENT)
    assert r.returncode == 0, r.stdout + r.stderr
    assert (v1.target / "neosecra-1.2.3-db.sql.gz.age").exists()


def test_v1_restore_verify_ok_and_confirm_refused(v1: V1):
    v1.make_encrypted()
    ok = v1.restore()
    assert ok.returncode == 0, ok.stdout + ok.stderr
    assert "No changes were made" in (ok.stdout + ok.stderr)
    assert not v1.e.restore_out.exists()
    refused = v1.restore("--confirm")
    assert refused.returncode != 0 and "NOT IMPLEMENTED" in (refused.stdout + refused.stderr)
    assert not v1.e.restore_out.exists()
    w = v1.restore(wrapper=True)
    assert w.returncode == 0, w.stdout + w.stderr


def test_v1_restore_bad_hash_fails(v1: V1):
    v1.make_encrypted()
    (v1.target / "neosecra-1.2.3-db.sql.gz.age.sha256").write_text("0" * 64 + "  x\n")
    r = v1.restore()
    assert r.returncode != 0 and "MISMATCH" in (r.stdout + r.stderr)


def test_v1_restore_undecryptable_fails(v1: V1):
    v1.make_encrypted()
    f = v1.target / "neosecra-1.2.3-db.sql.gz.age"
    f.write_bytes(b"NOTAGE\n" + f.read_bytes())
    Path(str(f) + ".sha256").write_text(hashlib.sha256(f.read_bytes()).hexdigest() + "  " + f.name + "\n")
    r = v1.restore()
    assert r.returncode != 0


def test_v1_restore_requires_identity(v1: V1):
    v1.make_encrypted()
    r = v1.restore(BACKUP_AGE_IDENTITY_FILE="")
    assert r.returncode != 0 and "BACKUP_AGE_IDENTITY_FILE" in (r.stdout + r.stderr)


def test_v1_restore_legacy_plaintext_needs_flag(v1: V1):
    v1.target.mkdir()
    (v1.target / "neosecra-1.0.0-db.sql").write_text("SELECT 1;\n")
    r = v1.restore()
    assert r.returncode != 0 and "--legacy-plaintext" in (r.stdout + r.stderr)
    ok = v1.restore("--legacy-plaintext")
    assert ok.returncode == 0, ok.stdout + ok.stderr
    assert "NOT encrypted" in (ok.stdout + ok.stderr)
