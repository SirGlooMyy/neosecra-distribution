#!/usr/bin/env python3
"""Crash-safe, owner-scoped state helpers for the V1 updater.

The updater is a privileged process.  Lock, journal, and monotonic-state
failures therefore fail closed: a caller never gets to guess that a malformed
file is safe, and a child process cannot heartbeat or release another run's
lock.
"""

from __future__ import annotations

import contextlib
import fcntl
import json
import math
import os
import re
import shutil
import sys
import tempfile
import time
import uuid
from pathlib import Path
from typing import Any, Iterator, NoReturn


LOCK_STALE_SECONDS = 60.0
SAFE_TOKEN = re.compile(r"^[A-Za-z0-9._:-]{1,128}$")
VALID_STEPS = {"START", "PULL_LOAD", "MIGRATE", "PROMOTE", "CRASH"}
VALID_STATUSES = {"STARTED", "COMPLETED", "FAILED_SAFE"}


def die(message: str, code: int = 4) -> NoReturn:
    print(f"RECOVERY ERROR: {message}", file=sys.stderr)
    raise SystemExit(code)


def _root(value: str) -> Path:
    root = Path(value)
    if not root.is_absolute():
        # The command is normally invoked with an absolute installation path;
        # accepting a relative path would make ownership checks ambiguous.
        die("V1 root must be an absolute path")
    if not root.exists() or not root.is_dir():
        die(f"V1 root is missing or not a directory: {root}")
    return root


def get_lock_file(v1_root: str) -> str:
    return str(Path(v1_root) / ".update.lock")


def get_journal_file(v1_root: str) -> str:
    return str(Path(v1_root) / ".update.journal")


def _guard_file(v1_root: Path) -> Path:
    return v1_root / ".update.lock.guard"


@contextlib.contextmanager
def _guard(v1_root: Path) -> Iterator[None]:
    """Serialize lock-file inspection/replacement across updater processes."""

    try:
        fd = os.open(_guard_file(v1_root), os.O_RDWR | os.O_CREAT, 0o600)
    except OSError as exc:
        die(f"Cannot open lock guard: {exc}", 14)
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX)
        except OSError as exc:
            die(f"Cannot acquire lock guard: {exc}", 14)
        yield
    finally:
        try:
            fcntl.flock(fd, fcntl.LOCK_UN)
        finally:
            os.close(fd)


def _read_lock(path: Path) -> dict[str, Any] | None:
    if not path.exists():
        return None
    try:
        with path.open(encoding="utf-8") as stream:
            state = json.load(stream)
    except (OSError, UnicodeError, ValueError) as exc:
        die(f"Malformed lock state; refusing takeover: {exc}", 14)
    if not isinstance(state, dict):
        die("Malformed lock state; expected an object", 14)
    exec_id = state.get("exec_id")
    pid = state.get("pid")
    heartbeat = state.get("heartbeat")
    if (
        not isinstance(exec_id, str)
        or not SAFE_TOKEN.fullmatch(exec_id)
        or not isinstance(pid, int)
        or isinstance(pid, bool)
        or pid <= 0
        or not isinstance(heartbeat, (int, float))
        or isinstance(heartbeat, bool)
        or not math.isfinite(float(heartbeat))
    ):
        die("Malformed lock state; owner metadata is invalid", 14)
    return state


def _atomic_json(path: Path, value: Any, mode: int = 0o600) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp_path: Path | None = None
    try:
        fd, raw_tmp = tempfile.mkstemp(prefix=f".{path.name}.", dir=str(path.parent))
        tmp_path = Path(raw_tmp)
        os.fchmod(fd, mode)
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(value, stream, sort_keys=True, separators=(",", ":"))
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(tmp_path, path)
        tmp_path = None
        dir_fd = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(dir_fd)
        finally:
            os.close(dir_fd)
    except OSError as exc:
        die(f"Atomic state write failed: {exc}", 14)
    finally:
        if tmp_path is not None:
            try:
                tmp_path.unlink(missing_ok=True)
            except OSError:
                pass


def lock_acquire(v1_root: str) -> str:
    root = _root(v1_root)
    lock_file = root / ".update.lock"
    exec_id = str(uuid.uuid4())
    with _guard(root):
        state = _read_lock(lock_file)
        if state is not None:
            age = time.time() - float(state["heartbeat"])
            if age <= LOCK_STALE_SECONDS:
                die(f"Active update in progress (Exec ID: {state['exec_id']})", 14)
            # Keep this audit line on stdout for the existing operator contract;
            # callers that capture the ID must select the final line only.
            print(f"AUDIT_LOG [RECOVERY] Stale lock detected (last heartbeat {age:.1f}s ago). Taking over.")
        _atomic_json(
            lock_file,
            {"exec_id": exec_id, "pid": os.getpid(), "heartbeat": time.time()},
        )
    print(exec_id)
    return exec_id


def lock_assert_owner(v1_root: str, exec_id: str, owner_pid: str | int | None = None) -> None:
    root = _root(v1_root)
    if not isinstance(exec_id, str) or not SAFE_TOKEN.fullmatch(exec_id):
        die("Lock owner token is invalid", 14)
    expected_pid: int | None = None
    if owner_pid is not None:
        try:
            expected_pid = int(owner_pid)
        except (TypeError, ValueError):
            die("Lock owner pid is invalid", 14)
        if expected_pid <= 0:
            die("Lock owner pid is invalid", 14)
    with _guard(root):
        state = _read_lock(root / ".update.lock")
        if state is None:
            die("Update lock is missing", 14)
        if state["exec_id"] != exec_id or (expected_pid is not None and state["pid"] != expected_pid):
            die("Update lock owner mismatch", 14)
        if time.time() - float(state["heartbeat"]) > LOCK_STALE_SECONDS:
            die("Update lock owner is stale", 14)


def lock_heartbeat(v1_root: str, exec_id: str) -> None:
    root = _root(v1_root)
    with _guard(root):
        state = _read_lock(root / ".update.lock")
        if state is None or state["exec_id"] != exec_id or state["pid"] != os.getpid():
            die("Update lock owner mismatch; heartbeat refused", 14)
        state["heartbeat"] = time.time()
        _atomic_json(root / ".update.lock", state)


def lock_release(v1_root: str, exec_id: str) -> None:
    root = _root(v1_root)
    if not isinstance(exec_id, str) or not SAFE_TOKEN.fullmatch(exec_id):
        die("Lock owner token is required for release", 14)
    with _guard(root):
        state = _read_lock(root / ".update.lock")
        if state is None:
            return
        if state["exec_id"] != exec_id or state["pid"] != os.getpid():
            die("Update lock owner mismatch; release refused", 14)
        try:
            (root / ".update.lock").unlink()
        except OSError as exc:
            die(f"Update lock release failed: {exc}", 14)


def _read_journal(path: Path) -> list[dict[str, Any]]:
    if not path.exists():
        return []
    try:
        with path.open(encoding="utf-8") as stream:
            value = json.load(stream)
    except (OSError, UnicodeError, ValueError) as exc:
        die(f"Malformed update journal; refusing recovery: {exc}", 15)
    if not isinstance(value, list):
        die("Malformed update journal; expected an array", 15)
    for entry in value:
        if not isinstance(entry, dict):
            die("Malformed update journal entry", 15)
        if not isinstance(entry.get("step"), str) or entry["step"] not in VALID_STEPS:
            die("Malformed update journal step", 15)
        if not isinstance(entry.get("status"), str) or entry["status"] not in VALID_STATUSES:
            die("Malformed update journal status", 15)
        if not isinstance(entry.get("exec_id"), str) or not entry["exec_id"]:
            die("Malformed update journal owner", 15)
        if not isinstance(entry.get("target"), str):
            die("Malformed update journal target", 15)
    return value


def journal_step(v1_root: str, step: str, status: str, exec_id: str, target: str = "") -> None:
    root = _root(v1_root)
    if step not in VALID_STEPS or status not in VALID_STATUSES:
        die("Invalid journal step or status", 15)
    if not isinstance(exec_id, str) or not exec_id:
        die("Journal exec_id is required", 15)
    if not isinstance(target, str):
        die("Journal target is invalid", 15)
    journal_file = root / ".update.journal"
    journal = _read_journal(journal_file)
    journal.append(
        {
            "exec_id": exec_id,
            "timestamp": time.time(),
            "step": step,
            "status": status,
            "target": target,
        }
    )
    _atomic_json(journal_file, journal)
    print(f"AUDIT_LOG [{exec_id}] Journal: {step} -> {status}")


def check_resume_policy(v1_root: str, target: str) -> None:
    root = _root(v1_root)
    journal = _read_journal(root / ".update.journal")
    if not journal:
        return
    last = journal[-1]
    status = last["status"]
    if status in {"COMPLETED", "FAILED_SAFE"}:
        return
    if status != "STARTED":
        die("Update journal ended in an unknown state", 15)
    last_target = last["target"]
    if last_target and last_target != target:
        die(
            f"Interrupted update targets {last_target}, not requested {target}; refusing ambiguous resume",
            15,
        )
    step = last["step"]
    print(f"AUDIT_LOG [RECOVERY] Previous update to {last_target} was interrupted at step {step}.")
    if step in {"MIGRATE", "PROMOTE"}:
        die(
            "Interrupted during critical phase (MIGRATE/PROMOTE). Deterministic resume requires signed rollback authorization to revert, or manual intervention.",
            15,
        )
    print(f"AUDIT_LOG [RECOVERY] Safe to resume from interrupted step {step}.")


def check_disk_space(v1_root: str, required_mb: str | int) -> None:
    root = _root(v1_root)
    try:
        required = int(required_mb)
    except (TypeError, ValueError):
        die("Required disk space is invalid", 16)
    if required < 0:
        die("Required disk space is invalid", 16)
    _total, _used, free = shutil.disk_usage(root)
    free_mb = free / (1024 * 1024)
    if free_mb < required:
        die(f"Insufficient disk space. Required: {required}MB, Free: {free_mb:.1f}MB", 16)
    print(f"AUDIT_LOG [RECOVERY] Disk space check passed ({free_mb:.1f}MB free).")


def check_double_promotion(v1_root: str, target: str) -> None:
    root = _root(v1_root)
    state_file = root / ".release_state.json"
    if not state_file.exists():
        return
    try:
        with state_file.open(encoding="utf-8") as stream:
            state = json.load(stream)
    except (OSError, UnicodeError, ValueError) as exc:
        die(f"Malformed release state; refusing promotion: {exc}", 17)
    if not isinstance(state, dict) or not isinstance(state.get("platform_version"), str):
        die("Malformed release state; platform_version is required", 17)
    if state["platform_version"] == target:
        die(f"Double promotion rejected. Version {target} is already successfully promoted.", 17)


def main() -> None:
    if len(sys.argv) < 3:
        die("Usage: recovery.py <command> <absolute-v1-root> ...", 2)
    command = sys.argv[1]
    root = sys.argv[2]
    if command == "lock_acquire" and len(sys.argv) == 3:
        lock_acquire(root)
    elif command == "lock_assert_owner" and len(sys.argv) == 5:
        lock_assert_owner(root, sys.argv[3], sys.argv[4])
    elif command == "lock_heartbeat" and len(sys.argv) == 4:
        lock_heartbeat(root, sys.argv[3])
    elif command == "lock_release" and len(sys.argv) == 4:
        lock_release(root, sys.argv[3])
    elif command == "journal_step" and len(sys.argv) in {6, 7}:
        journal_step(root, sys.argv[3], sys.argv[4], sys.argv[5], sys.argv[6] if len(sys.argv) == 7 else "")
    elif command == "check_resume_policy" and len(sys.argv) == 4:
        check_resume_policy(root, sys.argv[3])
    elif command == "check_disk_space" and len(sys.argv) == 4:
        check_disk_space(root, sys.argv[3])
    elif command == "check_double_promotion" and len(sys.argv) == 4:
        check_double_promotion(root, sys.argv[3])
    else:
        die(f"Unknown or malformed recovery command: {command}", 2)


if __name__ == "__main__":
    main()
