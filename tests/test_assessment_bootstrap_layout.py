"""Fresh installs (bootstrap.sh) accept the assembled Assessment package and follow the chosen channel."""
import json
import os
import re
import subprocess
import sys
from pathlib import Path

import pytest
from fixtures.publisher import BASH, ROOT, posix

from test_assessment_adopt import build_package

PYTHON = os.environ.get('NEOSECRA_TEST_PYTHON') or sys.executable
BOOTSTRAP = (ROOT / 'bootstrap.sh').read_text(encoding='utf-8')


def heredoc(name):
    return BOOTSTRAP.split("<<'%s'\n" % name, 1)[1].split('\n%s\n' % name, 1)[0]


def test_bootstrap_archive_preflight_accepts_the_package(tmp_path):
    archive = build_package(tmp_path)
    script = tmp_path / 'extract.py'
    script.write_text(heredoc('EXTRACT_PY'), encoding='utf-8')
    destination = tmp_path / 'extract'
    result = subprocess.run([PYTHON, str(script), str(archive), str(destination), '1.3.75'], capture_output=True, text=True)
    assert result.returncode == 0, result.stdout + result.stderr
    deployment = next(destination.glob('neosecra-distribution-*')) / 'deployment'
    assert (deployment / 'env.v1.example').is_file() and (deployment / 'agent/update-agent.sh').is_file()


def test_the_old_whole_repository_archive_layout_was_not_extractable(tmp_path):
    """Why the template ships as env.v1.example: dot-files are refused by both extractors."""
    import io
    import tarfile
    archive = tmp_path / 'dotfile.tar.gz'
    with tarfile.open(archive, 'w:gz') as stream:
        for name in ('neosecra-distribution-1.3.75/deployment/VERSION', 'neosecra-distribution-1.3.75/deployment/.env.v1.example'):
            info = tarfile.TarInfo(name)
            info.size = 2
            stream.addfile(info, io.BytesIO(b'x\n'))
    script = tmp_path / 'extract.py'
    script.write_text(heredoc('EXTRACT_PY'), encoding='utf-8')
    result = subprocess.run([PYTHON, str(script), str(archive), str(tmp_path / 'out'), '1.3.75'], capture_output=True, text=True)
    assert result.returncode != 0 and 'unsafe archive member path' in result.stderr


def channel_json(name):
    return json.dumps({
        'channel': name, 'product': 'assessment', 'product_code': 'assessment', 'edition': 'standard', 'status': 'available',
        'current_version': '1.3.76',
        'releases': [{'version': '1.3.76', 'archive': {'url': 'https://update.neosecra.com/releases/1.3.76/distribution-1.3.76.tar.gz',
                                                       'sha256': 'a' * 64, 'signature_url': 'x'}}]})


def run_identity(tmp_path, document, expected):
    script = tmp_path / 'channel.py'
    script.write_text(heredoc('CHANNEL_PY'), encoding='utf-8')
    source = tmp_path / 'channel.json'
    source.write_text(document, encoding='utf-8')
    base = tmp_path / 'base'
    base.mkdir(exist_ok=True)
    env = dict(os.environ)
    env.pop('NEOSECRA_EXPECTED_CHANNEL', None)
    if expected is not None:
        env['NEOSECRA_EXPECTED_CHANNEL'] = expected
    return subprocess.run([PYTHON, str(script), str(source), str(base), '', str(tmp_path / 'fields'), ''], env=env, capture_output=True, text=True)


@pytest.mark.parametrize('document,expected,accepted', [
    ('assessment-stable', None, True),                      # historic default
    ('assessment-stable', 'assessment-stable', True),
    ('assessment-candidate', 'assessment-candidate', True),
    ('assessment-candidate', None, False),                  # a stable bootstrap never takes a candidate document
    ('assessment-candidate', 'assessment-stable', False),
    ('assessment-stable', 'assessment-candidate', False),
])
def test_channel_identity_is_bound_to_the_expected_channel(tmp_path, document, expected, accepted):
    result = run_identity(tmp_path, channel_json(document), expected)
    assert (result.returncode == 0) is accepted, result.stderr
    if not accepted:
        assert 'Channel identity mismatch' in result.stderr


def test_expected_channel_derivation_in_bootstrap():
    block = BOOTSTRAP.split('EXPECTED_CHANNEL="${NEOSECRA_EXPECTED_CHANNEL:-}"', 1)[1].split('if [[ -n "${LOCAL_MANIFEST:-}" ]]', 1)[0]
    assert 'assessment-candidate.json) EXPECTED_CHANNEL="assessment-candidate"' in block
    assert '*) EXPECTED_CHANNEL="assessment-stable"' in block  # any other URL keeps the historic stable identity
    assert 'Unsupported channel' in block


def test_stable_install_keeps_the_historic_env_lines_and_candidate_adds_the_binding():
    block = BOOTSTRAP.split('UPGRADE_CHANNEL_LINES=(', 1)[1].split('printf', 1)[0]
    assert 'channels/${EXPECTED_CHANNEL}.json' in block
    assert 'if [[ "$EXPECTED_CHANNEL" != "assessment-stable" ]]' in block and 'UPGRADE_RELEASE_CHANNEL=${EXPECTED_CHANNEL}' in block


def test_flat_package_gets_the_v1_bridge_and_the_env_template_name():
    assert 'mv -- "${RELEASE_DIR}/env.v1.example" "${RELEASE_DIR}/.env.v1.example"' in BOOTSTRAP
    assert 'ln -sfn . "${RELEASE_DIR}/v1"' in BOOTSTRAP
    assert '[[ -f "${RELEASE_DIR}/agent/update-agent.sh" && ! -e "${RELEASE_DIR}/v1" ]]' in BOOTSTRAP


@pytest.mark.skipif(not BASH or not Path(BASH).is_file(), reason='Git Bash/bash is unavailable')
def test_bootstrap_still_parses():
    result = subprocess.run([str(BASH), '-n', posix(ROOT / 'bootstrap.sh')], capture_output=True, text=True)
    assert result.returncode == 0, result.stderr
