"""Agent policy/trigger dispatch with local command doubles, no live services."""

import json

import pytest
import yaml

from test_rollback_policy_behavior import manifest, sandbox, shell_path, write


def agent_rollback(box, payload, product="assessment", real_rollback=False):
    agent = box.tree / "agent/update-agent.sh"
    source = agent.read_text(encoding="utf-8")
    assert source.endswith('main "$@"\n')
    # Only suppress the daemon entry point; execute its actual rollback function.
    write(agent, source.removesuffix('main "$@"\n'))
    if not real_rollback:
        write(box.tree / "upgrade/rollback.sh", '''#!/usr/bin/env bash
printf 'rollback:%s\n' "$*" >> "$TEST_COMMAND_LOG"
exit 0
''')
    trigger = box.root / "rollback-request.json"
    write(trigger, json.dumps(payload))
    script = '''
set +e
source "$1"
agent_acquire_lock() { return 0; }
sync_upgrade_journals() { return 0; }
write_agent_status() { printf 'status:%s\n' "$*" >> "$TEST_COMMAND_LOG"; }
run_hotspot_rollback() { printf 'hotspot:%s\n' "$*" >> "$TEST_COMMAND_LOG"; }
RUNTIME_PRODUCT_CODE="$3"
process_rollback_request "$2"
'''
    result = box.run_shell(script, shell_path(agent), shell_path(trigger), product)
    assert not trigger.exists(), result.stdout + result.stderr
    return result


def trigger(box):
    return {"target_version": "1.0.0", "auth_path": shell_path(box.auth),
            "nonce": "fixture-rollback-nonce-1234", "product": "assessment",
            "channel": "assessment-stable", "edition": "standard"}


@pytest.mark.parametrize("policy", ["backup_restore", "none", "legacy"])
def test_agent_selects_same_policy_as_rollback(sandbox, policy):
    sandbox.set_policy(policy)
    result = agent_rollback(sandbox, trigger(sandbox))
    assert result.returncode == 0, result.stdout + result.stderr
    calls = sandbox.calls()
    dispatch = next(line for line in calls.splitlines() if line.startswith("rollback:"))
    assert ("--pointer-only" in dispatch) == (policy == "none")
    assert "--from-backup" not in dispatch
    assert "--auth " in dispatch
    assert "status:ROLLBACK_COMPLETED 1.0.0 0" in calls


def test_agent_rejects_product_backup_path(sandbox):
    sandbox.set_policy("backup_restore")
    payload = trigger(sandbox)
    payload["backup_path"] = shell_path(sandbox.backup)
    result = agent_rollback(sandbox, payload)
    assert result.returncode == 1
    log = sandbox.install / "state/logs/update-agent.log"
    assert "Products cannot supply backup_path" in log.read_text(encoding="utf-8")
    assert "status:ROLLBACK_REJECTED 1.0.0 12" in sandbox.calls()
    assert "rollback:" not in sandbox.calls()


@pytest.mark.parametrize("invalid", ["absent", "missing", "relative", "traversal"])
def test_agent_missing_or_unsafe_auth_is_auth_failed(sandbox, invalid):
    payload = trigger(sandbox)
    if invalid == "absent":
        del payload["auth_path"]
    elif invalid == "missing":
        sandbox.auth.unlink()
    elif invalid == "relative":
        payload["auth_path"] = "auth.json"
    else:
        payload["auth_path"] = shell_path(sandbox.root) + "/../auth.json"
    result = agent_rollback(sandbox, payload)
    assert result.returncode == 1
    assert "status:AUTH_FAILED 1.0.0 4" in sandbox.calls()
    assert "rollback:" not in sandbox.calls()


@pytest.mark.parametrize("invalid", ["missing", "malformed", "inconsistent", "unsupported"])
def test_agent_policy_failures_do_not_dispatch_rollback(sandbox, invalid):
    path = sandbox.tree / "release-manifest.yaml"
    if invalid == "missing":
        path.unlink()
    elif invalid == "malformed":
        write(path, "upgrade: [")
    else:
        data = manifest("none")
        if invalid == "inconsistent":
            data["upgrade"]["backup_required"] = True
        else:
            data["rollback"]["database_strategy"] = "unsupported"
        write(path, yaml.safe_dump(data))
    result = agent_rollback(sandbox, trigger(sandbox))
    assert result.returncode == 12
    assert "status:ROLLBACK_FAILED 1.0.0 12" in sandbox.calls()
    assert "rollback:" not in sandbox.calls()


def test_hotspot_dispatch_is_unchanged_and_does_not_read_generic_policy(sandbox):
    sandbox.tree.joinpath("release-manifest.yaml").unlink()
    result = agent_rollback(sandbox, trigger(sandbox), product="hotspot")
    assert result.returncode == 0, result.stdout + result.stderr
    calls = sandbox.calls()
    assert "hotspot:1.0.0 " + shell_path(sandbox.auth) in calls
    assert "rollback:" not in calls
    assert "status:ROLLBACK_COMPLETED 1.0.0 0" in calls


@pytest.mark.parametrize("policy", ["backup_restore", "none"])
def test_agent_to_real_rollback_completes_with_matching_policy(sandbox, policy):
    if policy == "backup_restore":
        sandbox.encrypted_backup()
    else:
        sandbox.set_policy(policy)
    sandbox.complete_postflight()
    result = agent_rollback(sandbox, trigger(sandbox), real_rollback=True)
    assert result.returncode == 0, result.stdout + result.stderr
    calls = sandbox.calls()
    assert "status:ROLLBACK_COMPLETED 1.0.0 0" in calls
    assert ("backup:--target" in calls) == (policy == "backup_restore")
    assert (" psql " in calls) == (policy == "backup_restore")
    assert (sandbox.install / "state/installed-version").read_text() == "1.0.0\n"
