"""make-images-lock.sh writes digests only from real images and never invents one."""
import hashlib
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

import pytest
from fixtures.publisher import BASH, ROOT, posix

PYTHON = os.environ.get('NEOSECRA_TEST_PYTHON') or sys.executable
VERSION = '1.3.76'
TEMPLATE = '''# template
postgres=postgres:15
redis=redis:7-alpine
backend=registry.neosecra.com/security-health-backend:@VERSION@
worker=registry.neosecra.com/security-health-backend:@VERSION@
beat=registry.neosecra.com/security-health-backend:@VERSION@
frontend=registry.neosecra.com/security-health-frontend:@VERSION@
openvas=immauss/openvas:26.07.12.01
zap=ghcr.io/zaproxy/zaproxy:2.17.0
dast-egress=registry.neosecra.com/neosecra-dast-egress:4
'''
REFS = [line.split('=', 1) for line in TEMPLATE.replace('@VERSION@', VERSION).splitlines() if line and not line.startswith('#')]

FAKE_DOCKER = r'''#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_LOG"
safe() { local s="${1//\//_}"; s="${s//:/_}"; printf '%s' "${s//@/_}"; }
case "$1 $2" in
  "image inspect") ref="${@: -1}"; [[ -f "$FAKE_DIR/digests/$(safe "$ref")" ]] && { cat "$FAKE_DIR/digests/$(safe "$ref")"; exit 0; }; exit 1 ;;
  "manifest inspect") [[ -f "$FAKE_DIR/registry/$(safe "$3")" ]] && exit 0; exit 1 ;;
esac
if [[ "$1" == pull ]]; then
  [[ -f "$FAKE_DIR/pullable/$(safe "$2")" ]] || exit 1
  cp "$FAKE_DIR/pullable/$(safe "$2")" "$FAKE_DIR/digests/$(safe "$2")"; exit 0
fi
exit 0
'''


def digest(name):
    shared = 'backend' if name in ('backend', 'worker', 'beat') else name
    return 'sha256:' + hashlib.sha256(shared.encode()).hexdigest()


def repo_of(ref):
    return ref.rsplit(':', 1)[0] if ':' in ref.rsplit('/', 1)[-1] else ref


class Lab:
    def __init__(self, tmp):
        if not BASH or not Path(BASH).is_file():
            pytest.skip('Git Bash/bash is unavailable')
        self.tmp = tmp
        self.repo = tmp / 'repo'
        for relative in ('update-server/lib', 'products', 'schemas', 'ci'):
            shutil.copytree(ROOT / relative, self.repo / relative, ignore=shutil.ignore_patterns('__pycache__'))
        for relative in ('bootstrap.sh', 'update-server/bootstrap-hotspot.sh'):
            shutil.copyfile(ROOT / relative, self.repo / relative)
        script = self.repo / 'update-server/make-images-lock.sh'
        script.write_bytes((ROOT / 'update-server/make-images-lock.sh').read_bytes().replace(b'\r\n', b'\n'))
        self.fake = tmp / 'fake'
        for sub in ('bin', 'digests', 'pullable', 'registry'):
            (self.fake / sub).mkdir(parents=True)
        (self.fake / 'bin/docker').write_text(FAKE_DOCKER, encoding='utf-8', newline='\n')
        (self.fake / 'bin/docker').chmod(0o755)
        (self.fake / 'bin/python3').write_text('#!/usr/bin/env bash\nexec "%s" "$@"\n' % posix(PYTHON), encoding='utf-8', newline='\n')
        (self.fake / 'bin/python3').chmod(0o755)
        self.template = tmp / 'images.lock.template'
        self.template.write_text(TEMPLATE, encoding='utf-8', newline='\n')
        self.output = tmp / 'out/images.lock'
        self.output.parent.mkdir()
        self.log = tmp / 'docker.log'

    @staticmethod
    def safe(ref):
        return re.sub(r'[/:@]', '_', ref)

    def local(self, name, ref, form=None):
        """The image exists locally with a repository digest (as after push or pull)."""
        entry = form or (repo_of(ref) + '@' + digest(name))
        (self.fake / 'digests' / self.safe(ref)).write_text(entry + '\n', encoding='utf-8', newline='\n')
        (self.fake / 'registry' / self.safe(repo_of(ref) + '@' + digest(name))).write_text('ok', encoding='utf-8')

    def everything_local(self):
        for name, ref in REFS:
            self.local(name, ref)

    def run(self, *args, template=None):
        command = [posix(self.repo / 'update-server/make-images-lock.sh'), '--product', 'assessment', '--version', VERSION,
                   '--template', posix(template or self.template), '--output', posix(self.output), *args]
        env = dict(os.environ, FAKE_LOG=posix(self.log), FAKE_DIR=posix(self.fake), PYTHONUTF8='1')
        return subprocess.run([str(BASH), '-c', 'export PATH="%s:$PATH"; exec bash "$@"' % posix(self.fake / 'bin'), 'x', *command],
                              env=env, capture_output=True, text=True, timeout=120)

    def calls(self):
        return self.log.read_text().splitlines() if self.log.exists() else []


@pytest.fixture
def lab(tmp_path):
    return Lab(tmp_path)


def lines(lab):
    return [line for line in lab.output.read_text().splitlines() if line and not line.startswith('#')]


def test_digests_are_the_repository_digests_of_the_real_images(lab):
    lab.everything_local()
    result = lab.run('--no-pull')
    assert result.returncode == 0, result.stdout + result.stderr
    assert lines(lab) == ['%s=%s@%s' % (name, ref, digest(name)) for name, ref in REFS]
    assert 'accepted by the publisher validation: 9 images' in result.stderr
    assert not any(c.startswith('pull ') for c in lab.calls())


def test_the_result_is_accepted_by_the_publishers_own_parser(lab):
    lab.everything_local()
    assert lab.run('--no-pull').returncode == 0
    sys.path.insert(0, str(ROOT / 'update-server/lib'))
    from registry import images, load_registry
    rows = images(lab.output, load_registry(ROOT, 'assessment'))
    assert rows['zap']['optional'] is True and 'optional' not in rows['backend']
    assert rows['backend']['digest'] == rows['worker']['digest'] == rows['beat']['digest']


def test_first_party_image_without_a_digest_stops_the_script_and_is_never_pulled(lab):
    lab.everything_local()
    (lab.fake / 'digests' / lab.safe('registry.neosecra.com/security-health-frontend:' + VERSION)).unlink()
    result = lab.run()
    assert result.returncode != 0 and 'has no repository digest on this machine' in result.stderr
    assert 'docker push registry.neosecra.com/security-health-frontend:' + VERSION in result.stderr
    assert not lab.output.exists()
    assert not any(c.startswith('pull registry.neosecra.com') for c in lab.calls())


def test_a_locally_built_image_that_was_never_pushed_has_no_digest(lab):
    lab.everything_local()
    (lab.fake / 'digests' / lab.safe('registry.neosecra.com/security-health-backend:' + VERSION)).write_text('\n', encoding='utf-8')
    result = lab.run()
    assert result.returncode != 0 and 'has no repository digest' in result.stderr and not lab.output.exists()


def test_a_digest_of_another_repository_is_not_accepted(lab):
    lab.everything_local()
    (lab.fake / 'digests' / lab.safe('registry.neosecra.com/security-health-backend:' + VERSION)).write_text(
        'registry.neosecra.com/other-image@' + digest('x') + '\n', encoding='utf-8')
    assert lab.run().returncode != 0 and not lab.output.exists()


def test_missing_public_images_are_pulled_but_only_public_ones(lab):
    lab.everything_local()
    for name, ref in REFS:
        if name in ('postgres', 'zap'):
            (lab.fake / 'digests' / lab.safe(ref)).unlink()
            (lab.fake / 'pullable' / lab.safe(ref)).write_text(repo_of(ref) + '@' + digest(name) + '\n', encoding='utf-8')
    result = lab.run()
    assert result.returncode == 0, result.stdout + result.stderr
    pulls = [c for c in lab.calls() if c.startswith('pull ')]
    assert sorted(pulls) == ['pull ghcr.io/zaproxy/zaproxy:2.17.0', 'pull postgres:15']
    assert dict(line.split('=', 1) for line in lines(lab))['postgres'] == 'postgres:15@' + digest('postgres')


def test_no_pull_refuses_to_reach_the_network(lab):
    lab.everything_local()
    (lab.fake / 'digests' / lab.safe('redis:7-alpine')).unlink()
    result = lab.run('--no-pull')
    assert result.returncode != 0 and 'not present locally' in result.stderr
    assert not any(c.startswith('pull ') for c in lab.calls())


@pytest.mark.parametrize('form', ['docker.io/library/postgres@%s', 'index.docker.io/library/postgres@%s', 'postgres@%s'])
def test_docker_hub_repository_digest_spellings(lab, form):
    lab.everything_local()
    lab.local('postgres', 'postgres:15', form=form % digest('postgres'))
    assert lab.run('--no-pull').returncode == 0
    assert dict(line.split('=', 1) for line in lines(lab))['postgres'] == 'postgres:15@' + digest('postgres')


def test_verify_registry_asks_the_registry_for_every_digest(lab):
    lab.everything_local()
    ok = lab.run('--no-pull', '--verify-registry')
    assert ok.returncode == 0, ok.stderr
    assert len([c for c in lab.calls() if c.startswith('manifest inspect')]) == 9
    lab.output.unlink()
    (lab.fake / 'registry' / lab.safe('registry.neosecra.com/security-health-backend@' + digest('backend'))).unlink()
    denied = lab.run('--no-pull', '--verify-registry')
    assert denied.returncode != 0 and 'does not confirm' in denied.stderr and not lab.output.exists()


def test_existing_output_is_never_overwritten(lab):
    lab.everything_local()
    lab.output.write_text('keep\n', encoding='utf-8')
    result = lab.run('--no-pull')
    assert result.returncode != 0 and 'refusing to overwrite' in result.stderr
    assert lab.output.read_text() == 'keep\n'


@pytest.mark.parametrize('line', [
    'zap=ghcr.io/zaproxy/zaproxy:2.17.0@sha256:' + '0' * 64,   # a digest must never be typed into the template
    'zap=ghcr.io/zaproxy/zaproxy:latest',
    'zap=GHCR.io/zaproxy/zaproxy:2.17.0',
    'zap',
])
def test_template_lines_must_be_plain_lowercase_tag_references(lab, line):
    lab.everything_local()
    bad = lab.tmp / 'bad.template'
    bad.write_text(TEMPLATE.replace('zap=ghcr.io/zaproxy/zaproxy:2.17.0', line), encoding='utf-8', newline='\n')
    result = lab.run('--no-pull', template=bad)
    assert result.returncode != 0 and not lab.output.exists()


def test_incomplete_template_is_rejected_by_the_publisher_validation(lab):
    lab.everything_local()
    short = lab.tmp / 'short.template'
    short.write_text(TEMPLATE.replace('beat=registry.neosecra.com/security-health-backend:@VERSION@\n', ''), encoding='utf-8', newline='\n')
    result = lab.run('--no-pull', template=short)
    assert result.returncode != 0 and 'rejected by the publisher validation' in result.stderr and not lab.output.exists()


def test_the_real_assessment_template_names_what_the_compose_files_need():
    template = ROOT.parent / 'neosecra-assessment/.worktrees/rel-chan/deployment/v1/release/images.lock.template'
    root = os.environ.get('NEOSECRA_ASSESSMENT_ROOT')
    if root:
        template = Path(root) / 'deployment/v1/release/images.lock.template'
    if not template.is_file():
        pytest.skip('Assessment checkout not available')
    names = [l.split('=', 1)[0] for l in template.read_text(encoding='utf-8').splitlines() if l and not l.startswith('#')]
    assert names == [name for name, _ in REFS]
