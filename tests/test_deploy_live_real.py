"""Offline integration tests: SSH executes the actual remote Bash against a temp tree.

Only fixture repositories are committed/pushed to local bare origins. No network or
production target is used. POSIX capabilities are probed rather than assumed on NTFS.
"""
from __future__ import annotations

import hashlib
import io
import itertools
import os
import re
import shlex
import stat
import subprocess
import tarfile
import time
from pathlib import Path

import pytest

from test_deploy_live import BASH, SCRIPT, World, _git, _write_tree, pytestmark


SSH_RELAY = """#!/usr/bin/env bash
set -euo pipefail
d="${FAKE_LOG:?}"
n=0; if [ -f "$d/ssh.count" ]; then n=$(cat "$d/ssh.count"); fi
n=$((n+1)); echo "$n" > "$d/ssh.count"
printf '%s\\0' "$@" > "$d/ssh.$n.args"
if [[ -n ${REPLACE_TAR:-} ]]; then
  IFS= read -r encoded
  script=$(printf '%s' "$encoded" | base64 --decode)
  if [[ $script == *'held=0'* ]]; then
    cat > /dev/null
    { printf '%s\\n' "$encoded"; cat -- "$REPLACE_TAR"; } | bash -c "${@: -1}"
  else
    { printf '%s\\n' "$encoded"; cat; } | bash -c "${@: -1}"
  fi
  exit "$?"
fi
exec bash -c "${@: -1}"
"""

MV_FAULT = """#!/usr/bin/env bash
set -euo pipefail
if [[ ${2:-} == -- && ${3:-} == */.deploy-staging/*/files/* ]]; then
  if [[ ${FAULT_KIND:-} == term ]]; then kill -TERM "$PPID"; fi
  echo 'injected move failure' >&2
  exit 99
fi
exec /usr/bin/mv "$@"
"""

BASE_FILES = {"scripts/util.py": "print('committed')\n", "docs/readme.md": "guide\n"}


class RealWorld:
    def __init__(self, tmp: Path):
        self.tmp = tmp
        self.bin = tmp / "bin"
        self.bin.mkdir()
        (self.bin / "ssh").write_text(SSH_RELAY, encoding="utf-8", newline="\n")
        (self.bin / "ssh").chmod(0o755)
        self.env = dict(os.environ)
        self.env.update(
            FAKE_BIN=self.bin.as_posix(),
            GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull,
            GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@example.invalid",
            GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@example.invalid",
            GIT_TERMINAL_PROMPT="0",
        )
        self._seq = itertools.count(1)
        self.repo = tmp / "repo"
        self.repo.mkdir()
        self.origin = tmp / "origin.git"
        self.git("init", "-q", "-b", "main")
        _git(tmp, "init", "-q", "--bare", "-b", "main", self.origin.as_posix(), env=self.env)
        self.git("remote", "add", "origin", self.origin.as_posix())
        self.sha = self.commit(BASE_FILES)
        self.allow = tmp / "allow.txt"
        self.allow.write_text("**/*\n", encoding="utf-8", newline="\n")
        self.target = tmp / "distribution"
        self.target.mkdir()

    def git(self, *args: str) -> str:
        return _git(self.repo, *args, env=self.env)

    def commit(self, files: dict[str, str], executable: str | None = None) -> str:
        _write_tree(self.repo, files)
        self.git("add", "-A")
        if executable:
            self.git("update-index", "--chmod=+x", executable)
        self.git("commit", "-q", "-m", "fixture")
        self.git("push", "-q", "origin", "main")
        return self.git("rev-parse", "HEAD")

    def shell(self, script: str, *args: str) -> subprocess.CompletedProcess:
        proc = subprocess.run([BASH, "-c", script, "test", *args], env=self.env,
                              capture_output=True, text=True, encoding="utf-8", timeout=60)
        assert proc.returncode == 0, proc.stderr
        return proc

    def unix(self, path: Path) -> str:
        if os.name == "nt":
            return self.shell('cygpath -au "$1"', path.as_posix()).stdout.strip()
        return path.as_posix()

    def mode(self, path: Path) -> str:
        return self.shell('stat -c %a -- "$1"', path.as_posix()).stdout.strip()

    def posix_modes(self):
        probe = self.tmp / "mode-probe"
        probe.write_bytes(b"probe")
        self.shell('chmod 600 -- "$1"', probe.as_posix())
        if self.mode(probe) != "600":
            pytest.skip("Git Bash/NTFS chmod 600 kaydetmiyor; POSIX mod geri donusu Ubuntu'da kosulmali")

    def symlink(self, dest: Path, link: Path, directory: bool = True):
        try:
            link.symlink_to(dest, target_is_directory=directory)
        except OSError as exc:
            pytest.skip(f"Symlink yetkisi/Developer Mode yok: {getattr(exc, 'winerror', None) or exc.errno}")
        if self.shell('if [[ -L $1 ]]; then echo yes; fi', link.as_posix()).stdout.strip() != "yes":
            pytest.skip("Git Bash bu dosya sistemindeki symlink'i -L ile tanimiyor")

    def run(self, *args: str, extra_env: dict | None = None):
        return World.run(self, *args, extra_env=extra_env)

    def deploy(self, apply: bool = False, profile: str = "distribution", extra_env=None):
        args = ["--profile", profile, "--ref", self.sha, "--target",
                f"deploy@example.invalid:{self.unix(self.target)}", "--allowlist", self.allow.as_posix()]
        if apply:
            args.append("--apply")
        return self.run(*args, extra_env=extra_env)

    def backup(self) -> Path:
        backups = list((self.target / ".deploy-backups").iterdir())
        assert len(backups) == 1
        return backups[0]

    def rollback(self, apply: bool = True):
        args = ["--profile", "distribution", "--rollback", self.backup().name, "--target",
                f"deploy@example.invalid:{self.unix(self.target)}"]
        if apply:
            args.append("--apply")
        return self.run(*args)

    def fault(self):
        (self.bin / "mv").write_text(MV_FAULT, encoding="utf-8", newline="\n")
        (self.bin / "mv").chmod(0o755)


@pytest.fixture
def real(tmp_path) -> RealWorld:
    return RealWorld(tmp_path)


def snapshot(root: Path):
    result = {}
    for path in [root, *root.rglob("*")]:
        st = path.lstat()
        if path.is_symlink():
            content = os.readlink(path)
        elif path.is_file():
            content = path.read_bytes()
        else:
            content = None
        result[path.relative_to(root).as_posix()] = (stat.S_IFMT(st.st_mode), stat.S_IMODE(st.st_mode), st.st_mtime_ns, content)
    return result


def manifest(backup: Path):
    return {row.split("\t", 3)[3]: row.split("\t", 3)[:3]
            for row in (backup / "MANIFEST.sha256").read_text().splitlines()}


def test_full_apply_files_modes_stamp_and_blob_bytes(real: RealWorld):
    run = real.deploy(True)
    assert run.rc == 0, run.text
    for path, content in BASE_FILES.items():
        assert (real.target / path).read_bytes() == content.encode()
        assert real.mode(real.target / path) == "644"
    assert f"commit={real.sha}\n" in (real.target / ".deployed-commit").read_text()
    assert not (real.target / ".deploy-lock").exists()
    assert not (real.target / ".deploy-incomplete").exists()
    assert not list((real.target / ".deploy-staging").iterdir())
    assert {"NEW-FILES", "PREVIOUS-STAMP", "STAMP-PRESENT", "NEW-DIRS"} <= manifest(real.backup()).keys()


def test_executable_mode_from_git(real: RealWorld):
    real.sha = real.commit({"scripts/run.sh": "#!/bin/sh\necho ready\n"}, "scripts/run.sh")
    run = real.deploy(True)
    assert run.rc == 0, run.text
    assert real.mode(real.target / "scripts/run.sh") == "755"


@pytest.mark.parametrize("position", ["ancestor", "target-root", "file", "stamp", "stamp-new", "backup", "staging", "lock", "backup-child"])
def test_symlinks_rejected_before_any_write(real: RealWorld, position: str):
    outside = real.tmp / "outside"
    outside.mkdir()
    (outside / "sentinel").write_bytes(b"untouched")
    if position == "ancestor":
        real.symlink(outside, real.target / "scripts")
    elif position == "target-root":
        real.target.rmdir()
        real.symlink(outside, real.target)
    elif position == "file":
        (real.target / "scripts").mkdir()
        real.symlink(outside / "sentinel", real.target / "scripts/util.py", False)
    elif position.startswith("stamp"):
        name = ".deployed-commit.new" if position == "stamp-new" else ".deployed-commit"
        real.symlink(outside / "sentinel", real.target / name, False)
    elif position == "backup-child":
        (real.target / ".deploy-backups").mkdir()
        real.symlink(outside, real.target / ".deploy-backups/old")
    else:
        name = {"backup": ".deploy-backups", "staging": ".deploy-staging", "lock": ".deploy-lock"}[position]
        real.symlink(outside, real.target / name)
    before, outside_before = snapshot(real.target), snapshot(outside)
    run = real.deploy(True)
    assert run.rc != 0 and "symlink" in run.err, run.text
    assert snapshot(real.target) == before and snapshot(outside) == outside_before


@pytest.mark.parametrize("path", ["scripts/util.py", ".deployed-commit", ".deployed-commit.new"])
def test_existing_directory_at_file_path_is_rejected(real: RealWorld, path: str):
    (real.target / path).mkdir(parents=True)
    before = snapshot(real.target)
    run = real.deploy(True)
    assert run.rc != 0 and "normal dosya degil" in run.err, run.text
    assert snapshot(real.target) == before


DENIED = ["deployment/tls.crt", "deployment/server.cer", "deployment/server.pfx",
          "keys/id_rsa", "keys/id_ed25519.old", "keys/id_ecdsa", "keys/sign.minisign",
          "keys/minisign.key", "keys/sign.sec", "keys/store.jks", "keys/store.keystore",
          "secrets", "credentials", "state", "backups", "certs", ".htpasswd",
          "db/prod.sql", "db/prod.sql.gz", "db/backup.dump", "keys/UPPER.PFX"]
ANCHORS = ["public-keys/key.pub", "deployment/ca/root.crt", "deployment/x/ca/root.crt", "deployment/x/key.pub"]


def test_deny_escapes_and_fixed_public_trust_anchors(real: RealWorld):
    real.sha = real.commit({p: "non-secret fixture\n" for p in DENIED + ANCHORS})
    run = real.deploy(True)
    assert run.rc == 0, run.text
    assert all(not (real.target / p).exists() for p in DENIED)
    assert all((real.target / p).is_file() for p in ANCHORS)


def test_lisans_policy_cannot_be_overridden(real: RealWorld):
    real.target.rmdir()
    real.target = real.tmp / "lisans"
    real.target.mkdir()
    paths = ["docker-compose.yml", "VERSION", ".env.fixture", "create_user.py"]
    real.sha = real.commit({p: "fixture\n" for p in paths})
    real.allow.write_text("docker-compose.yml\nVERSION\n.env*\ncreate_user.py\nscripts/**\ndocs/**\n")
    run = real.deploy(True, "lisans")
    assert run.rc == 0, run.text
    assert all(not (real.target / p).exists() for p in paths)


@pytest.mark.parametrize("pattern", ["**", "*", "  **\r\n"])
def test_bare_wildcard_allowlist_is_rejected(real: RealWorld, pattern: str):
    real.allow.write_text(pattern, newline="\n")
    before = snapshot(real.target)
    run = real.deploy(True)
    assert run.rc != 0 and "allowlist deseni" in run.err and run.count("ssh") == 0
    assert snapshot(real.target) == before


def test_autocrlf_true_keeps_exact_git_blob_bytes(real: RealWorld):
    real.sha = real.commit({"scripts/run.sh": "#!/bin/sh\necho LF\n"}, "scripts/run.sh")
    real.git("config", "core.autocrlf", "true")
    run = real.deploy(True)
    assert run.rc == 0, run.text
    for path in [*BASE_FILES, "scripts/run.sh"]:
        blob = subprocess.run(["git", "cat-file", "blob", f"{real.sha}:{path}"], cwd=real.repo,
                              env=real.env, capture_output=True, check=True).stdout
        actual = (real.target / path).read_bytes()
        assert b"\r" not in actual
        assert hashlib.sha256(actual).digest() == hashlib.sha256(blob).digest()


def test_batch_blob_verification_rejects_changed_archive_before_ssh(real: RealWorld):
    payload = real.tmp / "changed-source.tar"
    with tarfile.open(payload, "w") as tf:
        for name, body in BASE_FILES.items():
            data = b"changed archive bytes\n" if name == "scripts/util.py" else body.encode()
            member = tarfile.TarInfo(name)
            member.size = len(data)
            tf.addfile(member, io.BytesIO(data))
    git = real.shell("command -v git").stdout.strip()
    (real.bin / "git").write_text(
        '#!/usr/bin/env bash\nset -euo pipefail\n'
        'if [[ " $* " == *" archive "* ]]; then cat -- "$LOCAL_ARCHIVE"; '
        'else exec "$REAL_GIT" "$@"; fi\n', encoding="utf-8", newline="\n")
    (real.bin / "git").chmod(0o755)
    before = snapshot(real.target)
    run = real.deploy(extra_env={"REAL_GIT": git, "LOCAL_ARCHIVE": payload.as_posix()})
    assert run.rc != 0 and "git blob / arsiv hash uyusmazligi: scripts/util.py" in run.err, run.text
    assert run.count("ssh") == 0 and snapshot(real.target) == before


def test_batch_paths_preserve_spaces_quotes_and_unicode(real: RealWorld):
    paths = ["docs/space name.md", "docs/'quoted'.md", "docs/-dash.md", "docs/ölçüm.md"]
    if os.name != "nt":  # NTFS does not allow a double quote in a filename.
        paths.append('docs/"quoted".md')
    real.sha = real.commit({p: "exact bytes\n" for p in paths})
    run = real.deploy()
    assert run.rc == 0 and "yerel dogrulama tamam" in run.err, run.text


@pytest.mark.parametrize("tool", ["git", "sha256sum", "stat", "chmod"])
def test_batch_tool_failure_stops_before_ssh(real: RealWorld, tool: str):
    actual_git = real.shell("command -v git").stdout.strip()
    body = '#!/usr/bin/env bash\nset -euo pipefail\n'
    if tool == "git":
        body += 'if [[ " $* " != *" hash-object "* ]]; then exec "$REAL_GIT" "$@"; fi\n'
    body += 'echo "injected batch failure" >&2\nexit 99\n'
    (real.bin / tool).write_text(body, encoding="utf-8", newline="\n")
    (real.bin / tool).chmod(0o755)
    before = snapshot(real.target)
    run = real.deploy(extra_env={"REAL_GIT": actual_git})
    assert run.rc != 0 and "injected batch failure" in run.err, run.text
    assert run.count("ssh") == 0 and snapshot(real.target) == before


@pytest.mark.parametrize("existing", [False, True])
def test_350_file_local_validation_budget(real: RealWorld, existing: bool):
    files = {f"license-server/backend/f{i:03}.py": f"print({i})\n" for i in range(348)}
    real.sha = real.commit(files)
    real.target.rmdir()
    real.target = real.tmp / "lisans"
    real.target.mkdir()
    if existing:
        _write_tree(real.target, {**BASE_FILES, **files})
    before = snapshot(real.target)
    start = time.perf_counter()
    run = real.deploy(profile="lisans")
    elapsed = time.perf_counter() - start
    assert run.rc == 0 and snapshot(real.target) == before, run.text
    assert "yerel dogrulama: 350 dosya..." in run.err
    seconds = re.search(r"yerel dogrulama tamam \((\d+) sn\)", run.err)
    assert seconds and int(seconds[1]) < 90, run.err
    assert "uzak plan..." in run.err and "yerel dogrulama" not in run.out
    if existing:
        assert "yeni dosya: 0, ayni: 350" in run.out
    print(f"D10 350 files existing={existing}: local={seconds[1]}s total={elapsed:.3f}s")


@pytest.mark.parametrize("attr", ["export-ignore", "export-subst"])
def test_archive_attributes_fail_before_ssh(real: RealWorld, attr: str):
    real.sha = real.commit({".gitattributes": f"scripts/util.py {attr}\n"})
    run = real.deploy(True)
    assert run.rc != 0 and attr in run.err and run.count("ssh") == 0


def test_identical_content_different_mode_is_backed_up_and_restored(real: RealWorld):
    real.posix_modes()
    _write_tree(real.target, BASE_FILES)
    real.shell('chmod 600 -- "$1"', (real.target / "scripts/util.py").as_posix())
    old_stamp = b"commit=" + b"a" * 40 + b"\ndeployed_at=before\n"
    (real.target / ".deployed-commit").write_bytes(old_stamp)
    run = real.deploy(True)
    assert run.rc == 0, run.text
    assert manifest(real.backup())["files/scripts/util.py"][1] == "600"
    assert real.mode(real.target / "scripts/util.py") == "644"
    run = real.rollback()
    assert run.rc == 0, run.text
    assert real.mode(real.target / "scripts/util.py") == "600"
    assert (real.target / ".deployed-commit").read_bytes() == old_stamp


def test_identical_content_and_mode_not_written_or_transferred(real: RealWorld):
    _write_tree(real.target, BASE_FILES)
    before = {p: (real.target / p).stat().st_mtime_ns for p in BASE_FILES}
    run = real.deploy(True)
    assert run.rc == 0, run.text
    assert all((real.target / p).stat().st_mtime_ns == before[p] for p in BASE_FILES)
    assert not any(p.startswith("files/") for p in manifest(real.backup()))
    assert (real.backup() / "NEW-FILES").read_bytes() == b""
    assert "yeni dosya: 0, ayni: 2" in run.out


def test_rollback_restores_existing_and_deletes_new_files_and_stamp(real: RealWorld):
    _write_tree(real.target, {"scripts/util.py": "old\n"})
    run = real.deploy(True)
    assert run.rc == 0, run.text
    before = snapshot(real.target)
    dry = real.rollback(False)
    assert dry.rc == 0 and snapshot(real.target) == before, dry.text
    run = real.rollback()
    assert run.rc == 0, run.text
    assert (real.target / "scripts/util.py").read_bytes() == b"old\n"
    assert not (real.target / "docs/readme.md").exists()
    assert not (real.target / "docs").exists()
    assert not (real.target / ".deployed-commit").exists()


def test_rollback_restores_exact_previous_stamp(real: RealWorld):
    old = b"commit=" + b"a" * 40 + b"\ndeployed_at=previous-time\nprevious=none\n"
    (real.target / ".deployed-commit").write_bytes(old)
    run = real.deploy(True)
    assert run.rc == 0, run.text
    assert "previous=" + "a" * 40 in (real.target / ".deployed-commit").read_text()
    run = real.rollback()
    assert run.rc == 0, run.text
    assert (real.target / ".deployed-commit").read_bytes() == old


@pytest.mark.parametrize("tamper", ["extra", "missing", "new-changed", "previous-stamp", "missing-stamp", "mode", "new-files"])
def test_rollback_rejects_tamper_before_writing(real: RealWorld, tamper: str):
    _write_tree(real.target, {"scripts/util.py": "old\n"})
    run = real.deploy(True)
    assert run.rc == 0, run.text
    backup = real.backup()
    if tamper == "extra":
        (backup / "files/extra.py").write_bytes(b"extra\n")
    elif tamper == "missing":
        (backup / "files/scripts/util.py").unlink()
    elif tamper == "new-changed":
        (real.target / "docs/readme.md").write_bytes(b"operator edit\n")
    elif tamper == "previous-stamp":
        (backup / "PREVIOUS-STAMP").write_bytes(b"tampered\n")
    elif tamper == "missing-stamp":
        (backup / "PREVIOUS-STAMP").unlink()
    elif tamper == "mode":
        real.posix_modes()
        real.shell('chmod 600 -- "$1"', (backup / "files/scripts/util.py").as_posix())
    else:
        (backup / "NEW-FILES").write_bytes(b"tampered\n")
    before = snapshot(real.target)
    run = real.rollback()
    assert run.rc != 0, run.text
    assert snapshot(real.target) == before


def test_backup_symlink_rejected(real: RealWorld):
    run = real.deploy(True)
    assert run.rc == 0, run.text
    backup = real.backup()
    external = real.tmp / "external-backup"
    backup.rename(external)
    real.symlink(external, backup)
    before = snapshot(real.target)
    run = real.rollback()
    assert run.rc != 0 and "symlink" in run.err, run.text
    assert snapshot(real.target) == before


def test_dry_run_tree_is_byte_for_byte_unchanged(real: RealWorld):
    _write_tree(real.target, {"scripts/util.py": "old\n", "keep/untouched": "keep\n"})
    before = snapshot(real.target)
    run = real.deploy()
    assert run.rc == 0, run.text
    assert snapshot(real.target) == before
    assert not (real.target / ".deploy-lock").exists()


def test_existing_lock_is_never_stolen(real: RealWorld):
    run = real.deploy(True)
    assert run.rc == 0, run.text
    lock = real.target / ".deploy-lock"
    lock.mkdir()
    (lock / "token").write_bytes(b"other-owner\n")
    before = snapshot(real.target)
    for run in (real.deploy(True), real.rollback()):
        assert run.rc != 0 and "uzak kilit mevcut" in run.err, run.text
        assert snapshot(real.target) == before


def test_prune_rejects_commit_from_deleted_origin_branch(real: RealWorld):
    # This deletion affects only this test's local bare origin.
    _git(real.origin, "update-ref", "-d", "refs/heads/main", env=real.env)
    run = real.deploy(True)
    assert run.rc != 0 and "origin dalindan" in run.err and run.count("ssh") == 0, run.text


@pytest.mark.parametrize("failure", ["exit", "term"])
def test_interrupted_apply_leaves_marker_blocks_next_and_allows_rollback(real: RealWorld, failure: str):
    real.fault()
    run = real.deploy(True, extra_env={"FAULT_KIND": failure})
    assert run.rc != 0, run.text
    marker = real.target / ".deploy-incomplete"
    assert marker.is_file() and marker.read_text().strip() == real.backup().name
    assert not (real.target / ".deploy-lock").exists()
    before = snapshot(real.target)
    again = real.deploy(True)
    assert again.rc != 0 and "rollback komutu" in again.err, again.text
    assert snapshot(real.target) == before
    (real.bin / "mv").unlink()
    run = real.rollback()
    assert run.rc == 0, run.text
    assert not marker.exists()


@pytest.mark.parametrize("kind", ["broken", "extra", "duplicate", "symlink", "hardlink", "directory", "traversal", "absolute"])
def test_bad_archive_rejected_without_target_file_writes(real: RealWorld, kind: str):
    payload = real.tmp / "bad.tar"
    if kind == "broken":
        payload.write_bytes(b"invalid tar")
    else:
        with tarfile.open(payload, "w") as tf:
            for name, body in BASE_FILES.items():
                info = tarfile.TarInfo(name)
                info.size = len(body.encode())
                if kind == "symlink" and name == "scripts/util.py":
                    info.type, info.linkname, info.size = tarfile.SYMTYPE, "/etc/passwd", 0
                elif kind == "hardlink" and name == "scripts/util.py":
                    info.type, info.linkname, info.size = tarfile.LNKTYPE, "docs/readme.md", 0
                elif kind == "directory" and name == "scripts/util.py":
                    info.type, info.size = tarfile.DIRTYPE, 0
                tf.addfile(info, io.BytesIO(body.encode()) if info.isfile() else None)
            if kind in {"extra", "duplicate", "traversal", "absolute"}:
                name = {"extra": "extra.py", "duplicate": "scripts/util.py",
                        "traversal": "../outside", "absolute": "/outside"}[kind]
                info = tarfile.TarInfo(name)
                tf.addfile(info, io.BytesIO(b""))
    run = real.deploy(True, extra_env={"REPLACE_TAR": payload.as_posix()})
    assert run.rc != 0, run.text
    assert not (real.target / "scripts/util.py").exists()
    assert not (real.target / "docs/readme.md").exists()
    assert (real.target / ".deploy-incomplete").is_file()
    assert not (real.target / ".deploy-lock").exists()


GLOB_CASES = [
    ("scripts/*", "scripts/a.py", True), ("scripts/*", "scripts/a/b.py", False),
    ("scripts/*", "scripts/.hidden", True), ("scripts/?.py", "scripts/a.py", True),
    ("scripts/?.py", "scripts/ab.py", False), ("**/a.py", "a.py", True),
    ("**/a.py", "x/y/a.py", True), ("**/a.py", "x/ba.py", False),
    ("docs/a+[x](1).md", "docs/a+[x](1).md", True),
    ("docs/a+[x](1).md", "docs/ax1.md", False),
    ("docs/{a}^$|.md", "docs/{a}^$|.md", True),
    ("./scripts/**", "scripts/a.py", False), ("scripts/**", "Scripts/a.py", False),
    ("scripts/**", "scripts/a/b.py", True), ("*", "a.py", True),
    ("*", "x/a.py", False), ("?", "x", True), ("?", "xy", False),
    ("**", "x/y", True),
]


@pytest.mark.parametrize("pattern,path,expected", GLOB_CASES)
def test_glob_conversion_table(pattern: str, path: str, expected: bool):
    source = SCRIPT.read_text(encoding="utf-8")
    funcs = source[source.index("glob_to_regex() {"):source.index("is_denied() {")]
    # MSYS expands wildcard argv from native Python; stdin/env preserve literal patterns.
    checks = '''
matches "$GLOB_PATH" "$GLOB_PATTERN"; expected=$?
matches "$GLOB_PATH" "$GLOB_PATTERN"; cached=$?
compile_patterns "$GLOB_PATTERN"
[[ $GLOB_PATH =~ $PATTERN_REGEX ]]; combined=$?
[[ $cached == "$expected" && $combined == "$expected" ]] || exit 3
exit "$expected"
'''
    proc = subprocess.run([BASH, "-s"], input=funcs + checks,
                          env=dict(os.environ, GLOB_PATH=path, GLOB_PATTERN=pattern),
                          capture_output=True, text=True, timeout=30)
    assert proc.returncode == (0 if expected else 1), proc.stderr
