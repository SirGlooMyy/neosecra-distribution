"""Assessment upgrade semantics in the shared runtime.

* the optional DAST overlay is part of every compose invocation of an installation
  that enabled it - and of nobody else's;
* the migration runs with the NEW image before any service is switched, then the
  application services (incl. beat and the DAST services) switch together;
* declarative post-upgrade hooks are idempotent and fail closed;
* the signed image mapping accepts optional (profile) images without loosening the
  exact-match rule for releases that declare none.
"""
import hashlib
import json
import os
import re
import subprocess
import sys
from pathlib import Path

import pytest
import yaml
from fixtures.publisher import BASH, ROOT, posix

V1 = ROOT / 'deployment/v1'
PYTHON = os.environ.get('NEOSECRA_TEST_PYTHON') or sys.executable
LIBS = ('common.sh', 'state.sh', 'manifest.sh', 'docker.sh', 'assessment_upgrade.sh', 'post_upgrade.sh')

FAKE_DOCKER = r'''#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_LOG"
case "$1" in
  info) exit 0 ;;
  inspect)
    ref="${@: -1}"
    safe="${ref//[\/:@]/_}"
    [[ -f "$FAKE_DIR/inspect/$safe" ]] && { cat "$FAKE_DIR/inspect/$safe"; exit 0; }
    exit 1 ;;
  compose)
    case " $* " in
      *" version "*) exit 0 ;;
      *" config --services "*) tr ' ' '\n' <<< "${FAKE_SERVICES:-}"; exit 0 ;;
      *" exec "*) exit "${FAKE_EXEC_RC:-0}" ;;
    esac ;;
esac
exit 0
'''


@pytest.fixture
def harness(tmp_path, monkeypatch):
    if not BASH or not Path(BASH).is_file():
        pytest.skip('Git Bash/bash is unavailable')
    tree = tmp_path / 'tree'
    (tree / 'lib').mkdir(parents=True)
    for name in LIBS:
        (tree / 'lib' / name).write_bytes((V1 / 'lib' / name).read_bytes().replace(b'\r\n', b'\n'))
    for relative in ('upgrade/post_upgrade.py',):
        target = tree / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes((V1 / relative).read_bytes().replace(b'\r\n', b'\n'))
    (tree / 'docker-compose.v1.yml').write_text('services: {}\n', encoding='utf-8')
    (tree / '.env.v1').write_text('POSTGRES_USER=neosecra\n', encoding='utf-8')
    (tree / 'release-manifest.yaml').write_text('version: 1.3.76\n', encoding='utf-8')
    fake = tmp_path / 'fake'
    (fake / 'bin').mkdir(parents=True)
    (fake / 'inspect').mkdir()
    docker = fake / 'bin/docker'
    docker.write_text(FAKE_DOCKER, encoding='utf-8', newline='\n')
    docker.chmod(0o755)
    py = fake / 'bin/python3'
    py.write_text('#!/usr/bin/env bash\nexec "%s" "$@"\n' % posix(PYTHON), encoding='utf-8', newline='\n')
    py.chmod(0o755)
    log = tmp_path / 'docker.log'
    for name in list(os.environ):
        if name.startswith(('NEOSECRA_', 'COMPOSE_', 'FAKE_')):
            monkeypatch.delenv(name, raising=False)

    class Harness:
        def __init__(self):
            self.tree, self.fake, self.log, self.tmp = tree, fake, log, tmp_path
            self.install = tmp_path / 'install'
            (self.install / 'state').mkdir(parents=True)

        def env_file(self, text):
            (self.tree / '.env.v1').write_text(text, encoding='utf-8')

        def overlay(self):
            (self.tree / 'docker-compose.dast.yml').write_text('services: {}\n', encoding='utf-8')

        def inspect(self, ref, output):
            safe = re.sub(r'[/:@]', '_', ref)
            (self.fake / 'inspect' / safe).write_text(output, encoding='utf-8', newline='\n')

        def run(self, body, **extra):
            env = dict(os.environ, FAKE_LOG=posix(self.log), FAKE_DIR=posix(self.fake),
                       NEOSECRA_INSTALL_ROOT=posix(self.install), PYTHONUTF8='1', **extra)
            script = ('set -Eeuo pipefail\nexport PATH="%s:$PATH"\ncd "%s"\n' % (posix(self.fake / 'bin'), posix(self.tree))
                      + ''.join('source lib/%s\n' % name for name in ('common.sh', 'state.sh', 'manifest.sh', 'docker.sh',
                                                                       'assessment_upgrade.sh', 'post_upgrade.sh'))
                      + 'set +e\n' + body)
            return subprocess.run([str(BASH), '-c', script], env=env, capture_output=True, text=True, timeout=120)

        def calls(self):
            return self.log.read_text(encoding='utf-8').splitlines() if self.log.exists() else []

    return Harness()


def compose_calls(harness):
    return [line for line in harness.calls() if line.startswith('compose ')]


# --- DAST overlay in every compose invocation ----------------------------------------

def test_without_the_overlay_file_compose_arguments_are_unchanged(harness):
    harness.env_file('COMPOSE_PROFILES=openvas,dast\n')  # even a "dast" profile: no overlay file, no overlay
    result = harness.run('compose config -q; run_compose up -d backend')
    assert result.returncode == 0, result.stderr
    for line in compose_calls(harness):
        assert 'docker-compose.dast.yml' not in line
        assert line.count(' -f ') == 1


def test_overlay_file_without_the_dast_profile_is_ignored(harness):
    harness.overlay()
    harness.env_file('COMPOSE_PROFILES=openvas\n')
    assert harness.run('compose config -q').returncode == 0
    assert 'docker-compose.dast.yml' not in ' '.join(compose_calls(harness))


@pytest.mark.parametrize('profiles', ['dast', 'openvas,dast', 'dast,openvas', ' openvas , dast '])
def test_enabled_overlay_is_part_of_every_compose_invocation(harness, profiles):
    harness.overlay()
    harness.env_file('COMPOSE_PROFILES=%s\n' % profiles)
    body = ('compose config -q\nrun_compose pull backend\nrun_compose up -d --force-recreate backend worker\n'
            'run_compose ps -q\nrun_compose exec -T postgres pg_isready\nrun_compose stop\n')
    assert harness.run(body).returncode == 0
    calls = compose_calls(harness)
    assert len(calls) == 6
    for line in calls:
        assert line.count(' -f ') == 2 and line.index('docker-compose.v1.yml') < line.index('docker-compose.dast.yml'), line


def test_one_off_run_containers_never_get_the_overlay(harness):
    harness.overlay()
    harness.env_file('COMPOSE_PROFILES=dast\n')
    assert harness.run('run_compose run --rm --no-deps -T backend alembic upgrade head').returncode == 0
    (line,) = compose_calls(harness)
    assert ' run --rm --no-deps -T backend alembic upgrade head' in line
    assert 'docker-compose.dast.yml' not in line


def test_process_environment_profile_wins_like_docker_compose_does(harness):
    harness.overlay()
    harness.env_file('COMPOSE_PROFILES=dast\n')
    assert harness.run('compose config -q', COMPOSE_PROFILES='openvas').returncode == 0
    assert 'docker-compose.dast.yml' not in ' '.join(compose_calls(harness))


def test_compose_args_helper_matches_compose(harness):
    harness.overlay()
    harness.env_file('COMPOSE_PROFILES=dast\n')
    result = harness.run('compose_args; printf "%s\\n" "${COMPOSE_ARGS[@]}"')
    assert result.returncode == 0
    args = result.stdout.splitlines()
    assert args.count('-f') == 2 and args[-1].endswith('docker-compose.dast.yml')


def test_recovery_of_the_previous_release_restores_its_own_overlay(harness):
    previous = harness.install / 'releases/1.3.75'
    previous.mkdir(parents=True)
    (previous / 'docker-compose.v1.yml').write_text('services: {}\n', encoding='utf-8')
    (previous / 'docker-compose.dast.yml').write_text('services: {}\n', encoding='utf-8')
    (previous / '.env.v1').write_text('COMPOSE_PROFILES=openvas,dast\n', encoding='utf-8')
    (harness.install / 'state/installed-version').write_text('1.3.75\n', encoding='utf-8')
    result = harness.run('recover_previous_release')
    assert result.returncode == 0, result.stdout + result.stderr
    (line,) = [c for c in compose_calls(harness) if ' up -d' in c]
    assert 'releases/1.3.75/docker-compose.dast.yml' in line


# --- migration first, then one switch ---------------------------------------------------

def upgrade_text():
    return (V1 / 'upgrade/upgrade.sh').read_text(encoding='utf-8')


def test_migration_runs_with_the_new_image_before_any_service_switch():
    text = upgrade_text()
    order = [text.index(marker) for marker in (
        'prepare_target_release "$TARGET"',        # signed payload verified, current untouched
        'bash "${V1_ROOT}/backup/backup.sh"',      # backup before anything changes
        'pin_channel_image_refs\n',                # digests from the signed channel entry
        'enforce_image_security 1',                # pulled/loaded and digest-checked
        'run_compose up -d postgres redis',
        'run_compose run --rm backend alembic upgrade head',
        'if ! switch_application_services; then',  # the first time an application service is replaced
        'wait_service_healthy backend 120',
        'install/postflight.sh',
        'run_post_upgrade_hooks "$CURRENT" "$TARGET"',
        'write_installed_version "$TARGET"',
        'switch_current "$TARGET"',
    )]
    assert order == sorted(order), order


def test_failed_migration_never_reaches_the_service_switch():
    text = upgrade_text()
    block = text[text.index('MIGRATE_OK=0'):text.index('if ! switch_application_services; then')]
    assert 'attempt_signed_rollback' in block and 'die "Upgrade failed at migration" 13' in block
    assert 'switch_application_services' not in block


def test_failed_fail_policy_hook_rolls_back_like_a_failed_health_check():
    text = upgrade_text()
    block = text[text.index('run_post_upgrade_hooks "$CURRENT" "$TARGET"'):text.index('# --- State ---')]
    assert 'attempt_signed_rollback' in block and 'die "Upgrade failed at a post-upgrade hook" 13' in block


# --- service switch ----------------------------------------------------------------------

def test_assessment_switch_includes_beat_and_the_dast_services(harness):
    harness.overlay()
    harness.env_file('COMPOSE_PROFILES=openvas,dast\n')
    result = harness.run('switch_application_services', FAKE_SERVICES='postgres redis backend worker beat frontend zap dast-egress')
    assert result.returncode == 0, result.stderr
    ups = [c for c in compose_calls(harness) if ' up ' in c]
    assert ups[0].endswith('up -d --force-recreate backend worker beat frontend')
    assert ups[1].endswith('up -d zap dast-egress')
    assert all('docker-compose.dast.yml' in c for c in ups)


def test_assessment_switch_without_dast_touches_no_scanner_service(harness):
    harness.env_file('COMPOSE_PROFILES=openvas\n')
    assert harness.run('switch_application_services', FAKE_SERVICES='postgres redis backend worker beat frontend').returncode == 0
    ups = [c for c in compose_calls(harness) if ' up ' in c]
    assert len(ups) == 1 and ups[0].endswith('up -d --force-recreate backend worker beat frontend')


def test_other_products_keep_the_historic_switch_command(harness):
    harness.overlay()
    harness.env_file('COMPOSE_PROFILES=dast\n')
    assert harness.run('switch_application_services', NEOSECRA_PRODUCT='soc', FAKE_SERVICES='backend worker beat frontend').returncode == 0
    ups = [c for c in compose_calls(harness) if ' up ' in c]
    assert len(ups) == 1 and ups[0].endswith('up -d --force-recreate backend worker frontend')
    assert 'zap' not in ups[0] and 'beat' not in ups[0]


# --- digest lookup ------------------------------------------------------------------------

DIGEST = 'sha256:' + 'a' * 64
OTHER = 'sha256:' + 'b' * 64


def lookup(harness, ref, expected, product='assessment', before=''):
    """Run the digest lookup exactly as upgrade.sh defines it (nested in enforce_image_security)."""
    text = upgrade_text()
    body = text.split('  local_image_digest() {', 1)[1].split(chr(10) + '  }' + chr(10), 1)[0]
    script = 'expected_product=%s%s%slocal_image_digest() {%s%s}%s%s%s local_image_digest %s %s' % (
        product, chr(10), before, body, chr(10), chr(10), '', '', ref, expected)
    return harness.run(script)


def test_digest_check_finds_an_image_that_was_pulled_by_digest(harness):
    # Pulled by digest: the image has no tag, so only "<repo>@<digest>" resolves.
    harness.inspect('registry.neosecra.com/security-health-backend@' + DIGEST,
                    'registry.neosecra.com/security-health-backend@%s' % DIGEST + chr(10))
    result = lookup(harness, 'registry.neosecra.com/security-health-backend:1.3.76', DIGEST)
    assert result.stdout.strip() == DIGEST, result.stderr


def test_digest_check_still_accepts_the_historic_tag_lookup(harness):
    harness.inspect('postgres:15', 'postgres@%s' % DIGEST + chr(10))
    assert lookup(harness, 'postgres:15', DIGEST).stdout.strip() == DIGEST


def test_digest_check_never_accepts_a_different_digest(harness):
    harness.inspect('registry.neosecra.com/x@' + DIGEST, 'registry.neosecra.com/x@%s' % OTHER + chr(10) + 'registry.neosecra.com/x@%s' % OTHER + chr(10))
    result = lookup(harness, 'registry.neosecra.com/x:1.0.0', DIGEST)
    assert result.stdout.strip() != DIGEST
    assert lookup(harness, 'registry.neosecra.com/missing:1', DIGEST).stdout.strip() == ''


def test_other_products_keep_the_by_reference_lookup_only(harness):
    harness.inspect('registry.neosecra.com/security-health-backend@' + DIGEST,
                    'registry.neosecra.com/security-health-backend@%s' % DIGEST + chr(10))
    assert lookup(harness, 'registry.neosecra.com/security-health-backend:1.3.76', DIGEST, product='soc').stdout.strip() == ''


def test_the_lookup_is_self_contained_in_enforce_image_security():
    """Harnesses that extract enforce_image_security (promotion gate tests) must keep working."""
    text = upgrade_text()
    body = text.split('enforce_image_security() {', 1)[1].split(chr(10) + '}' + chr(10), 1)[0]
    assert 'local_image_digest() {' in body and 'expected_product' in body
    assert body.count('local_image_digest "$image_ref" "$expected_digest"') == 2


# --- upgrade-time authentication probe ------------------------------------------------------

def probe_source():
    text = (V1 / 'lib/assessment_upgrade.sh').read_text(encoding='utf-8')
    return text.split("<<'PY' >/dev/null\n", 1)[1].split('\nPY\n', 1)[0]


def run_probe(tmp_path, outcome):
    """Run the embedded probe with a fake settings module and a scripted urlopen."""
    runner = tmp_path / 'probe_runner.py'
    runner.write_text(
        'import sys, types, urllib.error, urllib.request, io\n'
        'settings = types.SimpleNamespace(first_admin_email="a@b", first_admin_password="x")\n'
        'app = types.ModuleType("app"); config = types.ModuleType("app.config"); config.settings = settings\n'
        'sys.modules.update({"app": app, "app.config": config})\n'
        'import ssl\n'
        'ssl.create_default_context = lambda cafile=None: None\n'
        'outcome = %r\n'
        'class Response(io.BytesIO):\n'
        '    def __init__(self, status, body): super().__init__(body); self.status = status\n'
        '    def getcode(self): return self.status\n'
        '    def __enter__(self): return self\n'
        '    def __exit__(self, *a): return False\n'
        'def urlopen(request, timeout=0, context=None):\n'
        '    if outcome == "conn": raise OSError("refused")\n'
        '    if isinstance(outcome, tuple) and outcome[0] == "http": raise urllib.error.HTTPError("u", outcome[1], "m", {}, None)\n'
        '    return Response(*outcome)\n'
        'urllib.request.urlopen = urlopen\n'
        'exec(compile(open(sys.argv[1], encoding="utf-8").read(), "probe", "exec"))\n' % (outcome,), encoding='utf-8')
    source = tmp_path / 'probe.py'
    source.write_text(probe_source(), encoding='utf-8')
    return subprocess.run([PYTHON, str(runner), str(source)], capture_output=True, text=True).returncode


@pytest.mark.parametrize('outcome,expected_ok', [
    ((200, b'{"access_token": "t"}'), True),
    ((200, b'{"otp_required": true}'), True),   # second factor enabled by the operator
    (('http', 401), True),                      # operator changed the initial password
    (('http', 403), True), (('http', 423), True), (('http', 429), True),
    ((200, b'not json'), False),
    (('http', 404), False), (('http', 500), False), (('http', 502), False), (('http', 503), False),
    ('conn', False),
])
def test_upgrade_probe_accepts_policy_answers_and_rejects_a_broken_proxy(tmp_path, outcome, expected_ok):
    assert (run_probe(tmp_path, outcome) == 0) is expected_ok


def test_fresh_install_login_check_stays_strict():
    common = (V1 / 'lib/common.sh').read_text(encoding='utf-8')
    body = common.split('verify_initial_admin_login_via_frontend() {')[1].split('\n}\n')[0]
    assert 'if status != 200' in body and 'access_token' in body


# --- post-upgrade hooks ---------------------------------------------------------------------

MANIFEST = '''version: 1.3.76
post_upgrade:
  - id: compliance-backfill
    since: "1.3.75"
    service: backend
    command: ["python", "-m", "app.modules.compliance.backfill"]
    timeout_seconds: 30
    on_failure: warn
'''


def hook_manifest(harness, text=MANIFEST):
    (harness.tree / 'release-manifest.yaml').write_text(text, encoding='utf-8')


def exec_calls(harness):
    return [c for c in compose_calls(harness) if ' exec ' in c]


def test_hook_runs_once_for_an_upgrade_across_its_version_and_leaves_a_marker(harness):
    hook_manifest(harness)
    first = harness.run('run_post_upgrade_hooks 1.3.74 1.3.76')
    assert first.returncode == 0, first.stdout + first.stderr
    (call,) = exec_calls(harness)
    assert call.endswith('exec -T backend python -m app.modules.compliance.backfill')
    marker = harness.install / 'state/post-upgrade/compliance-backfill.done'
    assert marker.is_file() and json.loads(marker.read_text())['version'] == '1.3.76'
    again = harness.run('run_post_upgrade_hooks 1.3.74 1.3.77')
    assert again.returncode == 0 and len(exec_calls(harness)) == 1


def test_hook_is_skipped_for_an_installation_that_already_ran_its_version(harness):
    hook_manifest(harness)
    assert harness.run('run_post_upgrade_hooks 1.3.75 1.3.76').returncode == 0
    assert exec_calls(harness) == []
    assert not (harness.install / 'state/post-upgrade').exists()


def test_warn_hook_failure_does_not_fail_the_upgrade_and_is_retried(harness):
    hook_manifest(harness)
    failed = harness.run('run_post_upgrade_hooks 1.3.74 1.3.76', FAKE_EXEC_RC='7')
    assert failed.returncode == 0 and 'stays pending' in failed.stderr
    state = harness.install / 'state/post-upgrade'
    assert (state / 'compliance-backfill.failed').is_file() and not (state / 'compliance-backfill.done').exists()
    # Even after the installed version moved past "since", the failed hook is retried.
    retry = harness.run('run_post_upgrade_hooks 1.3.76 1.3.76')
    assert retry.returncode == 0
    assert (state / 'compliance-backfill.done').is_file() and not (state / 'compliance-backfill.failed').exists()
    assert len(exec_calls(harness)) == 2


def test_fail_policy_hook_failure_is_reported_to_the_upgrade(harness):
    hook_manifest(harness, MANIFEST.replace('on_failure: warn', 'on_failure: fail'))
    result = harness.run('run_post_upgrade_hooks 1.3.74 1.3.76', FAKE_EXEC_RC='3')
    assert result.returncode == 1


def test_invalid_hook_manifest_executes_nothing(harness):
    hook_manifest(harness, MANIFEST.replace('["python", "-m", "app.modules.compliance.backfill"]', '"python -m x; rm -rf /"'))
    result = harness.run('run_post_upgrade_hooks 1.3.74 1.3.76')
    assert result.returncode == 2 and exec_calls(harness) == []


def test_post_upgrade_cli_lists_and_retries(harness):
    hook_manifest(harness)
    state = harness.install / 'state/post-upgrade'
    state.mkdir(parents=True)
    (state / 'compliance-backfill.failed').write_text('{}\n', encoding='utf-8')
    for name in ('upgrade/post-upgrade.sh',):
        target = harness.tree / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes((V1 / name).read_bytes().replace(b'\r\n', b'\n'))
    (harness.install / 'state/installed-version').write_text('1.3.76\n', encoding='utf-8')
    env = dict(os.environ, FAKE_LOG=posix(harness.log), FAKE_DIR=posix(harness.fake), NEOSECRA_INSTALL_ROOT=posix(harness.install))

    def cli(*args):
        return subprocess.run([str(BASH), '-c', 'export PATH="%s:$PATH"; exec bash "$@"' % posix(harness.fake / 'bin'), 'x',
                               posix(harness.tree / 'upgrade/post-upgrade.sh'), *args], env=env, capture_output=True, text=True, timeout=120)

    assert 'compliance-backfill\tsince 1.3.75\tfailed' in cli('status').stdout
    assert cli('run').returncode == 0 and len(exec_calls(harness)) == 1
    assert 'done' in cli('status').stdout
    assert cli('run', '--hook', 'compliance-backfill').returncode != 0  # completed hooks are never re-run


# --- manifest contract of the hook helper -----------------------------------------------------

def hooks(tmp_path, text):
    path = tmp_path / 'm.yaml'
    path.write_text(text, encoding='utf-8')
    sys.path.insert(0, str(V1 / 'upgrade'))
    import importlib
    module = importlib.import_module('post_upgrade')
    return module, path


@pytest.mark.parametrize('mutation', [
    lambda h: h.update(id='Bad Id'), lambda h: h.update(id=''), lambda h: h.update(since='latest'),
    lambda h: h.update(service='back end'), lambda h: h.update(command='python -m x'),
    lambda h: h.update(command=[]), lambda h: h.update(command=['python', 3]),
    lambda h: h.update(command=['a' * 300]), lambda h: h.update(command=['x'] * 17),
    lambda h: h.update(timeout_seconds=0), lambda h: h.update(timeout_seconds=99999),
    lambda h: h.update(timeout_seconds=True), lambda h: h.update(on_failure='ignore'),
    lambda h: h.update(unexpected='x'), lambda h: h.pop('service'),
])
def test_hook_helper_rejects_invalid_declarations(tmp_path, mutation):
    data = yaml.safe_load(MANIFEST)
    mutation(data['post_upgrade'][0])
    module, path = hooks(tmp_path, yaml.safe_dump(data))
    with pytest.raises(module.HookError):
        module.load_hooks(path)


def test_hook_helper_rejects_duplicates_and_non_lists(tmp_path):
    data = yaml.safe_load(MANIFEST)
    data['post_upgrade'].append(dict(data['post_upgrade'][0]))
    module, path = hooks(tmp_path, yaml.safe_dump(data))
    with pytest.raises(module.HookError):
        module.load_hooks(path)
    module, path = hooks(tmp_path, 'post_upgrade: {id: x}\n')
    with pytest.raises(module.HookError):
        module.load_hooks(path)
    module, path = hooks(tmp_path, 'version: 1.0.0\n')
    assert module.load_hooks(path) == []


def test_hook_plan_semantics(tmp_path):
    module, path = hooks(tmp_path, MANIFEST)
    state = tmp_path / 'state'
    assert [h['id'] for h in module.pending(path, state, '1.3.74')] == ['compliance-backfill']
    assert module.pending(path, state, '1.3.75') == [] and module.pending(path, state, '1.3.99') == []
    assert [h['id'] for h in module.pending(path, state, 'none')] == ['compliance-backfill']
    module.mark_failed(state, 'compliance-backfill', '1.3.76')
    assert [h['id'] for h in module.pending(path, state, '1.3.99')] == ['compliance-backfill']
    module.mark_done(state, 'compliance-backfill', '1.3.76')
    assert module.pending(path, state, '1.3.74') == []
    with pytest.raises(module.HookError):
        module.pending(path, state, '1.3.74', only='compliance-backfill')
    with pytest.raises(module.HookError):
        module.marker_path(state, '../escape')


# --- signed image mapping ---------------------------------------------------------------------

def mapping(tmp_path, images, services, target='1.3.76', expected_channel='assessment-candidate'):
    release = {'version': target, 'archive': {'sha256': 'c' * 64}, 'images': images}
    channel = {'channel': expected_channel, 'product': 'assessment', 'product_code': 'assessment', 'edition': 'standard',
               'status': 'available', 'current_version': target, 'releases': [release]}
    compose = {'services': {name: {'image': ref} for name, ref in services.items()}}
    env = dict(os.environ, CHANNEL_JSON=json.dumps(channel), TARGET=target, EXPECTED_CHANNEL=expected_channel,
               EXPECTED_PRODUCT='assessment', LEGACY_ALLOWLIST=str(V1 / 'upgrade/legacy_allowlist.json'))
    return subprocess.run([PYTHON, str(V1 / 'upgrade/verify_mapping.py')], input=json.dumps(compose), env=env, capture_output=True, text=True)


def entry(name, optional=None, repo=None):
    repo = repo or name
    value = {'reference': repo + ':1', 'digest': 'sha256:' + hashlib.sha256(name.encode()).hexdigest()}
    if optional is not None:
        value['optional'] = optional
    return value


def pinned(images, name):
    return images[name]['reference'] + '@' + images[name]['digest']


def test_optional_images_may_be_absent_from_compose_but_not_unmapped_services(tmp_path):
    images = {'backend': entry('backend'), 'frontend': entry('frontend'), 'zap': entry('zap', True)}
    base = {n: pinned(images, n) for n in ('backend', 'frontend')}
    ok = mapping(tmp_path, images, base)
    assert ok.returncode == 0, ok.stderr
    assert 'ENFORCE backend' in ok.stdout and 'zap' not in ok.stdout  # absent: pinned in the env, not enforced
    enabled = mapping(tmp_path, images, dict(base, zap=pinned(images, 'zap')))
    assert enabled.returncode == 0 and 'ENFORCE zap' in enabled.stdout
    unmapped = mapping(tmp_path, images, dict(base, sidecar='x:1@sha256:' + 'd' * 64))
    assert unmapped.returncode != 0 and 'do not exactly match' in unmapped.stderr


def test_required_images_still_have_to_match_exactly(tmp_path):
    images = {'backend': entry('backend'), 'frontend': entry('frontend'), 'zap': entry('zap', True)}
    missing = mapping(tmp_path, images, {'backend': pinned(images, 'backend')})
    assert missing.returncode != 0 and 'do not exactly match' in missing.stderr


def test_a_release_without_optional_entries_keeps_the_exact_match_rule(tmp_path):
    images = {'backend': entry('backend'), 'frontend': entry('frontend'), 'zap': entry('zap')}
    result = mapping(tmp_path, images, {n: pinned(images, n) for n in ('backend', 'frontend')})
    assert result.returncode != 0 and 'do not exactly match' in result.stderr


def test_optional_must_be_literal_true(tmp_path):
    images = {'backend': entry('backend'), 'zap': entry('zap', 'yes')}
    result = mapping(tmp_path, images, {'backend': pinned(images, 'backend')})
    assert result.returncode != 0


def test_optional_entries_are_validated_even_when_unused(tmp_path):
    images = {'backend': entry('backend'), 'zap': dict(entry('zap', True), digest='sha256:short')}
    result = mapping(tmp_path, images, {'backend': pinned(images, 'backend')})
    assert result.returncode != 0 and 'immutable sha256 digest' in result.stderr
    images = {'backend': entry('backend'), 'zap': dict(entry('zap', True), reference='zap:latest')}
    assert mapping(tmp_path, images, {'backend': pinned(images, 'backend')}).returncode != 0


def test_candidate_document_is_not_accepted_for_a_stable_installation(tmp_path):
    images = {'backend': entry('backend')}
    result = mapping(tmp_path, images, {'backend': pinned(images, 'backend')}, expected_channel='assessment-stable')
    # The document says assessment-stable (matches); a candidate document under a stable binding must fail.
    assert result.returncode == 0
    channel_json = json.dumps({'channel': 'assessment-candidate', 'product': 'assessment', 'edition': 'standard', 'status': 'available',
                               'current_version': '1.3.76', 'releases': [{'version': '1.3.76', 'archive': {'sha256': 'c' * 64}, 'images': images}]})
    env = dict(os.environ, CHANNEL_JSON=channel_json, TARGET='1.3.76', EXPECTED_CHANNEL='assessment-stable', EXPECTED_PRODUCT='assessment',
               LEGACY_ALLOWLIST=str(V1 / 'upgrade/legacy_allowlist.json'))
    denied = subprocess.run([PYTHON, str(V1 / 'upgrade/verify_mapping.py')], input=json.dumps({'services': {'backend': {'image': pinned(images, 'backend')}}}),
                            env=env, capture_output=True, text=True)
    assert denied.returncode != 0 and 'Channel binding mismatch' in denied.stderr
