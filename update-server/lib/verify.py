#!/usr/bin/env python3
"""Pinned Minisign verification; never display signer diagnostics."""
import hashlib
import re
import os
import subprocess
import shutil
import sys
from pathlib import Path

def keys(keyring):
    keyring=Path(keyring)
    if keyring.is_symlink(): raise ValueError('pinned keyring is a symlink')
    result=[keyring] if keyring.is_file() else sorted(p for p in keyring.glob('*.pub') if p.is_file() and not p.is_symlink())
    if not result: raise ValueError('pinned public keyring is missing or empty')
    return result

def signature(file,keyring,binary=None):
    file=Path(file)
    sig=Path(str(file)+'.minisig')
    if file.is_symlink() or sig.is_symlink() or not file.is_file() or not sig.is_file():
        raise ValueError('signed file or signature is missing or unsafe')
    binary=binary or os.environ.get('MINISIGN_BIN','minisign')
    for key in keys(keyring):
        command=[binary,'-V','-p',key.as_posix(),'-m',file.as_posix(),'-x',sig.as_posix(),'-q']
        if os.name=='nt':
            resolved=shutil.which(binary) or binary
            if resolved.lower().endswith('.exe'):
                resolved=re.sub(r'^/([a-zA-Z])/',lambda m: m[1].upper()+':/',resolved)
                command[0]=resolved
            else: command=[shutil.which('bash') or 'bash',*command]
        if subprocess.run(command,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL).returncode==0:
            return
    raise ValueError('Minisign verification failed')

def artifact(file,keyring,binary=None):
    file=Path(file)
    sidecar=Path(str(file)+'.sha256')
    row=sidecar.read_text(encoding='utf-8')
    match=re.fullmatch(r'([0-9a-f]{64}) [ *]([^\r\n]+)\n',row)
    if sidecar.is_symlink() or not match or match[1]!=hashlib.sha256(file.read_bytes()).hexdigest() or match[2]!=file.name:
        raise ValueError('SHA-256 sidecar mismatch')
    signature(file,keyring,binary)

if __name__=='__main__':
    try:
        if sys.argv[1]=='artifact': artifact(sys.argv[2],sys.argv[3])
        else: signature(sys.argv[2],sys.argv[3])
    except (ValueError,OSError) as exc:
        print('[ERROR] '+str(exc),file=sys.stderr);sys.exit(1)
