#!/usr/bin/env python3
"""Failure-atomic replacement of verified channel pairs on local filesystems.

Regular channel paths remain compatible with repository tooling. Each rename
is atomic; readers may briefly retry a mismatched pair during the multi-path
transaction. SIGKILL/power loss cannot be made atomic across filesystems.
"""
import os
import hashlib
import signal
import sys
import tempfile
from pathlib import Path
from verify import signature

def safe_parent(path):
    for parent in [path.parent,*path.parents]:
        if parent.is_symlink(): raise ValueError('activation path contains a symlink')
    path.parent.mkdir(parents=True,exist_ok=True)
    if path.is_symlink(): raise ValueError('activation target is a symlink')

def activate(pairs,keyring):
    moves=[]
    expected_digest=None
    backups=[]
    # All candidates are copied/prepared before verification. The exact verified
    # inode is renamed into place; there is no copy after verification.
    for candidate,destination in pairs:
        candidate,destination=Path(candidate),Path(destination)
        safe_parent(destination)
        signature(candidate,keyring)
        digest=hashlib.sha256(candidate.read_bytes()).digest()
        if expected_digest is not None and digest!=expected_digest:
            raise ValueError("channel candidate SHA-256 mismatch")
        expected_digest=digest
        moves.extend([(candidate,destination),(Path(str(candidate)+'.minisig'),Path(str(destination)+'.minisig'))])
    for candidate,destination in moves:
        safe_parent(destination)
        if candidate.stat().st_dev != destination.parent.stat().st_dev:
            raise ValueError('activation candidate is not on destination filesystem')
    handlers={}
    def interrupted(signum,frame): raise RuntimeError('activation interrupted')
    for sig in (signal.SIGTERM,signal.SIGINT):
        handlers[sig]=signal.signal(sig,interrupted)
    try:
        for candidate,destination in moves:
            backup=None
            if destination.exists():
                fd,name=tempfile.mkstemp(prefix='.publish-backup-',dir=destination.parent)
                backup=Path(name)
                backups.append((destination,backup))
                with os.fdopen(fd,'wb') as stream:
                    stream.write(destination.read_bytes());stream.flush();os.fsync(stream.fileno())
                os.chmod(backup,destination.stat().st_mode & 0o777)
            else:
                backups.append((destination,None))
        completed=[]
        try:
            for (candidate,destination),(_,backup) in zip(moves,backups):
                os.replace(candidate,destination)
                completed.append((destination,backup))
        except BaseException:
            for destination,backup in reversed(completed):
                if backup: os.replace(backup,destination)
                else: destination.unlink(missing_ok=True)
            raise
    finally:
        for sig,handler in handlers.items(): signal.signal(sig,handler)
        for _,backup in backups:
            if backup: backup.unlink(missing_ok=True)

if __name__=='__main__':
    try:
        keyring,*paths=sys.argv[1:]
        activate(list(zip(paths[::2],paths[1::2])),keyring)
    except (ValueError,OSError,RuntimeError) as exc:
        print('[ERROR] '+str(exc),file=sys.stderr);sys.exit(1)
