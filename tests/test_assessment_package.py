"""The Assessment release archive: one manifest, extractor-safe layout, digests only from the lock."""
import hashlib
import importlib
import json
import os
import re
import subprocess
import sys
import tarfile
from pathlib import Path

import pytest
from fixtures.publisher import ROOT, posix

sys.path.insert(0, str(ROOT / 'update-server/lib'))
assessment_package = importlib.import_module('assessment_package')
from registry import load_registry, validate_manifest_trust  # noqa: E402

PYTHON = os.environ.get('NEOSECRA_TEST_PYTHON') or sys.executable
VERSION = '1.3.76'
DIGESTS = {name: 'sha256:' + hashlib.sha256(name.encode()).hexdigest()
           for name in ('postgres', 'redis', 'backend', 'worker', 'beat', 'frontend', 'openvas', 'zap', 'dast-egress')}
LOCK_REFS = {
    'postgres': 'postgres:15', 'redis': 'redis:7-alpine',
    'backend': 'registry.neosecra.com/security-health-backend:' + VERSION,
    'worker': 'registry.neosecra.com/security-health-backend:' + VERSION,
    'beat': 'registry.neosecra.com/security-health-backend:' + VERSION,
    'frontend': 'registry.neosecra.com/security-health-frontend:' + VERSION,
    'openvas': 'immauss/openvas:26.07.12.01', 'zap': 'ghcr.io/zaproxy/zaproxy:2.17.0',
    'dast-egress': 'registry.neosecra.com/neosecra-dast-egress:4',
}
# Backend, worker and beat run one image: they share one digest by contract.
DIGESTS['worker'] = DIGESTS['beat'] = DIGESTS['backend']

MANIFEST = '''product: neosecra-security-health
edition: security-health
version: 1.3.75
channel: stable
trust_policy: minisign-package-v1
build_commit: 0000000000000000000000000000000000000000
database_revision: "stale"
release_date: "2026-01-01T00:00:00Z"
images:
  - name: postgres
    ref: postgres:15
    digest: "@@DIGEST:postgres@@"
  - name: redis
    ref: redis:7-alpine
    digest: "@@DIGEST:redis@@"
  - name: backend
    ref: registry.neosecra.com/security-health-backend:1.3.75
    digest: "@@DIGEST:backend@@"
  - name: worker
    ref: registry.neosecra.com/security-health-backend:1.3.75
    digest: "@@DIGEST:worker@@"
  - name: beat
    ref: registry.neosecra.com/security-health-backend:1.3.75
    digest: "@@DIGEST:beat@@"
  - name: frontend
    ref: registry.neosecra.com/security-health-frontend:1.3.75
    digest: "@@DIGEST:frontend@@"
  - name: openvas
    ref: immauss/openvas:26.07.12.01
    digest: "@@DIGEST:openvas@@"
    profile: openvas
    optional: true
  - name: zap
    ref: ghcr.io/zaproxy/zaproxy:2.17.0
    digest: "@@DIGEST:zap@@"
    profile: dast
    optional: true
  - name: dast-egress
    ref: registry.neosecra.com/neosecra-dast-egress:4
    digest: "@@DIGEST:dast-egress@@"
    profile: dast
    optional: true

upgrade:
  backup_required: true
  migration_required: true
rollback:
  database_strategy: backup_restore
post_upgrade:
  - id: compliance-backfill
    since: "1.3.75"
    service: backend
    command: ["python", "-m", "app.modules.compliance.backfill"]
    timeout_seconds: 60
    on_failure: warn
'''


def write(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding='utf-8', newline='')
    return path


@pytest.fixture
def product(tmp_path):
    """A minimal Assessment checkout with the same file layout as the real one."""
    root = tmp_path / 'assessment'
    v1 = root / 'deployment/v1'
    write(v1 / 'docker-compose.v1.yml', 'name: neosecra-assessment\r\nservices: {}\r\n')
    write(v1 / 'docker-compose.dast.yml', 'services: {}\n')
    write(v1 / '.env.v1.example', 'POSTGRES_USER=neosecra\nDAST_ENABLED=false\n')
    write(v1 / 'release-manifest.yaml', MANIFEST.replace('\n', '\r\n'))
    write(v1 / 'VERSION', '1.3.75\n')
    write(v1 / 'config/nginx/security-health.conf', 'server {}\n')
    write(v1 / 'config/tls/server.key', 'never packaged\n')
    for name in ('zap-start.sh', 'log4j2.xml', 'install-firewall.sh'):
        write(root / 'deployment/dast' / name, '#!/bin/sh\n')
    versions = root / 'backend/alembic/versions'
    write(versions / '001_first.py', 'revision = "001_first"\ndown_revision = None\n')
    write(versions / '002_second.py', 'revision: str = "002_second"\ndown_revision: str | None = "001_first"\n')
    return root


@pytest.fixture
def lock(tmp_path):
    path = tmp_path / 'images.lock'
    path.write_text(''.join(f'{name}={LOCK_REFS[name]}@{DIGESTS[name]}\n' for name in LOCK_REFS), encoding='utf-8')
    return path


def build(product_root, lock, out, version=VERSION, shared_root=ROOT, extra=()):
    return subprocess.run(
        [PYTHON, str(ROOT / 'update-server/lib/assessment_package.py'), 'build', '--version', version,
         '--product-root', str(product_root), '--shared-root', str(shared_root), '--images-lock', str(lock),
         '--output', str(out), '--release-date', '2026-10-05T12:00:00Z', '--build-commit', 'a' * 40, *extra],
        capture_output=True, text=True)


def members(path):
    with tarfile.open(path, 'r:gz') as stream:
        return {m.name: (stream.extractfile(m).read() if m.isfile() else None) for m in stream.getmembers()}


def test_builds_one_manifest_with_trust_policy_and_lock_digests(product, lock, tmp_path):
    out = tmp_path / 'a.tar.gz'
    result = build(product, lock, out)
    assert result.returncode == 0, result.stdout + result.stderr
    files = members(out)
    manifests = [n for n in files if n.endswith('release-manifest.yaml')]
    assert manifests == ['neosecra-distribution-1.3.76/deployment/release-manifest.yaml']
    manifest = files[manifests[0]].decode()
    assert re.search(r'(?m)^trust_policy: minisign-package-v1$', manifest)
    assert re.search(r'(?m)^version: 1\.3\.76$', manifest)
    assert 'database_revision: "002_second"' in manifest
    assert 'build_commit: ' + 'a' * 40 in manifest
    assert 'ref: registry.neosecra.com/security-health-backend:1.3.76' in manifest
    assert '@@DIGEST' not in manifest and '1.3.75' not in manifest.split('post_upgrade:')[0].replace('"1.3.75"', '')
    for name, digest in DIGESTS.items():
        assert digest in manifest
    # The publisher's own check on the produced file.
    validate_manifest_trust(out, load_registry(ROOT, 'assessment'))


def test_archive_is_accepted_by_the_real_extractor_and_has_the_runtime_layout(product, lock, tmp_path):
    out = tmp_path / 'a.tar.gz'
    assert build(product, lock, out).returncode == 0
    dest = tmp_path / 'extract'
    result = subprocess.run([PYTHON, str(ROOT / 'deployment/v1/upgrade/secure_extract.py'), 'release', str(out), str(dest), VERSION],
                            capture_output=True, text=True)
    assert result.returncode == 0, result.stdout + result.stderr
    deployment = dest / 'neosecra-distribution-1.3.76/deployment'
    for needed in ('VERSION', 'lib/common.sh', 'lib/post_upgrade.sh', 'upgrade/upgrade.sh', 'upgrade/adopt-release.sh',
                   'upgrade/post_upgrade.py', 'agent/update-agent.sh', 'agent/artifact-verifier.sh',
                   'docker-compose.v1.yml', 'docker-compose.dast.yml', 'env.v1.example', 'release/images.lock',
                   'dast/zap-start.sh', 'dast/install-firewall.sh', 'config/nginx/security-health.conf',
                   'ca/update-neosecra-com.pub', 'schemas/release-manifest.schema.json'):
        assert (deployment / needed).is_file(), needed
    assert (deployment / 'VERSION').read_text().strip() == VERSION
    # Dot-files cannot travel (the extractor rejects them); links never do.
    names = list(members(out))
    assert not [n for n in names if any(part.startswith('.') for part in n.split('/'))]
    assert not (deployment / 'v1').exists()
    assert not (deployment / 'config/tls').exists() and not any('server.key' in n for n in names)
    assert not [n for n in names if 'hotspot' in n]


def test_shipped_text_files_never_carry_crlf(product, lock, tmp_path):
    out = tmp_path / 'a.tar.gz'
    assert build(product, lock, out).returncode == 0
    for name, data in members(out).items():
        if data is not None:
            assert b'\r\n' not in data, name


def test_scripts_are_executable_and_data_files_are_not(product, lock, tmp_path):
    out = tmp_path / 'a.tar.gz'
    assert build(product, lock, out).returncode == 0
    with tarfile.open(out, 'r:gz') as stream:
        modes = {m.name.split('/deployment/', 1)[-1]: m.mode for m in stream.getmembers() if m.isfile()}
    assert modes['agent/update-agent.sh'] == 0o755 and modes['upgrade/upgrade.sh'] == 0o755
    assert modes['bin/neosecra'] == 0o755
    assert modes['docker-compose.v1.yml'] == 0o644 and modes['release-manifest.yaml'] == 0o644


def test_archive_is_byte_for_byte_reproducible(product, lock, tmp_path):
    first, second = tmp_path / 'one.tar.gz', tmp_path / 'two.tar.gz'
    assert build(product, lock, first).returncode == 0 and build(product, lock, second).returncode == 0
    assert first.read_bytes() == second.read_bytes()


def test_script_checksums_describe_the_shipped_bytes(product, lock, tmp_path):
    out = tmp_path / 'a.tar.gz'
    assert build(product, lock, out).returncode == 0
    files = members(out)
    manifest = files['neosecra-distribution-1.3.76/deployment/release-manifest.yaml'].decode()
    line = re.search(r'(?m)^script_checksums: "(.*)"$', manifest).group(1)
    entries = dict(item.split('=') for item in line.split(','))
    assert 'deployment/upgrade/upgrade.sh' in entries
    for path, digest in entries.items():
        assert hashlib.sha256(files['neosecra-distribution-1.3.76/' + path]).hexdigest() == digest


# --- digests only from the lock ------------------------------------------------------

def test_lock_missing_a_required_service_is_refused(product, lock, tmp_path):
    lock.write_text(''.join(line for line in lock.read_text().splitlines(True) if not line.startswith('beat=')), encoding='utf-8')
    result = build(product, lock, tmp_path / 'a.tar.gz')
    assert result.returncode != 0 and 'images lock must match compose services exactly' in result.stderr
    assert not (tmp_path / 'a.tar.gz').exists()


def test_lock_reference_that_disagrees_with_the_manifest_is_refused(product, lock, tmp_path):
    text = lock.read_text().replace('security-health-frontend:' + VERSION, 'security-health-frontend:1.3.99')
    lock.write_text(text, encoding='utf-8')
    result = build(product, lock, tmp_path / 'a.tar.gz')
    assert result.returncode != 0 and 'differs from the manifest' in result.stderr


def test_optional_images_without_a_lock_entry_are_left_out_not_invented(product, lock, tmp_path):
    lines = [line for line in lock.read_text().splitlines(True) if not line.startswith(('zap=', 'dast-egress='))]
    lock.write_text(''.join(lines), encoding='utf-8')
    out = tmp_path / 'a.tar.gz'
    result = build(product, lock, out)
    assert result.returncode == 0, result.stderr
    manifest = members(out)['neosecra-distribution-1.3.76/deployment/release-manifest.yaml'].decode()
    assert 'name: zap' not in manifest and 'dast-egress' not in manifest and '@@DIGEST' not in manifest


def test_mutable_or_unpinned_lock_entries_are_refused(product, lock, tmp_path):
    lock.write_text(lock.read_text().replace('@' + DIGESTS['redis'], ''), encoding='utf-8')
    assert build(product, lock, tmp_path / 'a.tar.gz').returncode != 0


def test_unresolved_placeholder_for_a_required_image_is_refused(product, lock, tmp_path):
    manifest = product / 'deployment/v1/release-manifest.yaml'
    manifest.write_text(manifest.read_text().replace('name: frontend', 'name: frontend-extra\n    ref: x\n    digest: "@@DIGEST:frontend-extra@@"\n  - name: frontend', 1), encoding='utf-8')
    result = build(product, lock, tmp_path / 'a.tar.gz')
    assert result.returncode != 0


def test_manifest_without_trust_policy_is_refused(product, lock, tmp_path):
    manifest = product / 'deployment/v1/release-manifest.yaml'
    manifest.write_text(re.sub(r'(?m)^trust_policy:.*\n', '', manifest.read_text()), encoding='utf-8')
    result = build(product, lock, tmp_path / 'a.tar.gz')
    assert result.returncode != 0 and 'trust_policy' in result.stderr


def test_secret_looking_env_template_content_is_refused(product, lock, tmp_path):
    (product / 'deployment/v1/.env.v1.example').write_text('SECRET_KEY=' + 'A1b2C3d4' * 5 + '\n', encoding='utf-8')
    result = build(product, lock, tmp_path / 'a.tar.gz')
    assert result.returncode != 0 and 'secret-looking' in result.stderr


def test_version_must_be_numeric_semver(product, lock, tmp_path):
    assert build(product, lock, tmp_path / 'a.tar.gz', version='1.3.76-rc1').returncode != 0


def test_a_symlink_in_the_product_tree_is_refused(product, lock, tmp_path):
    link = product / 'deployment/v1/config/nginx/link.conf'
    try:
        link.symlink_to(product / 'deployment/v1/config/nginx/security-health.conf')
    except OSError:
        pytest.skip('symlinks are not available')
    assert build(product, lock, tmp_path / 'a.tar.gz').returncode != 0


# --- alembic head -----------------------------------------------------------------------

def test_alembic_head_is_found_without_alembic(product):
    assert assessment_package.alembic_head(product) == '002_second'


def test_two_alembic_heads_are_refused(product):
    write(product / 'backend/alembic/versions/003_branch.py', 'revision = "003_branch"\ndown_revision = "001_first"\n')
    with pytest.raises(ValueError, match='exactly one alembic head'):
        assessment_package.alembic_head(product)


def test_merge_revision_resolves_to_a_single_head(product):
    write(product / 'backend/alembic/versions/003_branch.py', 'revision = "003_branch"\ndown_revision = "001_first"\n')
    write(product / 'backend/alembic/versions/004_merge.py', 'revision = "004_merge"\ndown_revision = ("002_second", "003_branch")\n')
    assert assessment_package.alembic_head(product) == '004_merge'


# --- the shared tree keeps the other products' runtime out ------------------------------

def test_stray_secret_file_in_a_plain_shared_tree_stops_the_build(product, lock, tmp_path):
    import shutil
    shared = tmp_path / 'shared'
    for relative in ('products', 'schemas', 'update-server/lib', 'deployment/v1'):
        shutil.copytree(ROOT / relative, shared / relative, ignore=shutil.ignore_patterns('__pycache__', '.env.v1*'))
    write(shared / 'deployment/v1/lib/.env.v1', 'POSTGRES_PASSWORD=never\n')
    out = tmp_path / 'a.tar.gz'
    result = build(product, lock, out, shared_root=shared)
    assert result.returncode != 0 and not out.exists()


# --- the real Assessment checkout (opt-in: NEOSECRA_ASSESSMENT_ROOT) ---------------------

@pytest.mark.skipif(not os.environ.get('NEOSECRA_ASSESSMENT_ROOT'), reason='set NEOSECRA_ASSESSMENT_ROOT to an Assessment checkout')
def test_real_assessment_checkout_builds_a_publishable_archive(tmp_path):
    product_root = Path(os.environ['NEOSECRA_ASSESSMENT_ROOT'])
    lock = tmp_path / 'images.lock'
    template = product_root / 'deployment/v1/release/images.lock.template'
    rows = []
    for line in template.read_text(encoding='utf-8').splitlines():
        line = line.strip()
        if line and not line.startswith('#'):
            name, ref = line.split('=', 1)
            rows.append(f"{name}={ref.replace('@VERSION@', VERSION)}@sha256:{hashlib.sha256((name + VERSION).encode()).hexdigest()}")
    # Same shared-digest rule as production: backend, worker and beat run one image.
    shared = {row.split('=')[0]: row.rsplit('@', 1)[1] for row in rows if row.startswith('backend=')}
    rows = [re.sub(r'@sha256:.*$', '@' + shared['backend'], row) if row.split('=')[0] in ('worker', 'beat') else row for row in rows]
    lock.write_text('\n'.join(rows) + '\n', encoding='utf-8')
    out = tmp_path / 'distribution-1.3.76.tar.gz'
    result = build(product_root, lock, out)
    assert result.returncode == 0, result.stdout + result.stderr
    names = list(members(out))
    assert sum(n.endswith('/release-manifest.yaml') for n in names) == 1
    assert posix(out)
