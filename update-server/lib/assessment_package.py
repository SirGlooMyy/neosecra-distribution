#!/usr/bin/env python3
"""Assemble the signed-channel release archive for NeoSecra Assessment.

The archive is what ``upgrade.sh`` (prepare_target_release) and ``bootstrap.sh``
extract on an installation:

    neosecra-distribution-<version>/deployment/...

``deployment/`` is the flat runtime tree: the product files Assessment owns
(compose, DAST overlay, env template, release manifest, nginx config, DAST scanner
scripts) plus the shared runtime Distribution owns (agent, upgrade, lib, install,
backup, bin, smoke-tests, schemas, ca).  It carries exactly ONE release manifest
(the one the publisher checks for ``trust_policy``) and the image lock
``release/images.lock``.

Two constraints of the extractors shape the layout and are checked here, not
discovered on a customer host:

* ``secure_extract.py`` and bootstrap accept only path components that start with
  a letter or digit, so the env template ships as ``env.v1.example`` and is
  renamed to ``.env.v1.example`` after extraction;
* archives never carry links, and a ``v1 -> .`` bridge is created after
  extraction by ``ensure_release_v1_link``.

Nothing is built or pushed here; digests come from the image lock only.
"""
from __future__ import annotations

import argparse
import ast
import gzip
import hashlib
import io
import re
import subprocess
import sys
import tarfile
from datetime import datetime, timezone
from pathlib import Path, PurePosixPath

LIB = Path(__file__).resolve().parent
sys.path.insert(0, str(LIB))

from registry import fail, images as read_lock, load_registry, validate_manifest_trust  # noqa: E402

VERSION_RE = re.compile(r'^[0-9]+\.[0-9]+\.[0-9]+$')
SAFE_COMPONENT = re.compile(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$')
ARCHIVE_ROOT = 'neosecra-distribution-{version}'
PRODUCT = 'assessment'

# Product files (relative to the Assessment checkout) -> path inside deployment/.
PRODUCT_FILES = {
    'deployment/v1/docker-compose.v1.yml': 'docker-compose.v1.yml',
    'deployment/v1/docker-compose.dast.yml': 'docker-compose.dast.yml',
    'deployment/v1/.env.v1.example': 'env.v1.example',
    'deployment/v1/release-manifest.yaml': 'release-manifest.yaml',
    'deployment/dast/zap-start.sh': 'dast/zap-start.sh',
    'deployment/dast/log4j2.xml': 'dast/log4j2.xml',
    'deployment/dast/install-firewall.sh': 'dast/install-firewall.sh',
}
PRODUCT_TREES = {'deployment/v1/config': 'config'}
SKIPPED_TREES = {'tls'}  # per-installation certificates are generated on the host
# Shared runtime (relative to the Distribution checkout, under deployment/v1/).
SHARED_DIRS = ('agent', 'upgrade', 'lib', 'install', 'backup', 'bin', 'smoke-tests', 'schemas', 'ca')
# Hotspot-only agent files add nothing to an Assessment installation.
SHARED_SKIP = {'agent/hotspot-updater.sh', 'agent/install-hotspot-agent.sh'}
SCRIPT_CHECKSUMS = (
    'upgrade/upgrade.sh', 'install/preflight.sh', 'install/postflight.sh', 'lib/common.sh',
    'lib/manifest.sh', 'lib/state.sh', 'lib/docker.sh', 'lib/logging.sh', 'upgrade/rollback.sh',
)
EXECUTABLE_SUFFIXES = ('.sh',)
EXECUTABLE_NAMES = {'bin/neosecra'}
DIGEST_RE = re.compile(r'^sha256:[0-9a-f]{64}$')
PLACEHOLDER_RE = re.compile(r'@@DIGEST:([a-z0-9][a-z0-9._-]*)@@')
IGNORED_PARTS = {'__pycache__'}


# --- alembic head (parsed with ast: no alembic/SQLAlchemy needed on the build machine) -----

def _literal_assignment(tree: ast.Module, name: str):
    """Value of a top-level ``name = <literal>`` / ``name: T = <literal>`` (or None)."""
    for node in tree.body:
        if isinstance(node, ast.Assign) and any(isinstance(t, ast.Name) and t.id == name for t in node.targets):
            value = node.value
        elif isinstance(node, ast.AnnAssign) and isinstance(node.target, ast.Name) and node.target.id == name and node.value:
            value = node.value
        else:
            continue
        try:
            return ast.literal_eval(value)
        except ValueError:
            return None
    return None


def alembic_head(product_root: Path) -> str:
    versions = product_root / 'backend' / 'alembic' / 'versions'
    if not versions.is_dir():
        fail('alembic versions directory not found: ' + str(versions))
    revisions, parents = set(), set()
    for path in sorted(versions.glob('*.py')):
        tree = ast.parse(path.read_text(encoding='utf-8-sig'), filename=str(path))
        revision = _literal_assignment(tree, 'revision')
        if not isinstance(revision, str):
            continue
        revisions.add(revision)
        down = _literal_assignment(tree, 'down_revision')
        if isinstance(down, str):
            parents.add(down)
        elif isinstance(down, (tuple, list)):
            parents.update(item for item in down if isinstance(item, str))
    heads = sorted(revisions - parents)
    if len(heads) != 1:
        fail('expected exactly one alembic head, found: ' + ', '.join(heads or ['none']))
    return heads[0]


# --- file collection ------------------------------------------------------------------

def _listing(root: Path, relative: str) -> list[str]:
    """Files below ``root/relative`` (sorted, POSIX, no cache/secret leftovers)."""
    base = root / relative
    if not base.is_dir():
        fail('missing directory: ' + str(base))
    out = []
    for path in sorted(base.rglob('*')):
        if path.is_symlink():
            fail('symbolic link is not allowed in the package: ' + str(path))
        if not path.is_file():
            continue
        rel = path.relative_to(root).as_posix()
        if IGNORED_PARTS & set(path.parts) or path.suffix == '.pyc':
            continue
        out.append(rel)
    return out


def _git_visible(root: Path, relative: str) -> set[str] | None:
    """Files git would show for ``relative`` (tracked, or untracked but not ignored).

    Ignored files (``.env.v1`` copies, keys, backups) are never packaged.  Returns
    None when ``root`` is not a git checkout (a plain directory, e.g. in tests).
    """
    try:
        done = subprocess.run(['git', '-C', str(root), 'ls-files', '--cached', '--others',
                               '--exclude-standard', '--', relative],
                              capture_output=True, text=True, check=False)
    except OSError:
        return None
    if done.returncode != 0:
        return None
    return {line for line in done.stdout.splitlines() if line}


def _normalise(data: bytes) -> bytes:
    """A Windows checkout (autocrlf) must never ship CRLF to a Linux host."""
    return data if b'\x00' in data else data.replace(b'\r\n', b'\n')


def collect(product_root: Path, shared_root: Path, version: str, lock_text: str) -> dict[str, bytes]:
    """Map of in-archive path (below ``deployment/``) -> bytes, before manifest stamping."""
    files: dict[str, bytes] = {}

    def put(destination: str, data: bytes):
        if destination in files:
            fail('duplicate package path: ' + destination)
        files[destination] = _normalise(data)

    for source, destination in PRODUCT_FILES.items():
        path = product_root / source
        if path.is_symlink() or not path.is_file():
            fail('missing product file: ' + source)
        put(destination, path.read_bytes())
    for source, destination in PRODUCT_TREES.items():
        visible = _git_visible(product_root, source)
        for rel in _listing(product_root, source):
            parts = PurePosixPath(rel).relative_to(source).parts
            if parts[0] in SKIPPED_TREES or (visible is not None and rel not in visible):
                continue
            put(destination + '/' + '/'.join(parts), (product_root / rel).read_bytes())
    for directory in SHARED_DIRS:
        source = 'deployment/v1/' + directory
        visible = _git_visible(shared_root, source)
        for rel in _listing(shared_root, source):
            inner = directory + '/' + PurePosixPath(rel).relative_to(source).as_posix()
            if inner in SHARED_SKIP or (visible is not None and rel not in visible):
                continue
            put(inner, (shared_root / rel).read_bytes())
    put('VERSION', (version + chr(10)).encode())
    put('release/images.lock', lock_text.encode())
    return files


# --- manifest stamping ------------------------------------------------------------------

def _scalar(text: str, key: str) -> re.Match | None:
    return re.search(r'^' + re.escape(key) + r':[^\n]*$', text, re.M)


def stamp_manifest(text: str, *, version: str, release_date: str, database_revision: str,
                   build_commit: str | None, distribution_commit: str | None,
                   checksums: str, lock: dict[str, dict]) -> str:
    text = text.replace('\r\n', '\n')

    def set_scalar(key, value, after=None):
        nonlocal text
        match = _scalar(text, key)
        line = f'{key}: {value}'
        if match:
            text = text[:match.start()] + line + text[match.end():]
        elif after and _scalar(text, after):
            anchor = _scalar(text, after)
            text = text[:anchor.end()] + '\n' + line + text[anchor.end():]
        else:
            fail('release manifest has no ' + key + ' and no place to add it')

    set_scalar('version', version)
    set_scalar('database_revision', '"' + database_revision + '"')
    if build_commit:
        set_scalar('build_commit', build_commit)
    if distribution_commit:
        if _scalar(text, 'distribution_commit'):
            set_scalar('distribution_commit', distribution_commit)
        else:
            set_scalar('distribution_commit', distribution_commit, after='build_commit')
    set_scalar('release_date', '"' + release_date + '"')
    if _scalar(text, 'script_checksums'):
        set_scalar('script_checksums', '"' + checksums + '"')
    else:
        set_scalar('script_checksums', '"' + checksums + '"', after='release_date')

    # images: block -> entries are "  - name: x" followed by indented keys.
    start = re.search(r'^images:\s*$', text, re.M)
    if not start:
        fail('release manifest has no images block')
    end = re.search(r'^\S', text[start.end() + 1:], re.M)
    block_end = start.end() + 1 + (end.start() if end else len(text) - start.end() - 1)
    block = text[start.end() + 1:block_end]
    entries = re.split(r'(?m)^(?=  - name:)', block)
    head, entries = entries[0], entries[1:]
    kept, seen = [], set()
    for entry in entries:
        name = re.match(r'  - name:\s*(\S+)', entry).group(1)
        seen.add(name)
        optional = re.search(r'(?m)^    optional:[ 	]*true[ 	]*$', entry) is not None
        entry = re.sub(r'(?m)^(    ref:[ 	]*\S*security-health-(?:backend|frontend)):[0-9][0-9.]*[ 	]*$',
                       lambda m: m.group(1) + ':' + version, entry)
        ref = re.search(r'(?m)^    ref:[ 	]*(\S+)[ 	]*$', entry).group(1)
        if name not in lock:
            if not optional:
                fail('image lock has no entry for required manifest image: ' + name)
            continue
        if lock[name]['reference'] != ref:
            fail(f'image lock reference for {name} ({lock[name]["reference"]}) differs from the manifest ({ref})')
        replaced = re.sub(r'(?m)^(    digest:[ 	]*).*$', lambda m: m.group(1) + '"' + lock[name]['digest'] + '"', entry)
        if replaced == entry and DIGEST_RE.fullmatch(lock[name]['digest']) is None:
            fail('image digest cannot be stamped for ' + name)
        kept.append(replaced)
    unknown = set(lock) - seen
    if unknown:
        fail('image lock names services the manifest does not know: ' + ', '.join(sorted(unknown)))
    text = text[:start.end() + 1] + head + ''.join(kept) + text[block_end:]
    leftovers = PLACEHOLDER_RE.findall(text)
    if leftovers:
        fail('unresolved image digest placeholders: ' + ', '.join(sorted(set(leftovers))))
    if re.search(r'^trust_policy:\s*["\']?minisign-package-v1["\']?\s*(#.*)?$', text, re.M) is None:
        fail('release manifest does not state trust_policy: minisign-package-v1')
    if len(re.findall(r'^trust_policy:', text, re.M)) != 1:
        fail('release manifest must state trust_policy exactly once')
    try:
        import yaml
        data = yaml.safe_load(text)
        if str(data.get('version')) != version:
            fail('stamped manifest version is not the release version')
    except ImportError:  # the publisher and the agent validate it again
        pass
    return text


# --- archive ---------------------------------------------------------------------------

def _mode(path: str) -> int:
    return 0o755 if path.endswith(EXECUTABLE_SUFFIXES) or path in EXECUTABLE_NAMES else 0o644


def write_archive(files: dict[str, bytes], version: str, output: Path, mtime: int) -> None:
    root = ARCHIVE_ROOT.format(version=version)
    directories = {root, root + '/deployment'}
    for path in files:
        parts = PurePosixPath(path).parts
        for index in range(1, len(parts)):
            directories.add(root + '/deployment/' + '/'.join(parts[:index]))
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode='w', format=tarfile.PAX_FORMAT) as stream:
        for name in sorted(directories):
            info = tarfile.TarInfo(name)
            info.type, info.mode, info.mtime = tarfile.DIRTYPE, 0o755, mtime
            stream.addfile(info)
        for path in sorted(files):
            info = tarfile.TarInfo(root + '/deployment/' + path)
            info.size, info.mode, info.mtime = len(files[path]), _mode(path), mtime
            stream.addfile(info, io.BytesIO(files[path]))
    output.parent.mkdir(parents=True, exist_ok=True)
    with open(output, 'wb') as raw:
        with gzip.GzipFile(filename='', mode='wb', fileobj=raw, mtime=0, compresslevel=9) as compressed:
            compressed.write(buffer.getvalue())


def verify_package(output: Path, registry_root: Path, version: str) -> None:
    """The publisher's own archive checks plus the extractor's path rule."""
    from archive import inspect
    reg = load_registry(registry_root, PRODUCT)
    inspect(output, reg['secret_allowlist'])
    validate_manifest_trust(output, reg)
    manifests = 0
    with tarfile.open(output, 'r:gz') as stream:
        names = []
        for member in stream.getmembers():
            if not (member.isfile() or member.isdir()):
                fail('package contains a link or special entry: ' + member.name)
            for part in member.name.split('/'):
                if not SAFE_COMPONENT.fullmatch(part):
                    fail('package path component would be rejected by the extractor: ' + member.name)
            names.append(member.name)
            if member.isfile() and PurePosixPath(member.name).name == 'release-manifest.yaml':
                manifests += 1
            if member.isfile():
                data = stream.extractfile(member).read()
                if b'ghcr.io/sirgloomyy' in data.lower():
                    fail('package references the private GHCR namespace: ' + member.name)
        if manifests != 1:
            fail(f'package must contain exactly one release-manifest.yaml, found {manifests}')
        root = ARCHIVE_ROOT.format(version=version)
        for required in ('VERSION', 'lib/common.sh', 'upgrade/upgrade.sh', 'docker-compose.v1.yml',
                         'release-manifest.yaml', 'env.v1.example', 'release/images.lock', 'agent/update-agent.sh'):
            if root + '/deployment/' + required not in names:
                fail('package is missing deployment/' + required)


def build(args) -> Path:
    version = args.version
    if not VERSION_RE.fullmatch(version):
        fail('version must be numeric semver X.Y.Z')
    product_root, shared_root = Path(args.product_root).resolve(), Path(args.shared_root).resolve()
    reg = load_registry(shared_root, PRODUCT)
    lock_path = Path(args.images_lock)
    if not lock_path.is_file() or lock_path.is_symlink():
        fail('missing or unsafe --images-lock')
    lock = read_lock(lock_path, reg)  # same validation the publisher applies
    lock_text = lock_path.read_text(encoding='utf-8')
    release_date = args.release_date or datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
    mtime = int(datetime.strptime(release_date, '%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=timezone.utc).timestamp())
    files = collect(product_root, shared_root, version, lock_text)
    checksums = ','.join(
        'deployment/' + path + '=' + hashlib.sha256(files[path]).hexdigest()
        for path in SCRIPT_CHECKSUMS if path in files)
    files['release-manifest.yaml'] = _normalise(stamp_manifest(
        files['release-manifest.yaml'].decode('utf-8'), version=version, release_date=release_date,
        database_revision=alembic_head(product_root), build_commit=args.build_commit or None,
        distribution_commit=args.distribution_commit or None, checksums=checksums, lock=lock,
    ).encode('utf-8'))
    output = Path(args.output)
    write_archive(files, version, output, mtime)
    verify_package(output, shared_root, version)
    return output


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest='command', required=True)
    head = sub.add_parser('head', help='print the alembic head of a product checkout')
    head.add_argument('--product-root', required=True)
    make = sub.add_parser('build', help='assemble the release archive')
    make.add_argument('--version', required=True)
    make.add_argument('--product-root', required=True, help='Assessment checkout (product files)')
    make.add_argument('--shared-root', required=True, help='Distribution checkout (shared runtime, registry)')
    make.add_argument('--images-lock', required=True)
    make.add_argument('--output', required=True)
    make.add_argument('--release-date', help='UTC YYYY-MM-DDTHH:MM:SSZ (default: now)')
    make.add_argument('--build-commit')
    make.add_argument('--distribution-commit')
    args = parser.parse_args(argv)
    if args.command == 'head':
        print(alembic_head(Path(args.product_root)))
        return 0
    output = build(args)
    digest = hashlib.sha256(output.read_bytes()).hexdigest()
    print(f'[build-release] archive={output}')
    print(f'[build-release] sha256={digest} size={output.stat().st_size}')
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (ValueError, OSError, KeyError, TypeError) as exc:
        print('[ERROR] ' + str(exc), file=sys.stderr)
        sys.exit(1)
