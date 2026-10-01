"""Offline regression coverage for publisher templates and Hotspot VERSION."""
import shutil
import json
import subprocess
import sys

import pytest
from fixtures.publisher import ROOT, Publisher, package, posix

sys.path.insert(0, str(ROOT / 'update-server/lib'))
from archive import inspect
from registry import validate_manifest_trust


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


@pytest.mark.parametrize('suffix', ['yaml', 'json'])
@pytest.mark.parametrize('registered', ['minisign-package-v1', 'cosign-spdx-v1'])
@pytest.mark.parametrize('policy', [None, 'minisign-package-v1', 'cosign-spdx-v1', 'fallback'])
def test_publisher_manifest_policy_matches_registry(tmp_path, suffix, registered, policy):
    p = Publisher(tmp_path, stub_gates=True)
    p.register_fixture()
    registry_path = p.root / 'products/fixtureprod.json'
    reg = json.loads(registry_path.read_text(encoding='utf-8'))
    reg['trust_policy'] = registered
    registry_path.write_text(json.dumps(reg), encoding='utf-8')
    p.seed()
    before = p.snapshot()
    data = {'version': '1.0.1'}
    if policy is not None:
        data['trust_policy'] = policy
    content = json.dumps(data) if suffix == 'json' else ''.join(key + ': ' + value + '\n' for key, value in data.items())
    archive = package(tmp_path / 'fixture.tar.gz', {'payload/deployment/v1/release-manifest.' + suffix: content.encode()})
    result = p.run(archive=archive, dry=policy == registered)
    if policy == registered:
        assert result.returncode == 0, result.stdout + result.stderr
        assert 'trust=' + registered in result.stdout
        assert p.snapshot() == before
    else:
        assert result.returncode != 0
        assert 'trust_policy' in result.stderr
        if policy in ('minisign-package-v1', 'cosign-spdx-v1'):
            assert 'mismatch' in result.stderr
        assert p.snapshot() == before
        assert not (tmp_path / 'gate.log').exists()
        assert not (p.www / '.publish-lock').exists()


@pytest.mark.parametrize('dry', [False, True])
def test_manifest_mismatch_blocks_ungated_channel(tmp_path, dry):
    p = Publisher(tmp_path, stub_gates=True)
    p.register_fixture()
    registry_path = p.root / 'products/fixtureprod.json'
    reg = json.loads(registry_path.read_text(encoding='utf-8'))
    reg['channels'].append('beta')
    registry_path.write_text(json.dumps(reg), encoding='utf-8')
    before = p.snapshot()
    archive = package(tmp_path / 'fixtureprod-1.0.1.tar.gz', {
        'release-manifest.yaml': b'trust_policy: cosign-spdx-v1\n',
    })
    result = p.run(channel='beta', archive=archive, dry=dry)
    assert result.returncode != 0 and 'trust_policy mismatch' in result.stderr
    assert p.snapshot() == before
    assert not (tmp_path / 'gate.log').exists()


@pytest.mark.parametrize('content', [
    b'trust_policy: minisign-package-v1\ntrust_policy: cosign-spdx-v1\n',
    b'trust_policy: minisign-package-v1\n"trust_policy": cosign-spdx-v1\n',
    b'trust_policy: minisign-package-v1#not-a-comment\n',
    b'trust_policy: minisign-package-v1\n---\n{trust_policy: cosign-spdx-v1}\n',
    b'trust_policy: [minisign-package-v1]\n',
])
def test_ambiguous_or_invalid_yaml_policy_is_rejected(tmp_path, content):
    archive = package(tmp_path / 'policy.tar.gz', {'release-manifest.yaml': content})
    with pytest.raises(ValueError, match='trust_policy'):
        validate_manifest_trust(archive, {'trust_policy': 'minisign-package-v1'})


@pytest.mark.parametrize('value', ['minisign-package-v1', "'minisign-package-v1'", '"minisign-package-v1"'])
def test_yaml_policy_scalar_and_comment_are_supported(tmp_path, value):
    archive = package(tmp_path / 'policy.tar.gz', {
        'release-manifest.yaml': ('trust_policy: ' + value + ' # registered policy\n').encode(),
    })
    validate_manifest_trust(archive, {'trust_policy': 'minisign-package-v1'})


def test_multiple_release_manifests_are_rejected(tmp_path):
    archive = package(tmp_path / 'policy.tar.gz', {
        'release-manifest.yaml': b'trust_policy: minisign-package-v1\n',
        'deployment/v1/release-manifest.json': b'{"trust_policy":"minisign-package-v1"}\n',
    })
    with pytest.raises(ValueError, match='multiple manifests'):
        validate_manifest_trust(archive, {'trust_policy': 'minisign-package-v1'})


def test_final_transformed_manifest_policy_is_checked(tmp_path):
    p = Publisher(tmp_path, stub_gates=True)
    p.register_fixture()
    p.seed()
    before = p.snapshot()
    archive = package(tmp_path / 'fixture.tar.gz', {
        'release-manifest.yaml': b'trust_policy: minisign-package-v1\n',
    })
    changed = package(tmp_path / 'changed.tar.gz', {
        'release-manifest.yaml': b'trust_policy: cosign-spdx-v1\n',
    })
    # Fixture step changes only the staged archive, exercising the final check.
    step = p.root / 'update-server/lib/steps/migration-contract.sh'
    step.write_text('cp -- "' + posix(changed) + '" "$ARCHIVE"\n', encoding='utf-8', newline='\n')
    registry_path = p.root / 'products/fixtureprod.json'
    reg = json.loads(registry_path.read_text(encoding='utf-8'))
    reg['steps'] = ['migration-contract']
    registry_path.write_text(json.dumps(reg), encoding='utf-8')
    result = p.run(archive=archive)
    assert result.returncode != 0 and 'trust_policy mismatch' in result.stderr
    assert p.snapshot() == before
    assert not (tmp_path / 'gate.log').exists()
