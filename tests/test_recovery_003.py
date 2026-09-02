import pytest
import subprocess
import json
import os
import tempfile
import time

def test_stale_lock_takeover():
    with tempfile.TemporaryDirectory() as tmpdir:
        lock_file = os.path.join(tmpdir, ".update.lock")
        with open(lock_file, "w") as f:
            json.dump({"pid": 999999, "heartbeat": time.time() - 100, "exec_id": "test-old"}, f)

        res = subprocess.run(["python3", "deployment/v1/upgrade/recovery.py", "lock_acquire", tmpdir], capture_output=True, text=True)
        assert res.returncode == 0
        assert "Stale lock detected" in res.stdout
        assert "test-old" not in res.stdout  # It should output the new exec_id

def test_active_lock_rejected():
    with tempfile.TemporaryDirectory() as tmpdir:
        lock_file = os.path.join(tmpdir, ".update.lock")
        with open(lock_file, "w") as f:
            json.dump({"pid": 999999, "heartbeat": time.time() - 10, "exec_id": "test-active"}, f)

        res = subprocess.run(["python3", "deployment/v1/upgrade/recovery.py", "lock_acquire", tmpdir], capture_output=True, text=True)
        assert res.returncode == 14
        assert "Active update in progress" in res.stderr

def test_interrupted_migrate_policy():
    with tempfile.TemporaryDirectory() as tmpdir:
        journal_file = os.path.join(tmpdir, ".update.journal")
        with open(journal_file, "w") as f:
            json.dump([{"exec_id": "test", "step": "MIGRATE", "status": "STARTED", "target": "1.0.0"}], f)

        res = subprocess.run(["python3", "deployment/v1/upgrade/recovery.py", "check_resume_policy", tmpdir, "1.0.0"], capture_output=True, text=True)
        assert res.returncode == 15
        assert "Interrupted during critical phase" in res.stderr

def test_safe_resume_policy():
    with tempfile.TemporaryDirectory() as tmpdir:
        journal_file = os.path.join(tmpdir, ".update.journal")
        with open(journal_file, "w") as f:
            json.dump([{"exec_id": "test", "step": "PULL_LOAD", "status": "STARTED", "target": "1.0.0"}], f)

        res = subprocess.run(["python3", "deployment/v1/upgrade/recovery.py", "check_resume_policy", tmpdir, "1.0.0"], capture_output=True, text=True)
        assert res.returncode == 0
        assert "Safe to resume from interrupted step" in res.stdout

def test_failed_safe_resume_policy():
    with tempfile.TemporaryDirectory() as tmpdir:
        journal_file = os.path.join(tmpdir, ".update.journal")
        with open(journal_file, "w") as f:
            json.dump([{"exec_id": "test", "step": "CRASH", "status": "FAILED_SAFE", "target": "1.0.0"}], f)

        res = subprocess.run(["python3", "deployment/v1/upgrade/recovery.py", "check_resume_policy", tmpdir, "1.0.0"], capture_output=True, text=True)
        assert res.returncode == 0

def test_double_promotion():
    with tempfile.TemporaryDirectory() as tmpdir:
        state_file = os.path.join(tmpdir, ".release_state.json")
        with open(state_file, "w") as f:
            json.dump({"platform_version": "1.2.3"}, f)

        res = subprocess.run(["python3", "deployment/v1/upgrade/recovery.py", "check_double_promotion", tmpdir, "1.2.3"], capture_output=True, text=True)
        assert res.returncode == 17
        assert "Double promotion rejected" in res.stderr

def test_disk_space_failure():
    with tempfile.TemporaryDirectory() as tmpdir:
        # Require 99999999 MB (unlikely to have 100 TB free in test env)
        res = subprocess.run(["python3", "deployment/v1/upgrade/recovery.py", "check_disk_space", tmpdir, "99999999"], capture_output=True, text=True)
        assert res.returncode == 16
        assert "Insufficient disk space" in res.stderr
