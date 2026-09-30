#!/usr/bin/env python3
"""Inspect archives without extraction. Reject links, traversal and secrets."""
import fnmatch
import re
import sys
from pathlib import Path, PurePosixPath
from bundle_lock import TarReader
from registry import read_json

def inspect(path, allowlist=(), docker=False):
    names=set()
    manifest=False
    with TarReader(Path(path)) as archive:
        members=archive.getmembers()
        if not members: raise ValueError('archive is empty')
        for member in members:
            name=member.name
            pure=PurePosixPath(name)
            if '\\' in name or pure.is_absolute() or '..' in pure.parts or not pure.parts or re.match(r'^[A-Za-z]:',name):
                raise ValueError('unsafe archive path')
            normalized=pure.as_posix()
            if normalized in names: raise ValueError('duplicate archive member')
            names.add(normalized)
            if not (member.isfile() or member.isdir()): raise ValueError('unsafe archive link or special entry')
            if not member.isfile(): continue
            base=pure.name.lower()
            secret=any(fnmatch.fnmatchcase(base,p) for p in ('*.key','*.pem','*.p12','*.pfx','*.jks','id_rsa*','id_ed25519*','.env'))
            secret=secret or (base.startswith('.env.') and base not in ('.env.example','.env.sample','.env.template'))
            relative='/'.join(pure.parts[1:]) if len(pure.parts)>1 else normalized
            allowed=normalized in allowlist or relative in allowlist
            if secret and not allowed: raise ValueError('archive contains secret-looking file: '+normalized)
            if pure.name=='manifest.json': manifest=True
    if docker and not manifest: raise ValueError('Docker bundle lacks manifest.json')

if __name__=='__main__':
    try:
        reg=read_json(sys.argv[1])
        inspect(sys.argv[2],reg['secret_allowlist'])
        if len(sys.argv)>3 and sys.argv[3]: inspect(sys.argv[3],docker=True)
    except (ValueError,OSError) as exc:
        print('[ERROR] '+str(exc),file=sys.stderr);sys.exit(1)
