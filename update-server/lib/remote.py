#!/usr/bin/env python3
"""Activate only this publication, enforcing signed remote anti-rollback."""
import hashlib
import os
import shutil
import sys
from pathlib import Path
from activate import activate, safe_parent
from verify import artifact, signature
from registry import read_json, validate_channel, monotonic

def publish(root,incoming,relative,channel):
    root=Path(root);stage=root/incoming
    release=stage/relative;destination=root/relative
    keyring=stage/'public-keys'
    try:
        reg=read_json(stage/'registry.json')
        name=Path(channel).stem
        if name.removeprefix(reg['code']+'-') not in reg['channels']:
            raise ValueError('remote channel is not registered')
        candidate=stage/'channels'/channel
        signature(candidate,keyring)
        data=validate_channel(read_json(candidate),reg,name)
        current=data['current_version']
        advertised=next(r for r in data['releases'] if r['version']==current)
        existing_channel=root/'channels'/channel
        if existing_channel.exists():
            signature(existing_channel,keyring)
            existing=validate_channel(read_json(existing_channel),reg,name)
            if existing_channel.read_bytes()!=candidate.read_bytes():
                monotonic(existing,current,advertised['archive']['sha256'])
        # Bind all advertised artifacts to exactly the transferred payload files.
        expected={}
        for kind in ('archive','bootstrap','docker_bundle'):
            meta=advertised.get(kind)
            if not meta or meta.get('sha256')=='0': continue
            url=meta['url'];filename=url.rsplit('/',1)[-1]
            if filename in expected: raise ValueError('duplicate remote artifact filename')
            expected[filename]=meta['sha256']
        payloads={p.name:p for p in release.iterdir() if not p.name.endswith(('.minisig','.sha256'))}
        if set(payloads)!=set(expected): raise ValueError('remote release file set differs from channel')
        for name,file in payloads.items():
            artifact(file,keyring)
            if hashlib.sha256(file.read_bytes()).hexdigest()!=expected[name]:
                raise ValueError('remote artifact differs from signed channel')
        safe_parent(destination)
        if destination.exists():
            for name,file in payloads.items():
                existing=destination/name
                artifact(existing,keyring)
                if hashlib.sha256(existing.read_bytes()).digest()!=hashlib.sha256(file.read_bytes()).digest():
                    raise ValueError('immutable remote release violation')
        else:
            os.rename(release,destination)
            os.chmod(destination,0o755)
            for parent in destination.parents:
                if parent==root: break
                os.chmod(parent,0o755)
        activate([(candidate,existing_channel)],keyring)
    finally:
        shutil.rmtree(stage)

if __name__=='__main__':
    try: publish(*sys.argv[1:])
    except (ValueError,OSError,KeyError) as exc:
        print('[ERROR] '+str(exc),file=sys.stderr);sys.exit(1)
