#!/usr/bin/env python3
"""Idempotent post-upgrade hooks declared in the (signed) release manifest.

A release manifest may carry::

    post_upgrade:
      - id: compliance-backfill
        since: "1.3.75"
        service: backend
        command: ["python", "-m", "app.modules.compliance.backfill"]
        timeout_seconds: 1800
        on_failure: warn          # or: fail

Semantics
* A hook is *pending* when the installation was running a version OLDER than
  ``since`` before this upgrade and its marker ``<state>/post-upgrade/<id>.done``
  does not exist yet.  An installation that already ran ``since`` or later has
  had the step applied as part of its own upgrade to ``since``.
* The command runs inside the named compose service (never on the host and never
  through a shell), after the new services are healthy.
* The marker is written only after the command succeeded.  A failure writes
  ``<id>.failed`` instead, which keeps the hook pending until it succeeds: it is
  retried by the next upgrade or by ``upgrade/post-upgrade.sh run``.

The manifest is authenticated by the signed archive; it is still validated
strictly because it drives a command execution.  PyYAML is required: an
installation that cannot parse the manifest refuses to guess.
"""
from __future__ import annotations

import json
import os
import re
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

ID_RE = re.compile(r'^[a-z0-9][a-z0-9._-]{0,63}$')
SERVICE_RE = re.compile(r'^[a-z0-9][a-z0-9_-]{0,127}$')
SEMVER_RE = re.compile(r'^([0-9]+)\.([0-9]+)\.([0-9]+)(?:-[0-9A-Za-z.-]+)?$')
ALLOWED_KEYS = {'id', 'description', 'since', 'service', 'command', 'timeout_seconds', 'on_failure'}
REQUIRED_KEYS = {'id', 'since', 'service', 'command', 'timeout_seconds', 'on_failure'}
MAX_ARGS = 16
MAX_ARG_LENGTH = 256
MAX_TIMEOUT = 7200
NEWLINE = chr(10)
CARRIAGE_RETURN = chr(13)
NUL = chr(0)


class HookError(ValueError):
    pass


def _version(value: object, label: str) -> tuple[int, int, int]:
    match = SEMVER_RE.fullmatch(str(value or '').strip().lstrip('vV'))
    if not match:
        raise HookError(f'{label} is not a version: {value!r}')
    return tuple(int(part) for part in match.groups())  # type: ignore[return-value]


def load_hooks(manifest_path: str | Path) -> list[dict]:
    path = Path(manifest_path)
    if path.is_symlink() or not path.is_file():
        raise HookError('release manifest is missing or unsafe')
    try:
        import yaml
    except ImportError as exc:
        raise HookError('PyYAML is required to read post-upgrade hooks') from exc
    data = yaml.safe_load(path.read_text(encoding='utf-8'))
    if not isinstance(data, dict):
        raise HookError('release manifest is not a mapping')
    hooks = data.get('post_upgrade')
    if hooks is None:
        return []
    if not isinstance(hooks, list):
        raise HookError('post_upgrade must be a list')
    seen: set[str] = set()
    result = []
    for index, hook in enumerate(hooks):
        label = f'post_upgrade[{index}]'
        if not isinstance(hook, dict):
            raise HookError(f'{label} must be a mapping')
        unknown = set(hook) - ALLOWED_KEYS
        missing = REQUIRED_KEYS - set(hook)
        if unknown:
            raise HookError(f'{label} has unknown keys: {", ".join(sorted(map(str, unknown)))}')
        if missing:
            raise HookError(f'{label} is missing keys: {", ".join(sorted(missing))}')
        hook_id = hook['id']
        if not isinstance(hook_id, str) or not ID_RE.fullmatch(hook_id) or hook_id in seen:
            raise HookError(f'{label} has an invalid or duplicate id')
        seen.add(hook_id)
        _version(hook['since'], f'{label}.since')
        service = hook['service']
        if not isinstance(service, str) or not SERVICE_RE.fullmatch(service):
            raise HookError(f'{label}.service is invalid')
        command = hook['command']
        if (not isinstance(command, list) or not command or len(command) > MAX_ARGS
                or any(not isinstance(item, str) or not item or len(item) > MAX_ARG_LENGTH
                       or NUL in item or NEWLINE in item or CARRIAGE_RETURN in item for item in command)):
            raise HookError(f'{label}.command must be a short list of plain strings')
        timeout = hook['timeout_seconds']
        if isinstance(timeout, bool) or not isinstance(timeout, int) or not 1 <= timeout <= MAX_TIMEOUT:
            raise HookError(f'{label}.timeout_seconds must be an integer from 1 to {MAX_TIMEOUT}')
        if hook['on_failure'] not in ('warn', 'fail'):
            raise HookError(f'{label}.on_failure must be warn or fail')
        result.append({key: hook[key] for key in hook if key in ALLOWED_KEYS})
    return result


def marker_path(state_dir: str | Path, hook_id: str) -> Path:
    if not ID_RE.fullmatch(hook_id):
        raise HookError('invalid hook id')
    return Path(state_dir) / 'post-upgrade' / (hook_id + '.done')


def failed_path(state_dir: str | Path, hook_id: str) -> Path:
    return marker_path(state_dir, hook_id).with_suffix('.failed')


def is_done(state_dir: str | Path, hook_id: str) -> bool:
    return marker_path(state_dir, hook_id).is_file()


def pending(manifest_path, state_dir, current_version, only: str | None = None) -> list[dict]:
    """Hooks to run for an upgrade that starts from ``current_version``.

    ``only`` names one hook to run regardless of ``since`` (manual retry); a hook
    that already completed is never selected.
    """
    try:
        current = _version(current_version, 'current version')
    except HookError:
        current = (0, 0, 0)  # unknown origin: run the (idempotent) hook
    chosen = []
    for hook in load_hooks(manifest_path):
        if is_done(state_dir, hook['id']):
            continue
        if only is not None:
            if hook['id'] == only:
                chosen.append(hook)
        elif current < _version(hook['since'], 'since') or failed_path(state_dir, hook['id']).is_file():
            chosen.append(hook)
    if only is not None and not chosen:
        raise HookError('hook is unknown or already completed: ' + only)
    return chosen


def _write_record(path: Path, record: dict) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    handle, temporary = tempfile.mkstemp(dir=path.parent, prefix='.tmp-')
    try:
        with os.fdopen(handle, 'w', encoding='utf-8') as stream:
            stream.write(json.dumps(record) + NEWLINE)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temporary, 0o600)
        os.replace(temporary, path)
    except BaseException:
        try:
            os.unlink(temporary)
        except OSError:
            pass
        raise
    return path


def _now() -> str:
    return datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')


def mark_done(state_dir, hook_id: str, version: str) -> Path:
    path = _write_record(marker_path(state_dir, hook_id),
                         {'id': hook_id, 'version': version, 'completed_at': _now()})
    try:
        failed_path(state_dir, hook_id).unlink()
    except FileNotFoundError:
        pass
    return path


def mark_failed(state_dir, hook_id: str, version: str) -> Path:
    return _write_record(failed_path(state_dir, hook_id),
                         {'id': hook_id, 'version': version, 'failed_at': _now()})


def main(argv: list[str]) -> int:
    usage = ('usage: post_upgrade.py validate <manifest> | plan <manifest> <state_dir> <current_version> [hook_id] | '
             'argv <manifest> <hook_id> | mark <state_dir> <hook_id> <version> | '
             'mark-failed <state_dir> <hook_id> <version> | status <manifest> <state_dir>')
    if len(argv) < 2:
        print(usage, file=sys.stderr)
        return 2
    command, args = argv[1], argv[2:]
    try:
        if command == 'validate' and len(args) == 1:
            print(f'{len(load_hooks(args[0]))} hook(s) valid')
        elif command == 'plan' and len(args) in (3, 4):
            for hook in pending(*args):
                print('\t'.join([hook['id'], hook['service'], str(hook['timeout_seconds']), hook['on_failure']]))
        elif command == 'argv' and len(args) == 2:
            hook = next((item for item in load_hooks(args[0]) if item['id'] == args[1]), None)
            if hook is None:
                raise HookError('unknown hook id')
            sys.stdout.write(''.join(item + NUL for item in hook['command']))
        elif command == 'mark' and len(args) == 3:
            print(mark_done(*args))
        elif command == 'mark-failed' and len(args) == 3:
            print(mark_failed(*args))
        elif command == 'status' and len(args) == 2:
            for hook in load_hooks(args[0]):
                if is_done(args[1], hook['id']):
                    state = 'done'
                elif failed_path(args[1], hook['id']).is_file():
                    state = 'failed'
                else:
                    state = 'pending'
                print(f"{hook['id']}\tsince {hook['since']}\t{state}")
        else:
            print(usage, file=sys.stderr)
            return 2
    except (HookError, OSError) as exc:
        print(f'post-upgrade hooks: {exc}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
