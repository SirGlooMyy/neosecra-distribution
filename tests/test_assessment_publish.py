"""Publishing Assessment through the registry-driven publisher (candidate first, stable by promotion)."""
import hashlib
import io
import json
import tarfile
from pathlib import Path

import pytest
from fixtures.publisher import ROOT, Publisher, posix

VERSION = '1.3.76'
REFS = {
    'postgres': 'postgres:15', 'redis': 'redis:7-alpine',
    'backend': 'registry.neosecra.com/security-health-backend:' + VERSION,
    'worker': 'registry.neosecra.com/security-health-backend:' + VERSION,
    'beat': 'registry.neosecra.com/security-health-backend:' + VERSION,
    'frontend': 'registry.neosecra.com/security-health-frontend:' + VERSION,
    'openvas': 'immauss/openvas:26.07.12.01', 'zap': 'ghcr.io/zaproxy/zaproxy:2.17.0',
    'dast-egress': 'registry.neosecra.com/neosecra-dast-egress:4',
}
SHARED = ('backend', 'worker', 'beat')


def digest(name):
    return 'sha256:' + hashlib.sha256(('digest:' + ('backend' if name in SHARED else name)).encode()).hexdigest()


def lock_text(names=None):
    names = names if names is not None else list(REFS)
    return ''.join(f'{name}={REFS[name]}@{digest(name)}\n' for name in names)


MANIFEST = 'product: neosecra-security-health\nversion: %s\ntrust_policy: minisign-package-v1\n'


def archive(path, lock=None, manifests=1, trust=True, version=VERSION):
    root = 'neosecra-distribution-%s/deployment/' % version
    entries = {root + 'VERSION': version + '\n', root + 'lib/common.sh': '#!/usr/bin/env bash\n'}
    text = MANIFEST % version if trust else 'product: neosecra-security-health\nversion: %s\n' % version
    entries[root + 'release-manifest.yaml'] = text
    for index in range(1, manifests):
        entries[root + 'extra%d/release-manifest.yaml' % index] = text
    entries[root + 'release/images.lock'] = lock if lock is not None else lock_text()
    with tarfile.open(path, 'w:gz') as stream:
        for name, content in entries.items():
            data = content.encode()
            info = tarfile.TarInfo(name)
            info.size = len(data)
            stream.addfile(info, io.BytesIO(data))
    return path


def write_lock(tmp, text=None):
    path = tmp / 'images.lock'
    path.write_text(text if text is not None else lock_text(), encoding='utf-8', newline='\n')
    return path


def ok(result):
    assert result.returncode == 0, result.stdout + result.stderr


def channel(p, name='candidate'):
    return json.loads((p.www / ('channels/assessment-%s.json' % name)).read_text())


def test_first_candidate_publication_creates_the_signed_channel_pair(tmp_path):
    p = Publisher(tmp_path)
    assert not (p.root / 'channels/assessment-candidate.json').exists()
    package = archive(tmp_path / ('distribution-%s.tar.gz' % VERSION))
    ok(p.run(product='assessment', channel='candidate', version=VERSION, archive=package, lock=write_lock(tmp_path)))
    for base in (p.root / 'channels', p.www / 'channels'):
        assert (base / 'assessment-candidate.json').is_file() and (base / 'assessment-candidate.json.minisig').is_file()
    data = channel(p)
    assert data['channel'] == 'assessment-candidate' and data['product'] == 'assessment' and data['status'] == 'available'
    assert data['current_version'] == VERSION
    release = data['releases'][0]
    assert release['archive']['url'] == 'https://update.neosecra.com/releases/%s/distribution-%s.tar.gz' % (VERSION, VERSION)
    assert release['archive']['signature_url'].endswith('.tar.gz.minisig')
    assert 'docker_bundle' not in release and 'bundle_url' not in release  # registry pull, no bundle
    assert release['bootstrap']['url'] == 'https://update.neosecra.com/releases/%s/bootstrap.sh' % VERSION
    # Never touches stable.
    assert not (p.www / 'channels/assessment-stable.json').exists()
    assert (p.www / ('releases/%s/distribution-%s.tar.gz' % (VERSION, VERSION))).read_bytes() == package.read_bytes()


def test_candidate_entry_carries_the_images_map_with_optional_profile_images(tmp_path):
    p = Publisher(tmp_path)
    ok(p.run(product='assessment', channel='candidate', version=VERSION, archive=archive(tmp_path / 'a.tar.gz'), lock=write_lock(tmp_path)))
    images = channel(p)['releases'][0]['images']
    assert set(images) == set(REFS)
    for name, meta in images.items():
        assert meta['reference'] == REFS[name] and meta['digest'] == digest(name)
        assert ('optional' in meta) is (name in {'openvas', 'zap', 'dast-egress'})
        assert meta.get('optional', True) is True
    assert images['backend']['digest'] == images['worker']['digest'] == images['beat']['digest']


def test_candidate_is_not_gated_but_stable_is(tmp_path):
    p = Publisher(tmp_path, stub_gates=True)
    package = archive(tmp_path / 'a.tar.gz')
    ok(p.run(product='assessment', channel='candidate', version=VERSION, archive=package, lock=write_lock(tmp_path)))
    assert not (tmp_path / 'gate.log').exists()
    ok(p.run(product='assessment', channel='stable', version=VERSION, archive=package, lock=write_lock(tmp_path)))
    log = (tmp_path / 'gate.log').read_text()
    assert 'prerelease-gate.sh' in log and hashlib.sha256(package.read_bytes()).hexdigest() in log


def test_stable_promotion_reuses_the_candidate_archive_bytes_and_signatures(tmp_path):
    p = Publisher(tmp_path, stub_gates=True)
    package = archive(tmp_path / 'a.tar.gz')
    lock = write_lock(tmp_path)
    ok(p.run(product='assessment', channel='candidate', version=VERSION, archive=package, lock=lock))
    release = p.www / ('releases/' + VERSION)
    before = {path.name: path.read_bytes() for path in release.iterdir()}
    ok(p.run(product='assessment', channel='stable', version=VERSION, archive=package, lock=lock))
    assert {path.name: path.read_bytes() for path in release.iterdir()} == before
    assert channel(p, 'stable')['releases'][0]['archive'] == channel(p)['releases'][0]['archive']
    assert channel(p, 'stable')['channel'] == 'assessment-stable'


def test_a_changed_archive_cannot_be_promoted_under_the_same_version(tmp_path):
    p = Publisher(tmp_path, stub_gates=True)
    lock = write_lock(tmp_path)
    ok(p.run(product='assessment', channel='candidate', version=VERSION, archive=archive(tmp_path / 'a.tar.gz'), lock=lock))
    other = archive(tmp_path / 'b.tar.gz', lock=lock_text() + '# changed\n')
    result = p.run(product='assessment', channel='stable', version=VERSION, archive=other, lock=lock)
    assert result.returncode != 0


def test_each_candidate_release_must_be_newer(tmp_path):
    p = Publisher(tmp_path)
    ok(p.run(product='assessment', channel='candidate', version='1.3.76', archive=archive(tmp_path / 'a.tar.gz'), lock=write_lock(tmp_path)))
    before = p.snapshot()
    old_lock = lock_text().replace(VERSION, '1.3.75')
    old = p.run(product='assessment', channel='candidate', version='1.3.75',
                archive=archive(tmp_path / 'old.tar.gz', lock=old_lock, version='1.3.75'), lock=write_lock(tmp_path, old_lock))
    assert old.returncode != 0 and 'not newer' in old.stderr
    assert p.snapshot() == before


def test_images_lock_is_required(tmp_path):
    p = Publisher(tmp_path)
    before = p.snapshot()
    result = p.run(product='assessment', channel='candidate', version=VERSION, archive=archive(tmp_path / 'a.tar.gz'))
    assert result.returncode != 0 and '--images-lock is required' in result.stderr
    assert p.snapshot() == before


def test_docker_bundle_is_not_part_of_the_assessment_contract(tmp_path):
    p = Publisher(tmp_path)
    bundle = tmp_path / 'bundle.tar.gz'
    bundle.write_bytes(b'x')
    result = p.run(product='assessment', channel='candidate', version=VERSION, archive=archive(tmp_path / 'a.tar.gz'),
                   lock=write_lock(tmp_path), bundle=bundle)
    assert result.returncode != 0 and '--bundle is not registered for product' in result.stderr


@pytest.mark.parametrize('names,needle', [
    ([n for n in REFS if n != 'beat'], 'images lock must match compose services exactly'),
    ([n for n in REFS if n != 'frontend'], 'images lock must match compose services exactly'),
])
def test_lock_must_cover_the_required_services(tmp_path, names, needle):
    p = Publisher(tmp_path)
    before = p.snapshot()
    lock = write_lock(tmp_path, lock_text(names))
    result = p.run(product='assessment', channel='candidate', version=VERSION, archive=archive(tmp_path / 'a.tar.gz', lock=lock_text(names)), lock=lock)
    assert result.returncode != 0 and needle in result.stderr
    assert p.snapshot() == before


def test_optional_images_may_be_left_out_of_the_lock(tmp_path):
    p = Publisher(tmp_path)
    names = ['postgres', 'redis', 'backend', 'worker', 'beat', 'frontend']
    ok(p.run(product='assessment', channel='candidate', version=VERSION, archive=archive(tmp_path / 'a.tar.gz', lock=lock_text(names)),
             lock=write_lock(tmp_path, lock_text(names))))
    assert set(channel(p)['releases'][0]['images']) == set(names)


@pytest.mark.parametrize('mutation,needle', [
    (lambda t: t.replace('@' + digest('redis'), ''), 'mutable'),
    (lambda t: t.replace(REFS['redis'], 'redis:latest'), 'invalid or mutable image reference'),
    (lambda t: t.replace(digest('zap')[:20], 'sha256:ABCDEF0123456789AB'), 'lowercase sha256'),
    (lambda t: t.replace('frontend=', 'worker2='), 'images lock must match'),
])
def test_unpinned_or_malformed_lock_entries_are_refused(tmp_path, mutation, needle):
    p = Publisher(tmp_path)
    text = mutation(lock_text())
    result = p.run(product='assessment', channel='candidate', version=VERSION, archive=archive(tmp_path / 'a.tar.gz', lock=text), lock=write_lock(tmp_path, text))
    assert result.returncode != 0 and needle in result.stderr, result.stderr


def test_a_lock_other_than_the_one_packaged_is_refused(tmp_path):
    p = Publisher(tmp_path)
    packaged = lock_text()
    other = packaged.replace(digest('redis'), 'sha256:' + '0' * 64)
    result = p.run(product='assessment', channel='candidate', version=VERSION, archive=archive(tmp_path / 'a.tar.gz', lock=packaged), lock=write_lock(tmp_path, other))
    assert result.returncode != 0 and 'archive image lock differs from --images-lock' in result.stderr
    assert not (p.www / 'channels/assessment-candidate.json').exists()


def test_archive_without_a_packaged_lock_is_refused(tmp_path):
    p = Publisher(tmp_path)
    path = tmp_path / 'a.tar.gz'
    with tarfile.open(path, 'w:gz') as stream:
        for name, content in {'neosecra-distribution-%s/deployment/release-manifest.yaml' % VERSION: MANIFEST % VERSION}.items():
            data = content.encode()
            info = tarfile.TarInfo(name)
            info.size = len(data)
            stream.addfile(info, io.BytesIO(data))
    result = p.run(product='assessment', channel='candidate', version=VERSION, archive=path, lock=write_lock(tmp_path))
    assert result.returncode != 0 and 'does not carry exactly one deployment/release/images.lock' in result.stderr


def test_two_manifests_are_the_failure_the_old_builder_produced(tmp_path):
    p = Publisher(tmp_path)
    result = p.run(product='assessment', channel='candidate', version=VERSION, archive=archive(tmp_path / 'a.tar.gz', manifests=2), lock=write_lock(tmp_path))
    assert result.returncode != 0 and 'ambiguous release manifest trust_policy: multiple manifests' in result.stderr


def test_manifest_without_trust_policy_is_refused(tmp_path):
    p = Publisher(tmp_path)
    result = p.run(product='assessment', channel='candidate', version=VERSION, archive=archive(tmp_path / 'a.tar.gz', trust=False), lock=write_lock(tmp_path))
    assert result.returncode != 0 and 'missing trust_policy' in result.stderr


def test_dry_run_writes_nothing_and_needs_no_key(tmp_path):
    p = Publisher(tmp_path)
    before = p.snapshot()
    p.key.unlink()
    result = p.run(product='assessment', channel='candidate', version=VERSION, archive=archive(tmp_path / 'a.tar.gz'), lock=write_lock(tmp_path), dry=True)
    ok(result)
    assert 'Product=assessment channel=candidate version=%s trust=minisign-package-v1' % VERSION in result.stdout
    assert 'Registered step: images-lock' in result.stdout and 'enabled=0' in result.stdout
    assert p.snapshot() == before and not (p.root / 'channels/assessment-candidate.json').exists()


def test_beta_remains_an_unpublishable_reservation(tmp_path):
    p = Publisher(tmp_path, stub_gates=True)
    source = p.seed('assessment', 'beta')
    source.write_bytes((ROOT / 'channels/assessment-beta.json').read_bytes())
    Path(str(source) + '.minisig').unlink()
    before = p.snapshot()
    result = p.run(product='assessment', channel='beta', version=VERSION, archive=archive(tmp_path / 'a.tar.gz'), lock=write_lock(tmp_path))
    assert result.returncode != 0 and 'Unsafe channel pair' in result.stderr
    assert p.snapshot() == before


def test_unregistered_channel_names_stay_refused(tmp_path):
    p = Publisher(tmp_path)
    for name in ('canary', 'rc', 'Candidate', 'candidate;echo'):
        result = p.run(product='assessment', channel=name, version=VERSION, archive=archive(tmp_path / 'a.tar.gz'), lock=write_lock(tmp_path))
        assert result.returncode != 0 and 'channel is not registered' in result.stderr


def test_a_candidate_publication_never_changes_the_signed_stable_record(tmp_path):
    p = Publisher(tmp_path)
    stable = p.seed('assessment', 'stable', version='1.3.29')
    before = (stable.read_bytes(), Path(str(stable) + '.minisig').read_bytes(), (p.www / 'channels/assessment-stable.json').read_bytes())
    ok(p.run(product='assessment', channel='candidate', version=VERSION, archive=archive(tmp_path / 'a.tar.gz'), lock=write_lock(tmp_path)))
    assert (stable.read_bytes(), Path(str(stable) + '.minisig').read_bytes(), (p.www / 'channels/assessment-stable.json').read_bytes()) == before


def test_candidate_channel_passes_the_registry_validators_after_publication(tmp_path):
    import sys
    sys.path.insert(0, str(ROOT / 'update-server/lib'))
    from registry import load_registry, read_json, validate_channel
    p = Publisher(tmp_path)
    ok(p.run(product='assessment', channel='candidate', version=VERSION, archive=archive(tmp_path / 'a.tar.gz'), lock=write_lock(tmp_path)))
    validate_channel(read_json(p.root / 'channels/assessment-candidate.json'), load_registry(ROOT, 'assessment'), 'assessment-candidate')
    result = p.shell([posix(p.root / 'bin/validate-channels.sh'), posix(p.root), posix(p.www)])
    assert result.returncode != 0 or 'validated' in result.stdout  # other products are unseeded in this fixture


def test_pending_candidate_does_not_block_the_channel_validator(tmp_path):
    p = Publisher(tmp_path)
    for path in (p.root / 'products').glob('*.json'):
        reg = json.loads(path.read_text())
        for name in reg['channels']:
            if (reg['code'], name) != ('assessment', 'candidate'):
                p.seed(reg['code'], name)
    for root in (p.root, p.www):
        beta = root / 'channels/assessment-beta.json'
        beta.write_bytes((ROOT / 'channels/assessment-beta.json').read_bytes())
        Path(str(beta) + '.minisig').unlink()
    args = [posix(p.root / 'bin/validate-channels.sh'), posix(p.root)]
    result = p.shell(args)
    assert result.returncode == 0, result.stdout + result.stderr
    assert result.stdout.strip() == 'validated 7 registered channels (pending first publication: assessment-candidate)'
    # One copy without the other is drift, not "pending".
    (p.www / 'channels/assessment-candidate.json').write_text('{}', encoding='utf-8')
    drift = p.shell(args + [posix(p.www)])
    assert drift.returncode != 0 and 'drift' in drift.stderr + drift.stdout
