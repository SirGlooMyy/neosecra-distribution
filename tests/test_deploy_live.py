"""scripts/deploy-live.sh icin sozlesme testleri.

Gercek ag/host KULLANILMAZ: gecici git depolari, yerel bare 'origin' ve PATH'in onune konan
sahte ssh/rsync betikleri (cagri argumanlarini ve stdin'i dosyaya yazar) kullanilir.
Depolar ve sahte araclar modul kapsaminda bir kez kurulur; her betik calistirmasi kendi log
dizinini alir.
"""

from __future__ import annotations

import hashlib
import io
import itertools
import os
import re
import shlex
import shutil
import subprocess
import tarfile
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[1]
SCRIPT = REPO / "scripts" / "deploy-live.sh"
LISANS_ALLOWLIST = REPO / "scripts" / "deploy-live.lisans.allowlist"
TARGET = "deploy@example.invalid:/opt/testprod/distribution"


def _find_bash() -> str | None:
    if os.name == "nt":
        for cand in (
            r"C:\Program Files\Git\bin\bash.exe",
            r"C:\Program Files (x86)\Git\bin\bash.exe",
        ):
            if Path(cand).exists():
                return cand
        return None  # Windows'ta WSL bash'ine dusme
    return shutil.which("bash")


BASH = _find_bash()
pytestmark = [
    pytest.mark.skipif(BASH is None, reason="bash (Windows'ta Git Bash) bulunamadi"),
    pytest.mark.skipif(shutil.which("git") is None, reason="git bulunamadi"),
]

FAKE_SSH = """#!/usr/bin/env bash
set -euo pipefail
d="${FAKE_LOG:?}"
n=0; if [ -f "$d/ssh.count" ]; then n=$(cat "$d/ssh.count"); fi
n=$((n+1)); echo "$n" > "$d/ssh.count"
printf '%s\\0' "$@" > "$d/ssh.$n.args"
printf '%s %s\\n' "$MSYS_NO_PATHCONV" "$MSYS2_ARG_CONV_EXCL" > "$d/ssh.$n.env"
IFS= read -r encoded
printf '%s' "$encoded" | base64 --decode > "$d/ssh.$n.script"
cat > "$d/ssh.$n.stdin"
case "$(cat "$d/ssh.$n.script")" in
  *'held=0'*) if [ -n "${FAKE_LOCKED:-}" ]; then echo 'HATA: uzak kilit mevcut: .deploy-lock' >&2; exit 2; fi ;;
  *'salt-okunur on kontrol tamam'*)
    for ((i=0; i<${FAKE_NFILES:-3}; i++)); do printf '@@TRANSFER\\t%s\\n' "$i"; done ;;
esac
exit 0
"""

FAKE_RSYNC = """#!/usr/bin/env bash
d="${FAKE_LOG:?}"
n=$(cat "$d/rsync.count" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "$d/rsync.count"
printf '%s\\n' "$@" > "$d/rsync.$n.args"
for a in "$@"; do
  case "$a" in --files-from=*) cp "${a#--files-from=}" "$d/rsync.$n.files";; esac
done
src="${@: -2:1}"
cp -r "$src" "$d/rsync.$n.src"
case " $* " in *" --dry-run "*) echo ">f.st...... update-server/publish.sh";; esac
exit 0
"""

FILES = {
    "update-server/publish.sh": "#!/bin/sh\necho publish\n",
    "update-server/www/index.html": "www\n",
    "channels/stable.json": "{}\n",
    "deployment/certs/server.txt": "cert-dir\n",
    "keys/tls.key": "k\n",
    "keys/upper.PEM": "p\n",
    "pki/store.p12": "p\n",
    "app/.env.production": "X=1\n",
    "app/secrets/token.txt": "s\n",
    "app/credentials/c.txt": "c\n",
    "app/state/s.db": "s\n",
    "backups/old.tar": "b\n",
    "sub/backups/y.tar": "b\n",
    "docs/guide.md": "committed guide\n",
    "README.md": "readme\n",
}
EXPECTED = {"update-server/publish.sh", "docs/guide.md", "README.md"}
ALLOW_EVERYTHING = "\n".join(
    [
        "# hard-deny yollari bilerek allowlist'e de yazildi",
        "**/*",
        "channels/**",
        "update-server/www/**",
        "**/*.key",
        "**/.env*",
        "",
    ]
)

LICENSE_FILES = {
    "docker-compose.yml": "services: {}  # gelistirme\n",
    "license-server/backend/app.py": "print('app')\n",
    "license-server/backend/create_user.py": "print('x')\n",
    "license-server/backend/node_modules/pkg/index.js": "x\n",
    "license-server/backend/.env.local": "A=1\n",
    "license-server/frontend/index.html": "<html></html>\n",
    "license-server/deployment/nginx.conf": "server {}\n",
    "license-server/other/x.txt": "izin listesinde yok\n",
    "scripts/util.sh": "#!/bin/sh\n",
    "docs/a.md": "a\n",
    "README.md": "lisans readme\n",
    "ARCHITECTURE.md": "arch\n",
}
LICENSE_EXPECTED = {
    "license-server/backend/app.py",
    "license-server/frontend/index.html",
    "license-server/deployment/nginx.conf",
    "scripts/util.sh",
    "docs/a.md",
    "README.md",
    "ARCHITECTURE.md",
}


class Run:
    """Tek betik calistirmasi + o calistirmanin sahte-arac kayitlari."""

    def __init__(self, proc: subprocess.CompletedProcess, log: Path):
        self.proc = proc
        self.log = log

    @property
    def rc(self) -> int:
        return self.proc.returncode

    @property
    def out(self) -> str:
        return self.proc.stdout

    @property
    def err(self) -> str:
        return self.proc.stderr

    @property
    def text(self) -> str:
        return self.proc.stdout + self.proc.stderr

    def count(self, tool: str) -> int:
        f = self.log / f"{tool}.count"
        return int(f.read_text().strip()) if f.exists() else 0

    def args(self, tool: str, n: int) -> list[str]:
        raw = (self.log / f"{tool}.{n}.args").read_text(encoding="utf-8")
        return raw.rstrip("\0").split("\0") if "\0" in raw else raw.splitlines()

    def all_args(self, tool: str) -> list[list[str]]:
        return [self.args(tool, i) for i in range(1, self.count(tool) + 1)]

    def stdin_bytes(self, n: int) -> bytes:
        f = self.log / f"ssh.{n}.stdin"
        return f.read_bytes() if f.exists() else b""

    def ssh_texts(self) -> list[str]:
        """Her ssh cagrisi icin: argumanlar + stdin (metin olarak)."""
        return [
            "\n".join(self.args("ssh", n)) + "\n" + self.stdin_bytes(n).decode("utf-8", "replace")
            for n in range(1, self.count("ssh") + 1)
        ]

    def ssh_index(self, *needles: str) -> int:
        for i, t in enumerate(self.ssh_texts()):
            if all(nd in t for nd in needles):
                return i
        raise AssertionError(f"ssh cagrisi bulunamadi: {needles}")


def _git(cwd: Path, *args: str, env: dict) -> str:
    r = subprocess.run(
        ["git", "-c", "core.autocrlf=false", *args],
        cwd=cwd,
        env=env,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        stdin=subprocess.DEVNULL,
        timeout=60,
    )
    assert r.returncode == 0, f"git {args} basarisiz: {r.stderr}"
    return r.stdout.strip()


def _write_tree(root: Path, files: dict[str, str]) -> None:
    for rel, content in files.items():
        p = root / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(content, encoding="utf-8", newline="\n")


class World:
    def __init__(self, tmp: Path):
        self.tmp = tmp
        self.bin = tmp / "bin"
        self.bin.mkdir()
        for name, body in (("ssh", FAKE_SSH), ("rsync", FAKE_RSYNC)):
            (self.bin / name).write_text(body, encoding="utf-8", newline="\n")
            (self.bin / name).chmod(0o755)
        home = tmp / "home"
        home.mkdir()
        self.env = dict(os.environ)
        self.env.update(
            FAKE_BIN=self.bin.as_posix(),
            HOME=str(home),
            GIT_CONFIG_NOSYSTEM="1",
            GIT_CONFIG_GLOBAL=os.devnull,
            GIT_AUTHOR_NAME="t",
            GIT_AUTHOR_EMAIL="t@example.invalid",
            GIT_COMMITTER_NAME="t",
            GIT_COMMITTER_EMAIL="t@example.invalid",
            GIT_TERMINAL_PROMPT="0",
        )
        self._seq = itertools.count(1)
        # --- dagitim deposu + origin
        self.repo = tmp / "repo"
        self.repo.mkdir()
        self.origin = tmp / "origin.git"
        subprocess.run(
            ["git", "init", "-q", "--bare", "-b", "main", str(self.origin)],
            check=True,
            env=self.env,
            stdin=subprocess.DEVNULL,
        )
        _git(self.repo, "init", "-q", "-b", "main", env=self.env)
        _write_tree(self.repo, FILES)
        _git(self.repo, "add", "-A", env=self.env)
        _git(self.repo, "update-index", "--chmod=+x", "update-server/publish.sh", env=self.env)
        _git(self.repo, "commit", "-q", "-m", "ilk", env=self.env)
        _git(self.repo, "remote", "add", "origin", self.origin.as_posix(), env=self.env)
        _git(self.repo, "push", "-q", "origin", "main", env=self.env)
        self.pushed_sha = self.rev("HEAD")
        self.allow = tmp / "allow.txt"
        self.allow.write_text(ALLOW_EVERYTHING, encoding="utf-8", newline="\n")
        # --- lisans benzeri ikinci depo
        self.lic = tmp / "lic"
        self.lic.mkdir()
        _git(self.lic, "init", "-q", "-b", "main", env=self.env)
        _write_tree(self.lic, LICENSE_FILES)
        _git(self.lic, "add", "-A", env=self.env)
        _git(self.lic, "commit", "-q", "-m", "lisans", env=self.env)
        self.lic_sha = _git(self.lic, "rev-parse", "HEAD", env=self.env)
        self._cache: dict[str, Run] = {}
        self._local_sha: str | None = None

    def rev(self, ref: str) -> str:
        return _git(self.repo, "rev-parse", ref, env=self.env)

    def git(self, *args: str) -> str:
        return _git(self.repo, *args, env=self.env)

    def local_only_commit(self) -> str:
        if self._local_sha is None:
            (self.repo / "docs" / "local.md").write_text("local\n", encoding="utf-8", newline="\n")
            self.git("add", "docs/local.md")
            self.git("commit", "-q", "-m", "yalniz yerel")
            self._local_sha = self.rev("HEAD")
        return self._local_sha

    def run(self, *args: str, repo: Path | None = None, extra_env: dict | None = None) -> Run:
        log = self.tmp / f"log{next(self._seq)}"
        log.mkdir()
        env = dict(self.env, FAKE_LOG=log.as_posix(), **(extra_env or {}))
        proc = subprocess.run(
            # msys, baslangicta PATH'in basina /usr/bin ekleyebilir ve env degiskenlerini
            # Windows bicimine cevirir; sahte ssh/rsync'in gercek olanin ONUNDE kalmasi icin
            # PATH bash icinde, cygpath ile ayarlanir.
            [
                BASH,
                "-c",
                'fb="$FAKE_BIN"; if command -v cygpath >/dev/null 2>&1; then fb=$(cygpath -u "$fb"); fi; '
                'PATH="$fb:$PATH"; exec bash "$0" "$@"',
                SCRIPT.as_posix(),
                "--repo",
                (repo or self.repo).as_posix(),
                *args,
            ],
            cwd=self.tmp,  # bilerek depo DISI: --repo'nun kullanildigini sinar
            env=env,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            stdin=subprocess.DEVNULL,
            timeout=240,
        )
        return Run(proc, log)

    def deploy(self, ref: str, *extra: str, target: str = TARGET, **kw) -> Run:
        return self.run("--profile", "distribution", "--ref", ref, "--target", target, "--allowlist", self.allow.as_posix(), *extra, **kw)

    def cached(self, key: str, fn) -> Run:
        if key not in self._cache:
            self._cache[key] = fn()
        return self._cache[key]


@pytest.fixture(scope="module")
def world(tmp_path_factory) -> World:
    return World(tmp_path_factory.mktemp("deploylive"))


@pytest.fixture(scope="module")
def dry_run(world: World) -> Run:
    """Kirli agac (duzenlenmis + izlenmeyen dosya) ile varsayilan (dry-run) calistirma."""
    guide = world.repo / "docs" / "guide.md"
    untracked = world.repo / "docs" / "untracked.md"
    guide.write_text("DIRTY EDIT\n", encoding="utf-8", newline="\n")
    untracked.write_text("untracked\n", encoding="utf-8", newline="\n")
    try:
        return world.deploy(world.pushed_sha)
    finally:
        guide.write_text(FILES["docs/guide.md"], encoding="utf-8", newline="\n")
        untracked.unlink()


def remote_script(run: Run, n: int = 1) -> str:
    argv = shlex.split(run.args("ssh", n)[-1])
    assert argv[:4] == ["bash", "-euo", "pipefail", "-c"]
    assert "base64 --decode" in argv[4] and 'eval "$script"' in argv[4]
    assert len(run.args("ssh", n)[-1]) < 1024
    return (run.log / f"ssh.{n}.script").read_text(encoding="utf-8")


def selected(run: Run) -> set[str]:
    line = next(line for line in remote_script(run).splitlines() if line.startswith("declare -a FILES="))
    return set(re.findall(r'\[\d+\]="([^"]+)"', line))


def test_bash_syntax_ok():
    proc = subprocess.run([BASH, "-n", SCRIPT.as_posix()], capture_output=True, text=True, timeout=30)
    assert proc.returncode == 0, proc.stderr


def test_default_dry_run_is_read_only(dry_run: Run):
    assert dry_run.rc == 0, dry_run.text
    assert dry_run.count("ssh") == 1 and dry_run.count("rsync") == 0
    script = remote_script(dry_run)
    assert "DRY-RUN" in dry_run.out
    for mutation in ("acquire_lock", "mv -T", "cat >", "write_marker", "cp -p", "mkdir --"):
        assert mutation not in script


def test_hard_deny_precedes_allowlist_and_dirty_tree(dry_run: Run):
    assert selected(dry_run) == EXPECTED
    assert "kirli" in dry_run.out
    assert "untracked.md" not in selected(dry_run)


def test_apply_single_mutation_session_and_archive(world: World, tmp_path: Path):
    ident = tmp_path / "identity with spaces"
    ident.write_bytes(b"")
    run = world.deploy(world.pushed_sha, "--apply", "--identity", ident.as_posix())
    assert run.rc == 0, run.text
    assert run.count("ssh") == 2 and run.count("rsync") == 0
    script = remote_script(run, 2)
    for word in ("trap release_lock EXIT", "held=0", "MANIFEST.sha256", "NEW-FILES", "PREVIOUS-STAMP", "mv -T --", "tar -tf", "tar -tvf", "write_marker", "finish_marker"):
        assert word in script
    assert script.index("acquire_lock\n") < script.index('make_dir "$P/files"') < script.index('cat > "$S/.in.tar"') < script.index('mv -T -- "$S/files/$p"') < script.index("printf 'commit=")
    with tarfile.open(fileobj=io.BytesIO(run.stdin_bytes(2))) as tf:
        assert {m.name for m in tf.getmembers()} == EXPECTED
        assert tf.extractfile("docs/guide.md").read() == FILES["docs/guide.md"].encode()
        # Remote modes come from Git, not the archive mode reported by NTFS.
        assert 'declare -a MODES=([0]="644" [1]="644" [2]="755")' in script
    for n, argv in enumerate(run.all_args("ssh"), 1):
        assert argv[argv.index("--") + 1] == "deploy@example.invalid"
        assert "StrictHostKeyChecking=yes" in argv and "BatchMode=yes" in argv
        assert (run.log / f"ssh.{n}.env").read_text().strip() == "1 *"
        assert Path(argv[argv.index("-i") + 1]).name == ident.name


@pytest.mark.parametrize("target", [
    "deploy@example.invalid:opt/testprod", "deploy@example.invalid:/", "deploy@example.invalid:/opt",
    "deploy@example.invalid:/opt/../distribution", "deploy@example.invalid:/opt/a b/distribution",
    "deploy@example.invalid:/opt/$(id)/distribution", "/opt/testprod/distribution",
    "-Fsshcfg@example.invalid:/opt/distribution", "Root@example.invalid:/opt/distribution",
    "deploy@example.invalid:/opt/lisans",
])
def test_bad_targets_rejected_without_remote_calls(world: World, target: str):
    run = world.deploy(world.pushed_sha, target=target)
    assert run.rc != 0 and run.count("ssh") == 0


def test_profile_required_and_rsync_fail_closed(world: World):
    run = world.run("--ref", world.pushed_sha, "--target", TARGET)
    assert run.rc != 0 and "--profile" in run.err and run.count("ssh") == 0
    run = world.deploy(world.pushed_sha, "--transport", "rsync")
    assert run.rc != 0 and "tar" in run.err and run.count("ssh") == 0


def test_apply_rejects_local_and_tag_only_commits(world: World):
    sha = world.local_only_commit()
    run = world.deploy(sha, "--apply")
    assert run.rc != 0 and "origin" in run.err and run.count("ssh") == 0
    run = world.deploy(sha)
    assert run.rc == 0 and "origin" in run.err
    world.git("tag", "sadece-etiket", sha)
    world.git("push", "-q", "origin", "sadece-etiket")
    run = world.deploy("sadece-etiket", "--apply")
    assert run.rc != 0 and "origin" in run.err and run.count("ssh") == 0


def test_ancestor_commit_is_accepted(world: World):
    world.local_only_commit()
    world.git("push", "-q", "origin", "main")
    run = world.deploy(world.pushed_sha, "--apply")
    assert run.rc == 0, run.text


def test_lock_failure_has_no_client_side_unlock(world: World):
    run = world.deploy(world.pushed_sha, "--apply", extra_env={"FAKE_LOCKED": "1"})
    assert run.rc != 0 and ".deploy-lock" in run.err
    assert run.count("ssh") == 2  # readonly plan, then one mutation session; no unlock SSH


def test_repo_option_and_license_allowlist(world: World):
    run = world.run("--profile", "lisans", "--ref", "HEAD", "--target",
                    "lisans@example.invalid:/opt/neosecra/lisans", "--allowlist",
                    LISANS_ALLOWLIST.as_posix(), repo=world.lic)
    assert run.rc == 0, run.text
    assert selected(run) == LICENSE_EXPECTED
    assert world.lic_sha in run.out


@pytest.mark.parametrize("profile", ["distribution", "lisans"])
def test_profile_selects_correct_default_allowlist(world: World, profile: str):
    repo = world.lic if profile == "lisans" else world.repo
    sha = world.lic_sha if profile == "lisans" else world.pushed_sha
    run = world.run("--profile", profile, "--ref", sha, "--target",
                    f"deploy@example.invalid:/opt/neosecra/{profile}", repo=repo)
    assert run.rc == 0, run.text
    assert selected(run) == (LICENSE_EXPECTED if profile == "lisans" else EXPECTED)


def test_explicit_missing_allowlist_does_not_fall_back(world: World):
    missing = SCRIPT.parent / "deploy-live.distribution.allowlist"
    assert not missing.exists()
    run = world.deploy(world.pushed_sha, "--allowlist", missing.as_posix())
    assert run.rc != 0 and "allowlist bulunamadi" in run.err and run.count("ssh") == 0


def test_rollback_validation_and_default_dry_run(world: World):
    name = "20260930T101500Z-abcdef123456-0123456789abcdef"
    run = world.run("--profile", "distribution", "--rollback", name, "--target", TARGET)
    assert run.rc == 0, run.text
    script = remote_script(run)
    assert "validate_backup" in script and "NEW-FILES" in script
    assert "mv -T" not in script and "acquire_lock" not in script
    bad = world.run("--profile", "distribution", "--rollback", "../../etc", "--target", TARGET, "--apply")
    assert bad.rc != 0 and bad.count("ssh") == 0
    run = world.run("--profile", "distribution", "--rollback", name, "--target", TARGET, "--apply")
    assert run.rc == 0 and run.count("ssh") == 1
    script = remote_script(run)
    assert 'mv -T -- "$S/$p"' in script and 'rm -- "$T/$p"' in script
