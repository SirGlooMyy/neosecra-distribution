#!/usr/bin/env python3
"""Immutable image signatures, attestations and packaged SPDX promotion gate."""
import argparse
import json
import os
import re
import subprocess
from pathlib import Path, PurePosixPath
from bundle_lock import TarReader
from registry import read_json

PINNED_KEYRING=Path('/etc/neosecra/certs/cosign.pub')
DIGEST=re.compile(r'^sha256:[0-9a-f]{64}$')
REFERENCE=re.compile(r'^[a-z0-9][a-z0-9./:_-]*$')

def pinned_keys(keyring):
    # Same default public trust root as the existing customer image verifier.
    if os.name!='posix': raise ValueError('root-managed Cosign trust requires a POSIX publisher host')
    paths=[keyring] if keyring.is_file() else sorted(keyring.glob('*.pub'))
    if keyring.is_symlink() or not paths: raise ValueError('pinned Cosign public key/keyring is missing')
    for path in [keyring,*paths]:
        info=path.stat()
        if path.is_symlink() or info.st_uid!=0 or info.st_mode & 0o022:
            raise ValueError('Cosign public trust root must be root-owned and non-writable by group/others')
    return paths

def yaml_manifest(text):
    fields={};rows={};in_images=False;name=None
    for line in text.splitlines():
        if re.match(r'^[a-z_]+:',line):
            key,value=line.split(':',1)
            if key in ('product','version'): fields[key]=value.strip().strip('\'"')
            in_images=key=='images'
            continue
        if not in_images: continue
        match=re.match(r'\s*-\s*name:\s*([a-z0-9_-]+)\s*$',line)
        if match:
            name=match[1]
            if name in rows: raise ValueError('duplicate manifest image service')
            rows[name]={};continue
        match=re.match(r'\s*(ref|reference|digest):\s*(\S+)\s*$',line)
        if name and match:
            key='reference' if match[1] in ('ref','reference') else 'digest'
            rows[name][key]=match[2].strip('\'"')
    fields['images']=rows
    return fields

def contract(archive,version,reg=None):
    manifests=[];locks=[];sboms=[]
    with TarReader(archive) as stream:
        for member in stream.getmembers():
            if not member.isfile(): continue
            base=PurePosixPath(member.name).name
            if base not in ('release-manifest.json','release-manifest.yaml','images.lock') and not base.endswith('.spdx.json'): continue
            data=stream.extractfile(member).read()
            if base=='images.lock': locks.append(data.decode('utf-8'))
            elif base.endswith('.spdx.json'): sboms.append(json.loads(data))
            else: manifests.append(json.loads(data) if base.endswith('.json') else yaml_manifest(data.decode('utf-8')))
    if len(manifests)!=1: raise ValueError('Cosign artifact must have exactly one release manifest')
    manifest=manifests[0]
    if manifest.get('version')!=version: raise ValueError('artifact manifest version mismatch')
    if reg and manifest.get('product') not in [reg['code'],*reg['aliases']]: raise ValueError('artifact manifest product mismatch')
    images=manifest.get('images')
    if not isinstance(images,dict) or not images: raise ValueError('artifact manifest image set is missing')
    if len(locks)>1: raise ValueError('ambiguous packaged images lock')
    if locks:
        locked={}
        for raw in locks[0].splitlines():
            line=raw.strip()
            if not line or line.startswith('#'): continue
            if '=' not in line: raise ValueError('invalid packaged images lock')
            name,value=line.split('=',1)
            if name in locked or '@' not in value: raise ValueError('invalid or mutable packaged image')
            reference,digest=value.rsplit('@',1);locked[name]={'reference':reference,'digest':digest}
        if locked.keys()!=images.keys(): raise ValueError('packaged image service set differs from manifest')
        for name,row in images.items():
            reference=row.get('reference') or row.get('ref')
            if reference and reference.split('@',1)[0]!=locked[name]['reference']:
                raise ValueError('packaged image reference differs from manifest')
            digest=row.get('digest') or ''
            if digest and digest!=locked[name]['digest']:
                raise ValueError('packaged image digest differs from manifest')
            if reference and '@' in reference and reference.rsplit('@',1)[1]!=locked[name]['digest']:
                raise ValueError('packaged image digest differs from manifest')
        images=locked
    immutable=set()
    for row in images.values():
        reference=row.get('reference') or row.get('ref') or ''
        digest=row.get('digest') or ''
        if '@' in reference:
            reference,pin=reference.rsplit('@',1)
            if digest and digest!=pin: raise ValueError('image digest mismatch')
            digest=pin
        if not REFERENCE.fullmatch(reference) or reference.endswith(':latest') or not DIGEST.fullmatch(digest):
            raise ValueError('Cosign artifact image is not immutable')
        immutable.add(reference+'@'+digest)
    if not sboms: raise ValueError('packaged SPDX SBOMs are missing')
    for sbom in sboms:
        if sbom.get('spdxVersion')!='SPDX-2.3' or not isinstance(sbom.get('packages'),list) or not sbom['packages']:
            raise ValueError('packaged SPDX SBOM is invalid')
    return sorted(immutable)

def check(archive,version,public_keys,reg=None):
    for image in contract(Path(archive),version,reg):
        verified=False
        for key in public_keys:
            signature=subprocess.run(['cosign','verify','--key',str(key),image],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
            if signature.returncode!=0: continue
            # Existing customer predicate contract; packaged SPDX validation above
            # is additionally mandatory for this named trust policy.
            attestation=subprocess.run(['cosign','verify-attestation','--key',str(key),'--type','https://cosign.sigstore.dev/attestation/v1',image],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
            if attestation.returncode==0: verified=True;break
        if not verified: raise ValueError('Cosign image signature/attestation verification failed')

if __name__=='__main__':
    parser=argparse.ArgumentParser()
    parser.add_argument('--archive',type=Path,required=True)
    parser.add_argument('--version',required=True)
    parser.add_argument('--registry',type=Path)
    args=parser.parse_args()
    try:
        check(args.archive,args.version,pinned_keys(PINNED_KEYRING),read_json(args.registry) if args.registry else None)
    except (ValueError,OSError,KeyError,TypeError) as exc:
        parser.exit(1,'[GATE-ERROR] '+str(exc)+'\n')
