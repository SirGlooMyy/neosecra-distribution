"""Offline bootstrap boundary tests; no privileged install or real network."""

from __future__ import annotations

import hashlib
import gzip
import io
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
from pathlib import Path

import pytest


ROOT = Path(__file__).resolve().parents[1]
BASH = Path(r"C:\Program Files\Git\bin\bash.exe") if os.name == "nt" else Path(shutil.which("bash") or "/bin/bash")
VERSION = "1.3.44"
URL = "https://update.neosecra.com/releases/1.3.44/distribution.tar.gz"
KEY = (ROOT / "public-keys/update-neosecra-com.pub").read_text(encoding="utf-8").strip()


def bash_path(path: Path) -> str:
    text = path.resolve().as_posix()
    return "/" + text[0].lower() + text[2:] if os.name == "nt" else text


def archive_bytes(version: str = VERSION, member: str = "", kind: bytes = tarfile.REGTYPE) -> bytes:
    stream = io.BytesIO()
    root = f"neosecra-distribution-{VERSION}"
    with tarfile.open(fileobj=stream, mode="w:gz") as archive:
        # Place a safe member first so a late unsafe member tests preflight.
        for name, data in ((f"{root}/deployment/VERSION", version.encode()),
                           (f"{root}/deployment/safe.txt", b"verified payload")):
            info = tarfile.TarInfo(name)
            info.size = len(data)
            archive.addfile(info, io.BytesIO(data))
        if member:
            info = tarfile.TarInfo(member.replace("ROOT", root))
            info.type = kind
            if kind in (tarfile.SYMTYPE, tarfile.LNKTYPE):
                info.linkname = "../../escape"
            archive.addfile(info, io.BytesIO(b""))
    return stream.getvalue()


SHELL_MOCK = r'''
set -euo pipefail
{ printf '%s\t' "$tool" "$@"; printf '\n'; } >> "$P4_LOG"
if [[ "$tool" == curl ]]; then
    fail=0; tls=0; proto=0; redirect=0; output=""; url=""
    while [[ "$#" -gt 0 ]]; do
        case "$1" in
            --fail) fail=1 ;;
            --tlsv1.2) tls=1 ;;
            --proto) shift; [[ "$1" == =https ]] || exit 90; proto=1 ;;
            --proto-redir) shift; [[ "$1" == =https ]] || exit 90; redirect=1 ;;
            -o) shift; output="$1" ;;
            -H) shift ;;
            --silent|--show-error|--location) ;;
            -k) exit 90 ;;
            https://*) url="$1" ;;
            *) exit 90 ;;
        esac
        shift
    done
    [[ "$fail" == 1 && "$tls" == 1 && "$proto" == 1 && "$redirect" == 1 && -n "$output" ]] || exit 90
    case "$url" in
        */channels/*.minisig) name=channel.json.minisig ;;
        */channels/*) name=channel.json ;;
        */releases/*.sha256) name=dist.tar.gz.sha256 ;;
        */releases/*.minisig) name=dist.tar.gz.minisig ;;
        */releases/*) name=dist.tar.gz ;;
        *) exit 90 ;;
    esac
    [[ -f "$P4_SOURCE/$name" ]] || exit 22
    cp -- "$P4_SOURCE/$name" "$output"
elif [[ "$tool" == minisign ]]; then
    message=""; signature=""; key=""
    while [[ "$#" -gt 0 ]]; do
        case "$1" in
            -Vm) shift; message="$1" ;;
            -x) shift; signature="$1" ;;
            -p) shift; key="$1" ;;
            -q) ;;
            *) exit 90 ;;
        esac
        shift
    done
    public_key="$(cat "$key")"
    [[ "$public_key" == "$P4_KEY_1" || "$public_key" == "$P4_KEY_2" ]] || exit 1
    expected="mock-signature:$(sha256sum "$message" | cut -d' ' -f1)"
    [[ "$(cat "$signature")" == "$expected" ]]
elif [[ "$tool" == docker ]]; then
    exit 0
else
    exit 99
fi
'''


@pytest.fixture
def bootstrap(tmp_path: Path):
    source = tmp_path / "source"
    tools = tmp_path / "tools"
    source.mkdir()
    tools.mkdir()
    for name in ("curl", "minisign", "docker", "apt-get", "systemctl"):
        path = tools / name
        path.write_text('#!/usr/bin/env bash\ntool=' + name + "\n" + SHELL_MOCK, encoding="utf-8", newline="\n")
        path.chmod(0o755)
    python = tools / "python3"
    python.write_text('#!/usr/bin/env bash\nexec "$P4_PYTHON" "$@"\n', encoding="utf-8", newline="\n")
    python.chmod(0o755)
    log = tmp_path / "calls.jsonl"
    base = tmp_path / "install"
    temp = tmp_path / "private-temp"
    temp.mkdir()
    keys = [KEY, (ROOT / "public-keys/update-neosecra-com-20260904.pub").read_text(encoding="utf-8").strip()]

    def run(*, version=VERSION, installed="", archive=None, channel_signature="valid",
            archive_signature="valid", hash_mismatch=False, sidecar_mismatch=False,
            identity=None, overrides=None):
        payload = archive if archive is not None else archive_bytes()
        (source / "dist.tar.gz").write_bytes(payload)
        digest = hashlib.sha256(payload).hexdigest()
        channel = {
            "channel": "assessment-stable", "product": "assessment", "product_code": "assessment",
            "current_version": version, "releases": [{"version": version, "archive": {
                "url": URL, "sha256": "0" * 64 if hash_mismatch else digest,
            }}],
        }
        channel.update(identity or {})
        (source / "channel.json").write_text(json.dumps(channel), encoding="utf-8")
        for name, status in (("channel.json", channel_signature), ("dist.tar.gz", archive_signature)):
            signature = source / (name + ".minisig")
            if status == "missing":
                signature.unlink(missing_ok=True)
            else:
                value = "mock-signature:" + hashlib.sha256((source / name).read_bytes()).hexdigest()
                signature.write_text(value if status == "valid" else "invalid", encoding="ascii")
        (source / "dist.tar.gz.sha256").write_text(("0" * 64 if sidecar_mismatch else digest) + "  distribution.tar.gz\n", encoding="ascii")
        if installed:
            (base / "state").mkdir(parents=True, exist_ok=True)
            (base / "state/installed-version").write_text(installed, encoding="utf-8")
        script = (ROOT / "bootstrap.sh").read_text(encoding="utf-8")
        # Git Bash has a non-root synthetic EUID. Only bypass the host privilege
        # assertion, preserving all verification and extraction code verbatim.
        if os.name == "nt":
            script = re.sub(r'^\[\[ "?\$EUID"? -eq 0 \]\] \|\| err "Root required"$', ":", script, flags=re.M)
        env = {k: v for k, v in os.environ.items() if not k.startswith("NEOSECRA_") and k != "LOCAL_MANIFEST"}
        env.update({
            "P4_PYTHON": bash_path(Path(sys.executable)),
            "P4_TOOLS": bash_path(tools), "P4_SOURCE": bash_path(source), "P4_LOG": bash_path(log),
            "P4_KEY_1": keys[0], "P4_KEY_2": keys[1], "NEOSECRA_INSTALL_ROOT": bash_path(base),
            "TMPDIR": bash_path(temp),
        })
        env.update(overrides or {})
        command = '''export PATH="$P4_TOOLS:/usr/bin:/bin"
rsync() {
  test "$(cat deployment/VERSION)" = "1.3.44" || exit 78
  test "$(cat deployment/safe.txt)" = "verified payload" || exit 78
  printf 'P4_EXTRACTION_REACHED\n'
  exit 77
}'''
        result = subprocess.run([str(BASH), "-s"], input=(command + "\n" + script).encode("utf-8"), env=env,
                                cwd=ROOT, capture_output=True, timeout=120)
        result.stdout = result.stdout.decode("utf-8", errors="replace")
        result.stderr = result.stderr.decode("utf-8", errors="replace")
        calls = [line.rstrip("\t").split("\t") for line in log.read_text(encoding="utf-8").splitlines()] if log.exists() else []
        assert not list(temp.iterdir()), "Private staging was not cleaned on exit"
        return result, calls

    return run


def assert_before_archive(result, calls):
    assert result.returncode != 0, result.stdout
    assert not any(tool == "curl" and "/releases/" in args[-1] for tool, *args in calls)
    assert "P4_EXTRACTION_REACHED" not in result.stdout


@pytest.mark.parametrize("signature", ["missing", "invalid"])
def test_channel_signature_fails_before_archive_download(bootstrap, signature):
    result, calls = bootstrap(channel_signature=signature)
    assert_before_archive(result, calls)
    assert any(call[0] == "curl" for call in calls), result.stderr


@pytest.mark.parametrize("installed", ["1.3.45", "2.0.0", "1.3.44"])
def test_valid_signed_channel_cannot_downgrade(bootstrap, installed):
    target = "1.3.43" if installed == VERSION else VERSION
    result, calls = bootstrap(installed=installed, version=target)
    assert_before_archive(result, calls)
    assert "Anti-rollback" in result.stderr


@pytest.mark.parametrize("version", ["../x", "1.0;rm", "v1.3.44", "1.3.44\n", "1.2"])
def test_invalid_version_fails_before_archive_download(bootstrap, version):
    result, calls = bootstrap(version=version)
    assert_before_archive(result, calls)
    assert "Invalid version" in result.stderr


@pytest.mark.parametrize("identity", [{"channel": "soc-stable"}, {"product": "hotspot"}, {"product_code": "soc"}])
def test_signed_channel_identity_is_bound(bootstrap, identity):
    result, calls = bootstrap(identity=identity)
    assert_before_archive(result, calls)
    assert "identity mismatch" in result.stderr


@pytest.mark.parametrize("member,kind", [
    ("ROOT/../escape", tarfile.REGTYPE), ("/absolute", tarfile.REGTYPE),
    ("ROOT/link", tarfile.SYMTYPE), ("ROOT/hard", tarfile.LNKTYPE),
    ("ROOT/device", tarfile.CHRTYPE), ("ROOT/pipe", tarfile.FIFOTYPE),
    ("second-root/file", tarfile.REGTYPE), ("ROOT/deployment/VERSION", tarfile.REGTYPE),
])
def test_unsafe_archive_rejected_before_any_extraction(bootstrap, member, kind):
    result, _ = bootstrap(archive=archive_bytes(member=member, kind=kind))
    assert result.returncode != 0
    assert "SECURITY VIOLATION" in result.stderr
    assert "Archive preflight passed" not in result.stdout
    assert "P4_EXTRACTION_REACHED" not in result.stdout


@pytest.mark.parametrize("argument", ["hash_mismatch", "sidecar_mismatch"])
def test_hash_mismatch_rejected(bootstrap, argument):
    result, _ = bootstrap(**{argument: True})
    assert result.returncode != 0
    assert "SHA-256 mismatch" in result.stderr
    assert "Archive preflight passed" not in result.stdout


def test_bad_archive_signature_rejected(bootstrap):
    result, _ = bootstrap(archive_signature="invalid")
    assert result.returncode != 0
    assert "Archive Minisign signature" in result.stderr
    assert "Archive preflight passed" not in result.stdout


def test_internal_version_must_match_signed_channel(bootstrap):
    result, _ = bootstrap(archive=archive_bytes(version="1.3.43"))
    assert result.returncode != 0
    assert "VERSION does not match" in result.stderr
    assert "Archive preflight passed" not in result.stdout


def test_happy_path_extracts_only_verified_payload(bootstrap):
    result, calls = bootstrap()
    assert result.returncode == 77, result.stdout + result.stderr
    assert "P4_EXTRACTION_REACHED" in result.stdout
    curl_calls = [args[-1] for tool, *args in calls if tool == "curl"]
    assert curl_calls == ["https://update.neosecra.com/channels/assessment-stable.json",
                          "https://update.neosecra.com/channels/assessment-stable.json.minisig",
                          URL, URL + ".sha256", URL + ".minisig"]
    first_archive = next(i for i, call in enumerate(calls) if call[0] == "curl" and "/releases/" in call[-1])
    assert any(call[0] == "minisign" for call in calls[:first_archive])


@pytest.mark.parametrize("overrides", [{"NEOSECRA_VERSION": "1.0.0"},
                                     {"NEOSECRA_DISTRIBUTION_ARCHIVE_URL": "https://other.example/a.tar.gz"}])
def test_overrides_cannot_bypass_signed_metadata(bootstrap, overrides):
    result, calls = bootstrap(overrides=overrides)
    assert_before_archive(result, calls)
    assert "override must match" in result.stderr


def site_block(text: str, host: str) -> str:
    match = re.search(r"^" + re.escape(host) + r"[^\n]*\{\n(.*?)^\}", text, re.M | re.S)
    assert match, host
    return match[1]


def test_existing_https_vhosts_have_hsts_and_registry_is_pull_only():
    for name in ("Caddyfile", "Caddyfile.public"):
        text = (ROOT / "update-server" / name).read_text(encoding="utf-8")
        hosts = ["license.neosecra.com", "update.neosecra.com"]
        if name == "Caddyfile":
            hosts.append("registry.neosecra.com")
        for host in hosts:
            block = site_block(text, host)
            assert 'Strict-Transport-Security "max-age=31536000"' in block
            assert "includeSubDomains" not in block and "preload" not in block
    registry = site_block((ROOT / "update-server/Caddyfile").read_text(encoding="utf-8"), "registry.neosecra.com")
    assert "@registry_write not method GET HEAD" in registry
    assert 'respond @registry_write "registry is read-only over the public endpoint" 403' in registry


def test_no_downloaded_shell_installer_and_documentation_pins_real_key():
    for name in ("bootstrap.sh", "update-server/bootstrap-hotspot.sh", "docs/CUSTOMER-INSTALL.md"):
        text = (ROOT / name).read_text(encoding="utf-8")
        assert not re.search(r"curl\b[^\n]*(?:\n\s*)?\|\s*(?:sudo\s+)?(?:sh|bash)\b", text)
        assert "get.docker.com" not in text
        assert KEY in text
    document = (ROOT / "docs/CUSTOMER-INSTALL.md").read_text(encoding="utf-8")
    assert "C55D6825451AD013" in document
    assert "minisign -V -m bootstrap.sh" in document
    assert document.index("minisign -V -m bootstrap.sh") < document.index("sudo NEOSECRA_TLS_MODE=public bash ./bootstrap.sh")


def embedded_block(script: str, label: str) -> str:
    return script.split("<<'" + label + "'\n", 1)[1].split("\n" + label + "\n", 1)[0]


def test_hotspot_reinstall_antirollback_and_preflight(tmp_path):
    script = (ROOT / "update-server/bootstrap-hotspot.sh").read_text(encoding="utf-8")
    channel_code = script.split("requested_version, install_root = sys.argv[1:]", 1)
    assert len(channel_code) == 2
    # Execute the actual channel parser independently of disk provisioning.
    code = script.split('"$INSTALL_ROOT" <<\'PY\'\n', 1)[1].split("\nPY\n", 1)[0]
    base = tmp_path / "hotspot"
    (base / "state").mkdir(parents=True)
    (base / "state/installed-version").write_text("0.3.114")
    channel = tmp_path / "hotspot.json"
    channel.write_text(json.dumps({"channel": "hotspot-stable", "product": "hotspot", "edition": "standard",
                                   "status": "available", "current_version": "0.3.113",
                                   "releases": [{"version": "0.3.113"}]}))
    result = subprocess.run([sys.executable, "-c", code, str(channel), str(tmp_path / "release.json"),
                             "hotspot-stable", "hotspot", "standard", "", str(base)], capture_output=True, text=True)
    assert result.returncode != 0 and "Anti-rollback" in result.stderr
    assert "members.append(member)" in script
    assert script.index('Hotspot archive VERSION does not match signed channel') < script.index('for member in members:')


def extractor_code(product):
    if product == "assessment":
        return embedded_block((ROOT / "bootstrap.sh").read_text(encoding="utf-8"), "EXTRACT_PY")
    script = (ROOT / "update-server/bootstrap-hotspot.sh").read_text(encoding="utf-8")
    return script.split('"$EXTRACT_ROOT" "$VERSION" <<\'PY\'\n', 1)[1].split("\nPY\n", 1)[0]


def hotspot_archive(*, bad_member=False, declared_version=VERSION):
    stream = io.BytesIO()
    root = f"neosecra-hotspot-{VERSION}"
    with tarfile.open(fileobj=stream, mode="w:gz") as archive:
        for name, data in (("VERSION", declared_version.encode()), ("docker-compose.yml", b"services: {}"),
                           ("backend/.env.example", b"# public template"),
                           ("deployment/v1/agent/install-hotspot-agent.sh", b"#!/bin/bash\n")):
            member = tarfile.TarInfo(f"{root}/{name}")
            member.size = len(data)
            archive.addfile(member, io.BytesIO(data))
        if bad_member:
            link = tarfile.TarInfo(f"{root}/link")
            link.type = tarfile.SYMTYPE
            link.linkname = "../../escape"
            archive.addfile(link)
    return stream.getvalue()


@pytest.mark.parametrize("bad_member,version", [(True, VERSION), (False, "1.3.43"), (False, VERSION)])
def test_hotspot_extractor_preflight_and_legitimate_payload(tmp_path, bad_member, version):
    archive = tmp_path / "hotspot.tar.gz"
    archive.write_bytes(hotspot_archive(bad_member=bad_member, declared_version=version))
    destination = tmp_path / "extract"
    result = subprocess.run([sys.executable, "-c", extractor_code("hotspot"), str(archive), str(destination), VERSION],
                            capture_output=True, text=True)
    if bad_member or version != VERSION:
        assert result.returncode != 0
        assert not destination.exists(), "Unsafe archive wrote files before completing preflight"
    else:
        assert result.returncode == 0, result.stderr
        assert (destination / f"neosecra-hotspot-{VERSION}/VERSION").read_text() == VERSION


@pytest.mark.parametrize("product", ["assessment", "hotspot"])
@pytest.mark.parametrize("limit", ["count", "member_bytes", "total_bytes"])
def test_archive_resource_bounds_before_writes(tmp_path, product, limit):
    archive = tmp_path / "bounded.tar.gz"
    if limit == "count":
        stream = io.BytesIO()
        with tarfile.open(fileobj=stream, mode="w:gz") as bundle:
            for index in range(10001):
                bundle.addfile(tarfile.TarInfo(f"root/file-{index}"))
        archive.write_bytes(stream.getvalue())
    elif limit == "member_bytes":
        # The declared member size is enough to reject it; no multi-GB fixture.
        member = tarfile.TarInfo("root/huge")
        member.size = 3 * 1024**3
        archive.write_bytes(gzip.compress(member.tobuf() + b"\0" * 1024))
    else:
        # Three sparse 2-GiB members consume few fixture bytes but would expand
        # to 6 GiB. Each member passes its own limit, so this tests the sum.
        stream = io.BytesIO()
        with tarfile.open(fileobj=stream, mode="w:gz") as bundle:
            for index in range(3):
                member = tarfile.TarInfo(f"root/sparse-{index}")
                member.pax_headers = {"GNU.sparse.map": "0,0", "GNU.sparse.size": str(2 * 1024**3)}
                bundle.addfile(member)
        archive.write_bytes(stream.getvalue())
    destination = tmp_path / "extract"
    result = subprocess.run([sys.executable, "-c", extractor_code(product), str(archive), str(destination), VERSION],
                            capture_output=True, text=True)
    assert result.returncode != 0
    if limit == "count":
        assert "too many" in result.stderr
    elif limit == "member_bytes":
        assert "large" in result.stderr or "size limit" in result.stderr
    else:
        assert "total size" in result.stderr or "bounded extraction limit" in result.stderr
    assert not destination.exists()


@pytest.mark.parametrize("mismatch", [False, True])
def test_origin_static_reads_actual_tls_pair_and_rejects_per_host_mismatch(tmp_path, mismatch):
    text = (ROOT / "update-server/Caddyfile").read_text(encoding="utf-8")
    if mismatch:
        registry = site_block(text, "registry.neosecra.com")
        text = text.replace(registry, registry.replace("neosecra.com.key", "different.key"))
    caddy = tmp_path / "Caddyfile"
    caddy.write_text(text, encoding="utf-8", newline="\n")
    env = {**os.environ, "CLOUDFLARE_ORIGIN_CADDYFILE": bash_path(caddy),
           "CLOUDFLARE_ORIGIN_CERT": bash_path(ROOT / "update-server/certs/neosecra-origin.crt"),
           "CLOUDFLARE_ORIGIN_KEY": "", "CLOUDFLARE_ORIGIN_CA_ROOT": ""}
    result = subprocess.run([str(BASH), "-c", 'export PATH=/usr/bin:/mingw64/bin:/bin; bash "$1" --static',
                             "p4", bash_path(ROOT / "update-server/src/cloudflare-origin-test-012.sh")],
                            env=env, capture_output=True, text=True)
    assert result.returncode == (1 if mismatch else 0), result.stdout + result.stderr
    assert "FAIL: Caddy maps registry.neosecra.com:9447" in result.stderr if mismatch else "12 passed, 0 failed, 3 skipped" in result.stdout
