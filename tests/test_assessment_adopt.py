"""adopt-release.sh: record the release that is really running, without touching containers."""
import hashlib
import json
import os
import re
import subprocess
import sys
from pathlib import Path

import pytest
from fixtures.publisher import BASH, FIXTURES, ROOT, posix

from test_assessment_package import MANIFEST, write

PYTHON = os.environ.get('NEOSECRA_TEST_PYTHON') or sys.executable
V1 = ROOT / 'deployment/v1'
RUNNING = '1.3.75'
DB_HEAD = '002_second'
SECRET = 'S3cretValue-DoNotPrint-9f2c1ab7'
PACKAGE_VERSION = RUNNING

FAKE_DOCKER = r'''#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_LOG"
case "$1" in
  info) exit 0 ;;
  ps)
    service=""
    for arg in "$@"; do case "$arg" in label=com.docker.compose.service=*) service="${arg#label=com.docker.compose.service=}" ;; esac; done
    [[ -f "$FAKE_DIR/containers/$service" ]] && cat "$FAKE_DIR/containers/$service"
    exit 0 ;;
  inspect) cat "$FAKE_DIR/images/${@: -1}"; exit 0 ;;
  exec) cat "$FAKE_DIR/db_revision"; exit 0 ;;
esac
exit 0
'''
FAKE_MINISIGN = '#!/usr/bin/env bash\nexit "${FAKE_MINISIGN_RC:-0}"\n'
LN_SHIM = r'''#!/usr/bin/env bash
# Windows test shim: "ln -s[fn] <target> <link>" as an NTFS junction (no symlink privilege needed).
case "$1" in
  -s|-sf|-sfn)
    target="$2"
    [[ "$target" == /* ]] && target="$(cygpath -w "$target")"
    exec "@PYTHON@" "@JUNCTION@" "$1" "$target" "$(cygpath -w "$3")" ;;
  *) exec /usr/bin/ln "$@" ;;
esac
'''


def lock_for(version):
    refs = {
        'postgres': 'postgres:15', 'redis': 'redis:7-alpine',
        'backend': 'registry.neosecra.com/security-health-backend:' + version,
        'worker': 'registry.neosecra.com/security-health-backend:' + version,
        'beat': 'registry.neosecra.com/security-health-backend:' + version,
        'frontend': 'registry.neosecra.com/security-health-frontend:' + version,
        'openvas': 'immauss/openvas:26.07.12.01', 'zap': 'ghcr.io/zaproxy/zaproxy:2.17.0',
        'dast-egress': 'registry.neosecra.com/neosecra-dast-egress:4',
    }
    shared = hashlib.sha256(b'backend-image').hexdigest()
    return ''.join('%s=%s@sha256:%s\n' % (name, ref, shared if name in ('backend', 'worker', 'beat') else hashlib.sha256(name.encode()).hexdigest())
                   for name, ref in refs.items())


def build_package(tmp_path, version=PACKAGE_VERSION):
    product = tmp_path / 'assessment'
    v1 = product / 'deployment/v1'
    write(v1 / 'docker-compose.v1.yml', 'name: neosecra-assessment\nservices: {}\n')
    write(v1 / 'docker-compose.dast.yml', 'services: {}\n')
    write(v1 / '.env.v1.example', 'POSTGRES_USER=neosecra\n')
    write(v1 / 'release-manifest.yaml', MANIFEST)
    write(v1 / 'VERSION', version + '\n')
    write(v1 / 'config/nginx/security-health.conf', 'server {}\n')
    for name in ('zap-start.sh', 'log4j2.xml', 'install-firewall.sh'):
        write(product / 'deployment/dast' / name, '#!/bin/sh\n')
    write(product / 'backend/alembic/versions/001_first.py', 'revision = "001_first"\ndown_revision = None\n')
    write(product / 'backend/alembic/versions/002_second.py', 'revision = "002_second"\ndown_revision = "001_first"\n')
    lock = tmp_path / 'images.lock'
    lock.write_text(lock_for(version), encoding='utf-8', newline='\n')
    archive = tmp_path / ('distribution-%s.tar.gz' % version)
    result = subprocess.run([PYTHON, str(ROOT / 'update-server/lib/assessment_package.py'), 'build', '--version', version,
                             '--product-root', str(product), '--shared-root', str(ROOT), '--images-lock', str(lock),
                             '--output', str(archive), '--release-date', '2026-10-05T12:00:00Z'], capture_output=True, text=True)
    assert result.returncode == 0, result.stdout + result.stderr
    Path(str(archive) + '.minisig').write_text('fixture signature\n', encoding='utf-8')
    return archive


def env_text(extra=''):
    return '\n'.join([
        'POSTGRES_USER=neosecra', 'POSTGRES_PASSWORD=' + SECRET, 'POSTGRES_DB=neosecra_assessment',
        'DATABASE_URL=postgresql://neosecra:%s@postgres:5432/neosecra_assessment' % SECRET, 'REDIS_URL=redis://redis:6379/0',
        'SECRET_KEY=k-' + SECRET, 'OTP_SECRET=o-' + SECRET, 'FIRST_ADMIN_EMAIL=admin@neosecra.com',
        'FIRST_ADMIN_PASSWORD=Ab1!' + SECRET, 'ADMIN_RECOVERY_KEY=r-' + SECRET, 'BACKEND_CORS_ORIGINS=https://x.example',
        'COMPOSE_PROFILES=openvas', 'NEOSECRA_VERSION=1.3.55', extra, ''])


class World:
    def __init__(self, tmp_path):
        self.tmp = tmp_path
        self.install = tmp_path / 'install'
        self.fake = tmp_path / 'fake'
        self.bin = self.fake / 'bin'
        self.log = tmp_path / 'docker.log'
        (self.fake / 'containers').mkdir(parents=True)
        (self.fake / 'images').mkdir()
        self.bin.mkdir()
        for name, text in (('docker', FAKE_DOCKER), ('minisign', FAKE_MINISIGN)):
            (self.bin / name).write_text(text, encoding='utf-8', newline='\n')
            (self.bin / name).chmod(0o755)
        if os.name == 'nt':
            (self.bin / 'ln').write_text(LN_SHIM.replace('@PYTHON@', posix(PYTHON)).replace('@JUNCTION@', posix(FIXTURES / 'ln_junction.py')), encoding='utf-8', newline='\n')
            (self.bin / 'ln').chmod(0o755)
            shim = FIXTURES / 'pyshim.py'
            (self.bin / 'python3').write_text('#!/usr/bin/env bash\nexec "%s" "%s" "$@"\n' % (posix(PYTHON), posix(shim)), encoding='utf-8', newline='\n')
        else:
            (self.bin / 'python3').write_text('#!/usr/bin/env bash\nexec "%s" "$@"\n' % PYTHON, encoding='utf-8', newline='\n')
        (self.bin / 'python3').chmod(0o755)
        self.old = self.install / 'releases/1.3.55'
        write(self.old / '.env.v1', env_text())
        write(self.old / 'config/tls/server.crt', 'tls material\n')
        write(self.old / 'VERSION', '1.3.55\n')
        write(self.install / 'state/installed-version', '1.3.55\n')
        write(self.install / 'state/active-release', '1.3.55\n')
        self.older = self.install / 'releases/1.3.52'
        write(self.older / 'VERSION', '1.3.52\n')
        self.link(self.older, self.install / 'previous')
        self.link(self.old, self.install / 'current')
        self.running(backend='registry.neosecra.com/security-health-backend:' + RUNNING, db=DB_HEAD)
        self.package = build_package(tmp_path)

    def link(self, target, link):
        subprocess.run([str(BASH), '-c', 'export PATH="%s:$PATH"; ln -s "$1" "$2"' % posix(self.bin), 'x', posix(target), posix(link)], check=True)

    def running(self, backend=None, db=None, services=None):
        backend = backend or 'registry.neosecra.com/security-health-backend:' + RUNNING
        containers = {'backend': 'cid-backend', 'worker': 'cid-worker', 'beat': 'cid-beat', 'frontend': 'cid-frontend',
                      'postgres': 'cid-postgres', 'redis': 'cid-redis'}
        refs = {'backend': backend, 'worker': backend, 'beat': backend,
                'frontend': 'registry.neosecra.com/security-health-frontend:' + RUNNING, 'postgres': 'postgres:15', 'redis': 'redis:7-alpine'}
        for service, cid in {**containers, **(services or {})}.items():
            (self.fake / 'containers' / service).write_text(cid + '\n', encoding='utf-8', newline='\n')
        for service, cid in containers.items():
            (self.fake / 'images' / cid).write_text(refs[service] + '\n', encoding='utf-8', newline='\n')
        if db is not None:
            (self.fake / 'db_revision').write_text(db + '\n', encoding='utf-8', newline='\n')

    def add_container(self, service, cid, ref):
        (self.fake / 'containers' / service).write_text(cid + '\n', encoding='utf-8', newline='\n')
        (self.fake / 'images' / cid).write_text(ref + '\n', encoding='utf-8', newline='\n')

    def run(self, *args, root=False, **extra):
        env = dict(os.environ, FAKE_LOG=posix(self.log), FAKE_DIR=posix(self.fake), NEOSECRA_INSTALL_ROOT=posix(self.install),
                   PYTHONUTF8='1', **extra)
        if not root:
            env['NEOSECRA_ADOPT_ALLOW_NONROOT'] = '1'
        for name in list(env):
            if name.startswith(('COMPOSE_', 'UPGRADE_')):
                env.pop(name)
        script = posix(V1 / 'upgrade/adopt-release.sh')
        return subprocess.run([str(BASH), '-c', 'export PATH="%s:$PATH"; exec bash "$@"' % posix(self.bin), 'x', script, *map(str, args)],
                              env=env, capture_output=True, text=True, timeout=180)

    def adopt(self, *extra, **env):
        return self.run('--archive', posix(self.package), '--version', RUNNING, *extra, **env)

    def state(self):
        read = lambda path: path.read_text().strip() if path.exists() else None
        return {
            'installed': read(self.install / 'state/installed-version'), 'active': read(self.install / 'state/active-release'),
            'current': os.path.realpath(self.install / 'current'), 'previous': os.path.realpath(self.install / 'previous'),
            'releases': sorted(p.name for p in (self.install / 'releases').iterdir()),
        }


@pytest.fixture
def world(tmp_path, monkeypatch):
    if not BASH or not Path(BASH).is_file():
        pytest.skip('Git Bash/bash is unavailable')
    if os.name != 'nt':
        probe = tmp_path / 'probe'
        try:
            (tmp_path / 'target').mkdir()
            probe.symlink_to(tmp_path / 'target')
        except OSError:
            pytest.skip('symbolic links are unavailable')
    for name in list(os.environ):
        if name.startswith(('NEOSECRA_', 'FAKE_')):
            monkeypatch.delenv(name, raising=False)
    return World(tmp_path)


def test_dry_run_verifies_everything_and_changes_nothing(world):
    before = world.state()
    result = world.adopt('--dry-run')
    assert result.returncode == 0, result.stdout + result.stderr
    assert 'Dry-run complete' in result.stdout + result.stderr
    assert world.state() == before
    assert not (world.install / 'state/adopt').exists()


def test_adoption_records_the_running_release_and_keeps_secrets_private(world):
    result = world.adopt()
    assert result.returncode == 0, result.stdout + result.stderr
    assert SECRET not in result.stdout + result.stderr
    new = world.install / 'releases' / RUNNING
    assert new.is_dir()
    state = world.state()
    assert state['installed'] == RUNNING and state['active'] == RUNNING
    assert Path(state['current']).name == RUNNING and Path(state['previous']).name == '1.3.55'
    assert (new / 'VERSION').read_text().strip() == RUNNING
    assert (new / '.env.v1.example').is_file() and not (new / 'env.v1.example').exists()
    assert (new / 'release/images.lock').is_file() and (new / 'docker-compose.v1.yml').is_file()
    assert (new / 'v1').exists()  # bridge for current/v1/agent/update-agent.sh
    assert (new / 'agent/update-agent.sh').is_file() and (new / 'config/tls/server.crt').read_text() == 'tls material\n'
    env = (new / '.env.v1').read_text()
    assert 'POSTGRES_PASSWORD=' + SECRET in env and 'NEOSECRA_VERSION=' + RUNNING in env  # carried, not regenerated
    assert 'BACKEND_IMAGE=registry.neosecra.com/security-health-backend:' + RUNNING in env  # what runs, exactly
    assert 'POSTGRES_IMAGE=postgres:15' in env and 'REDIS_IMAGE=redis:7-alpine' in env
    assert re.search(r'(?m)^OPENVAS_IMAGE=immauss/openvas:26\.07\.12\.01@sha256:[0-9a-f]{64}$', env)  # not running: from the signed lock
    assert 'COMPOSE_PROFILES=openvas\n' in env and 'dast' not in re.search(r'(?m)^COMPOSE_PROFILES=.*$', env).group(0)
    # Scanner images are pinned from the signed lock even while the profile is off.
    assert re.search(r'(?m)^ZAP_IMAGE=ghcr\.io/zaproxy/zaproxy:2\.17\.0@sha256:[0-9a-f]{64}$', env)
    if os.name != 'nt':
        assert (new / '.env.v1').stat().st_mode & 0o777 == 0o600
    record = json.loads(next((world.install / 'state/adopt').glob('*.json')).read_text())
    assert record['applied'] is True and record['previous_installed_version'] == '1.3.55'
    # The old release tree and the running stack are untouched.
    assert (world.old / '.env.v1').read_text() == env_text()
    assert not [c for c in world.log.read_text().splitlines() if c.split()[0] in ('up', 'compose', 'stop', 'restart', 'rm', 'run', 'pull')]


def test_the_package_must_be_the_running_version(world):
    world.running(backend='registry.neosecra.com/security-health-backend:1.3.74')
    before = world.state()
    result = world.adopt()
    assert result.returncode != 0 and 'not version ' + RUNNING in result.stderr + result.stdout
    assert world.state() == before


def test_database_schema_must_match_the_package(world):
    world.running(db='001_first')
    before = world.state()
    result = world.adopt()
    assert result.returncode != 0 and 'false state' in result.stderr + result.stdout
    assert world.state() == before


def test_bad_signature_stops_before_anything_is_extracted(world):
    before = world.state()
    result = world.adopt(FAKE_MINISIGN_RC='1')
    assert result.returncode != 0 and 'signature verification FAILED' in result.stderr + result.stdout
    assert world.state() == before


def test_sha256_must_match_the_signed_channel_value(world):
    good = hashlib.sha256(world.package.read_bytes()).hexdigest()
    assert world.adopt('--sha256', '0' * 64, '--dry-run').returncode != 0
    assert world.adopt('--sha256', good, '--dry-run').returncode == 0


def test_an_existing_release_tree_is_never_overwritten(world):
    (world.install / 'releases' / RUNNING).mkdir()
    result = world.adopt()
    assert result.returncode != 0 and 'never overwrites' in result.stderr + result.stdout


def test_a_current_that_is_not_a_symlink_is_refused(world):
    current = world.install / 'current'
    if os.name == 'nt':
        subprocess.run(['cmd.exe', '/c', 'rmdir', str(current)], check=True)
    else:
        current.unlink()
    current.mkdir()
    result = world.adopt('--dry-run')
    assert result.returncode != 0 and 'is not a symlink' in result.stderr + result.stdout


def test_an_environment_that_would_fail_the_next_upgrade_is_refused_early(world):
    (world.old / '.env.v1').write_text(env_text().replace('POSTGRES_PASSWORD=' + SECRET, 'POSTGRES_PASSWORD='), encoding='utf-8')
    before = world.state()
    result = world.adopt()
    assert result.returncode != 0 and 'POSTGRES_PASSWORD is EMPTY' in result.stderr + result.stdout
    assert world.state() == before and not [n for n in before['releases'] if n.startswith('.staging')]


def test_default_ports_are_made_explicit_only_when_missing(world):
    result = world.adopt()
    assert result.returncode == 0
    env = (world.install / 'releases' / RUNNING / '.env.v1').read_text()
    for line in ('POSTGRES_PORT=25433', 'BACKEND_PORT=25800', 'FRONTEND_PORT=25300', 'NEOSECRA_EDITION=security_health'):
        assert line in env


def test_two_different_environment_files_are_never_guessed_between(world):
    write(world.old / '.env', env_text('EXTRA=1'))
    before = world.state()
    refused = world.adopt('--dry-run')
    assert refused.returncode != 0 and 'both .env.v1 and .env and they differ' in refused.stderr + refused.stdout
    assert world.state() == before
    chosen = world.adopt('--env-file', posix(world.old / '.env'), '--dry-run')
    assert chosen.returncode == 0, chosen.stdout + chosen.stderr


def test_identical_environment_files_and_a_lone_dot_env_are_fine(world):
    write(world.old / '.env', env_text())
    assert world.adopt('--dry-run').returncode == 0
    (world.old / '.env.v1').unlink()
    assert world.adopt('--dry-run').returncode == 0


def test_candidate_channel_binding(world):
    assert world.adopt('--channel', 'assessment-candidate').returncode == 0
    env = (world.install / 'releases' / RUNNING / '.env.v1').read_text()
    assert 'UPGRADE_CHANNEL_URL=https://update.neosecra.com/channels/assessment-candidate.json' in env
    assert 'UPGRADE_RELEASE_CHANNEL=assessment-candidate' in env


def test_unknown_channel_is_refused(world):
    assert world.adopt('--channel', 'assessment-canary', '--dry-run').returncode != 0


def test_running_dast_scanner_enables_the_profile_and_pins_its_images(world, tmp_path):
    key = tmp_path / 'secrets/dast_api_key'
    key.parent.mkdir()
    key.write_text('not-a-real-key\n', encoding='utf-8')
    (world.old / '.env.v1').write_text(env_text('DAST_API_KEY_FILE=%s\nDAST_ZAP_API_KEY=%s' % (posix(key), SECRET)), encoding='utf-8')
    world.add_container('zap', 'cid-zap', 'ghcr.io/zaproxy/zaproxy:2.17.0')
    world.add_container('dast-egress', 'cid-egress', 'neosecra-dast-egress:4')
    result = world.adopt()
    assert result.returncode == 0, result.stdout + result.stderr
    env = (world.install / 'releases' / RUNNING / '.env.v1').read_text()
    assert 'COMPOSE_PROFILES=openvas,dast' in env
    assert 'ZAP_IMAGE=ghcr.io/zaproxy/zaproxy:2.17.0' in env and 'DAST_EGRESS_IMAGE=neosecra-dast-egress:4' in env
    assert SECRET not in result.stdout + result.stderr


def test_dast_key_file_inside_home_is_refused_because_the_agent_cannot_read_it(world):
    (world.old / '.env.v1').write_text(env_text('DAST_API_KEY_FILE=/home/neosecra/dast/secret/dast_api_key'), encoding='utf-8')
    world.add_container('zap', 'cid-zap', 'ghcr.io/zaproxy/zaproxy:2.17.0')
    result = world.adopt()
    assert result.returncode != 0
    assert 'DAST_API_KEY_FILE' in result.stderr + result.stdout


def test_enable_dast_needs_an_existing_key_file(world):
    result = world.adopt('--enable-dast')
    assert result.returncode != 0 and 'DAST_API_KEY_FILE' in result.stderr + result.stdout


def test_hooks_that_were_applied_by_hand_can_be_marked(world):
    assert world.adopt('--mark-hooks-done', 'compliance-backfill').returncode == 0
    marker = world.install / 'state/post-upgrade/compliance-backfill.done'
    assert marker.is_file() and json.loads(marker.read_text())['version'] == RUNNING


def test_revert_restores_pointers_state_and_moves_the_adopted_tree_aside(world):
    before = world.state()
    assert world.adopt().returncode == 0 and world.state() != before
    result = world.run('--revert')
    assert result.returncode == 0, result.stdout + result.stderr
    after = world.state()
    assert {k: after[k] for k in ('installed', 'active', 'current', 'previous')} == {k: before[k] for k in ('installed', 'active', 'current', 'previous')}
    assert RUNNING not in after['releases'] and any(n.startswith('.adopt-reverted-' + RUNNING) for n in after['releases'])
    again = world.run('--revert')
    assert again.returncode != 0 and 'No adoption record' in again.stderr + again.stdout


def test_revert_refuses_when_current_moved_on(world):
    assert world.adopt().returncode == 0
    other = world.install / 'releases/1.3.80'
    write(other / 'VERSION', '1.3.80\n')
    subprocess.run([str(BASH), '-c', 'export PATH="%s:$PATH"; ln -s "$1" "$2.new" && mv -Tf "$2.new" "$2"' % posix(world.bin), 'x', posix(other), posix(world.install / 'current')], check=True)
    result = world.run('--revert')
    assert result.returncode != 0 and 'no longer points at the adopted tree' in result.stderr + result.stdout


def test_adoption_needs_root_unless_the_test_override_is_set(world):
    result = world.run('--archive', posix(world.package), '--version', RUNNING, '--dry-run', root=True)
    if os.geteuid() == 0 if hasattr(os, 'geteuid') else False:
        pytest.skip('running as root')
    assert result.returncode != 0 and 'must run as root' in result.stderr + result.stdout


def test_adoption_refuses_while_an_upgrade_lock_exists(world):
    (world.install / 'state/.install.lock').mkdir()
    result = world.adopt('--dry-run')
    assert result.returncode != 0 and 'lock is held' in result.stderr + result.stdout


def test_the_adopted_tree_can_be_used_by_the_agent_layout(world):
    assert world.adopt().returncode == 0
    new = world.install / 'releases' / RUNNING
    # Files the agent, upgrade.sh and rollback.sh source from current/v1/...
    for relative in ('lib/common.sh', 'lib/state.sh', 'lib/assessment_upgrade.sh', 'lib/post_upgrade.sh', 'upgrade/upgrade.sh',
                     'upgrade/rollback.sh', 'upgrade/post_upgrade.py', 'agent/update-agent.sh', 'agent/artifact-verifier.sh',
                     'install/preflight.sh', 'install/postflight.sh', 'backup/backup.sh', 'ca/update-neosecra-com.pub'):
        assert (new / 'v1' / relative).is_file(), relative
