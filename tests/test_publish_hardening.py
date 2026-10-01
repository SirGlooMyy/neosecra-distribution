"""Offline regression coverage for publisher templates and Hotspot VERSION."""
import shutil
import subprocess
import sys

import pytest
from fixtures.publisher import ROOT, Publisher, package, posix

sys.path.insert(0, str(ROOT / 'update-server/lib'))
from archive import inspect


@pytest.mark.parametrize('suffix', ['example', 'sample', 'template', 'dist'])
@pytest.mark.parametrize('name', ['deployment/.env.v1', 'deployment/v1/.env.v1', 'payload/id_rsa', 'payload/private.pem'])
def test_example_suffix_accepts_placeholders(tmp_path, name, suffix):
    archive = package(tmp_path / 'template.tar.gz', {
        name + '.' + suffix: b'PASSWORD=change-me\nTOKEN=<your-token>\nLONG_PLACEHOLDER=change-me-with-a-strong-password\nEMPTY=\n',
    })
    inspect(archive)


@pytest.mark.parametrize('content', [
    b'TOKEN=' + b'a' * 20 + b'\n',
    b'TOKEN="' + b'A1b2+/' * 5 + b'=="\n',
    b'TOKEN=short\nSECOND=' + b'0123456789abcdef' * 4 + b'\n',
    b'-----BEGIN PRIVATE KEY-----\ntest-only invalid material\n',
    b'-----BEGIN RSA PRIVATE KEY-----\ntest-only invalid material\n',
])
@pytest.mark.parametrize('allowlist', [(), ('payload/.env.example',)])
def test_example_secret_content_is_rejected_even_if_allowlisted(tmp_path, content, allowlist):
    archive = package(tmp_path / 'secret-template.tar.gz', {'payload/.env.example': content})
    with pytest.raises(ValueError, match='secret-looking content'):
        inspect(archive, allowlist)


@pytest.mark.parametrize('name', ['.env', '.env.v1', 'id_rsa', 'id_ed25519', 'private.pem'])
def test_runtime_secret_names_remain_rejected(tmp_path, name):
    archive = package(tmp_path / 'runtime.tar.gz', {'payload/' + name: b'placeholder\n'})
    with pytest.raises(ValueError, match='secret-looking file'):
        inspect(archive)


def hotspot_payload(version, marker):
    files = {
        'docker-compose.yml': b'services: {}\n',
        'backend/.env.example': b'PASSWORD=change-me\n',
        'frontend/admin/readme.txt': b'fixture\n',
        'frontend/portal/readme.txt': b'fixture\n',
    }
    for name in ('install-hotspot-agent', 'update-agent', 'hotspot-updater', 'artifact-verifier'):
        files['deployment/v1/agent/' + name + '.sh'] = b'#!/usr/bin/env bash\ntrue\n'
    for name in ('secure_extract', 'verify_rollback_auth', 'recovery'):
        files['deployment/v1/upgrade/' + name + '.py'] = b'# fixture\n'
    for name in ('common', 'manifest', 'state'):
        files['deployment/v1/lib/' + name + '.sh'] = b'# fixture\n'
    for directory in ('deployment/v1/ca', 'deploy/ca'):
        for name in ('update-neosecra-com.pub', 'update-neosecra-com-20260904.pub'):
            files[directory + '/' + name] = b'test-only public fixture\n'
    if marker is not None:
        files['VERSION'] = marker
    return {'neosecra-hotspot-' + version + '/' + name: content for name, content in files.items()}


VERSION_CASES = [
    (None, False),
    (b'0.3.25\n', False),
    (b'0.3.26', True),
    (b'0.3.26\n', True),
    (b'0.3.26\r\n', True),
    (b' 0.3.26\n', False),
    (b'0.3.26 \n', False),
    (b'0.3.26\n\n', False),
    (b'0.3.26\n0.3.26\n', False),
    (b'v0.3.26\n', False),
    (b'0.3.26\x00', False),
    (b'\xff', False),
    (b'0.3.26' + b' ' * 256, False),
]


@pytest.mark.parametrize('marker,accepted', VERSION_CASES)
def test_hotspot_gate_enforces_version(tmp_path, marker, accepted):
    p = Publisher(tmp_path)
    extractor = p.root / 'deployment/v1/upgrade/secure_extract.py'
    extractor.parent.mkdir(parents=True)
    shutil.copyfile(ROOT / 'deployment/v1/upgrade/secure_extract.py', extractor)
    archive = package(tmp_path / 'hotspot.tar.gz', hotspot_payload('0.3.26', marker))
    result = p.shell([posix(p.root / 'ci/prerelease-gate-hotspot.sh'), '--archive', posix(archive), '--version', '0.3.26'])
    assert (result.returncode == 0) is accepted, result.stdout + result.stderr
    assert ('HOTSPOT_GATE|PASS' in result.stdout) is accepted
    if not accepted:
        assert 'VERSION' in result.stdout + result.stderr


@pytest.mark.parametrize('marker,accepted', VERSION_CASES)
def test_bootstrap_archive_preflight_uses_same_version_contract(tmp_path, marker, accepted):
    source = (ROOT / 'update-server/bootstrap-hotspot.sh').read_text(encoding='utf-8')
    preflight = source.split('python3 - "$TMP_DIR/hotspot.tar.gz" "$EXTRACT_ROOT" "$VERSION" <<\'PY\'\n', 1)[1].split('\nPY\n', 1)[0]
    archive = package(tmp_path / 'hotspot.tar.gz', hotspot_payload('0.3.26', marker))
    result = subprocess.run([sys.executable, '-c', preflight, str(archive), str(tmp_path / 'extract'), '0.3.26'], capture_output=True, text=True)
    assert (result.returncode == 0) is accepted, result.stdout + result.stderr
    if not accepted:
        assert 'VERSION' in result.stdout + result.stderr


def test_gate_accepts_prerelease_version(tmp_path):
    p = Publisher(tmp_path)
    extractor = p.root / 'deployment/v1/upgrade/secure_extract.py'
    extractor.parent.mkdir(parents=True)
    shutil.copyfile(ROOT / 'deployment/v1/upgrade/secure_extract.py', extractor)
    version = '0.3.26-rc.1'
    archive = package(tmp_path / 'hotspot.tar.gz', hotspot_payload(version, version.encode() + b'\n'))
    result = p.shell([posix(p.root / 'ci/prerelease-gate-hotspot.sh'), '--archive', posix(archive), '--version', version])
    assert result.returncode == 0, result.stdout + result.stderr
