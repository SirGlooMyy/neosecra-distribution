"""The Assessment candidate work must not change how Hotspot, SOC or Pish are built, published or upgraded.

Everything Assessment-specific is additive and guarded by product; the files that only the other
products use are byte-identical to the committed ones, and the shared code paths they exercise keep
their behaviour (their own contract suites run unchanged next to this file).
"""
import hashlib
import json
import subprocess
import sys
from pathlib import Path

import pytest
from fixtures.publisher import ROOT

sys.path.insert(0, str(ROOT / 'update-server/lib'))
from registry import images, load_registry  # noqa: E402

# Files that belong to Hotspot, SOC or Pish (or to their publication) and were not part of this work.
OTHER_PRODUCT_FILES = [
    'products/hotspot.json', 'products/soc.json', 'products/pish.json',
    'channels/hotspot-candidate.json', 'channels/hotspot-candidate.json.minisig',
    'channels/hotspot-stable.json', 'channels/hotspot-stable.json.minisig',
    'channels/soc-beta.json', 'channels/soc-beta.json.minisig', 'channels/soc-stable.json',
    'channels/soc-stable.json.minisig', 'channels/pish-stable.json', 'channels/pish-stable.json.minisig',
    'channels/assessment-stable.json', 'channels/assessment-stable.json.minisig', 'channels/assessment-beta.json',
    'update-server/bootstrap-hotspot.sh', 'update-server/soc-bundle-lock.py',
    'update-server/lib/steps/bundle-lock.sh', 'update-server/lib/steps/migration-contract.sh',
    'update-server/lib/bundle_lock.py', 'update-server/lib/cosign_gate.py', 'update-server/lib/migration.py',
    'update-server/lib/activate.py', 'update-server/lib/remote.py', 'update-server/lib/verify.py', 'update-server/lib/archive.py',
    'update-server/publish.sh', 'ci/prerelease-gate.sh', 'ci/prerelease-gate-hotspot.sh', 'ci/prerelease-gate-soc.sh',
    'deployment/v1/agent/hotspot-updater.sh', 'deployment/v1/agent/install-hotspot-agent.sh',
    'deployment/v1/agent/install-agent.sh', 'deployment/v1/agent/artifact-verifier.sh',
    'deployment/v1/upgrade/rollback.sh', 'deployment/v1/upgrade/recovery.py', 'deployment/v1/upgrade/secure_extract.py',
    'deployment/v1/upgrade/verify_rollback_auth.py', 'deployment/v1/upgrade/verify_platform_manifest.py',
    'deployment/v1/upgrade/legacy_allowlist.json',
]


def committed(path):
    try:
        result = subprocess.run(['git', '-C', str(ROOT), 'show', 'HEAD:' + path], capture_output=True, check=False)
    except OSError:
        return None
    return result.stdout if result.returncode == 0 else None


@pytest.mark.parametrize('path', OTHER_PRODUCT_FILES)
def test_file_of_another_product_is_byte_identical_to_the_committed_one(path):
    expected = committed(path)
    if expected is None:
        pytest.skip('not a git checkout or not tracked')
    actual = (ROOT / path).read_bytes()
    assert actual.replace(b'\r\n', b'\n') == expected.replace(b'\r\n', b'\n'), path


def test_update_agent_scrubs_the_same_pin_names_before_upgrade_and_rollback():
    """The agent drops stale image pins inherited from the unit's environment file before it calls
    upgrade.sh/rollback.sh; Assessment's three pin names are part of that list in both places.
    (Checked against the file itself, so the test holds before and after the change is committed.)"""
    lf, crlf = chr(10).encode(), (chr(13) + chr(10)).encode()
    text = (ROOT / 'deployment/v1/agent/update-agent.sh').read_bytes().replace(crlf, lf)
    scrub = (b'unset NEOSECRA_VERSION BACKEND_IMAGE WORKER_IMAGE FRONTEND_IMAGE POSTGRES_IMAGE REDIS_IMAGE '
             b'OPENVAS_IMAGE BEAT_IMAGE ZAP_IMAGE DAST_EGRESS_IMAGE' + lf)
    assert text.count(scrub) == 2
    assert text.count(b'BEAT_IMAGE') == 2 and text.count(b'DAST_EGRESS_IMAGE') == 2


def test_other_products_registry_contracts_are_unchanged():
    for code, channels in (('hotspot', ['candidate', 'stable']), ('soc', ['beta', 'stable']), ('pish', ['stable'])):
        reg = load_registry(ROOT, code)
        assert reg['channels'] == channels
        for key in ('optional_services', 'archive_path'):
            assert key not in reg['images_lock']
        assert 'pending_channels' not in reg
    assert 'images-lock' not in load_registry(ROOT, 'soc')['steps']
    assert load_registry(ROOT, 'soc')['steps'] == ['bundle-lock']


def test_soc_image_lock_rows_keep_their_exact_shape(tmp_path):
    reg = load_registry(ROOT, 'soc')
    digest = lambda name: 'sha256:' + hashlib.sha256(name.encode()).hexdigest()
    names = reg['images_lock']['services']
    shared = digest('backend')
    lock = tmp_path / 'soc.lock'
    group = ('backend', 'worker', 'beat')
    lock.write_text(''.join('%s=registry.neosecra.com/soc-%s:1.0.0@%s\n' % (n, 'backend' if n in group else n, shared if n in group else digest(n)) for n in names), encoding='utf-8')
    rows = images(lock, reg)
    assert set(rows) == set(names)
    assert all(set(row) == {'reference', 'digest'} for row in rows.values())  # no "optional" flag outside Assessment


def test_soc_lock_with_an_extra_service_is_still_refused(tmp_path):
    reg = load_registry(ROOT, 'soc')
    names = reg['images_lock']['services'] + ['zap']
    lock = tmp_path / 'soc.lock'
    lock.write_text(''.join('%s=r/%s:1@sha256:%s\n' % (n, n, format(i + 1, '064x')) for i, n in enumerate(names)), encoding='utf-8')
    with pytest.raises(ValueError, match='images lock must match compose services exactly'):
        images(lock, reg)


def test_assessment_changes_are_visible_only_in_assessment_records():
    assert load_registry(ROOT, 'assessment')['images_lock']['optional_services'] == ['openvas', 'zap', 'dast-egress']
    gate = {code: json.loads((ROOT / 'products' / (code + '.json')).read_text())['gate'] for code in ('hotspot', 'soc', 'pish', 'assessment')}
    assert gate['assessment']['channels'] == ['stable']
