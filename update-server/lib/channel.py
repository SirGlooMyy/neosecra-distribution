#!/usr/bin/env python3
"""Append a release while preserving all historical release JSON bytes."""
import hashlib
import json
import sys
from datetime import datetime, timezone
from pathlib import Path
from registry import read_json, images, validate_channel, monotonic

BASE_URL='https://update.neosecra.com'

def spans(raw):
    decoder=json.JSONDecoder()
    pos=raw.index('{')+1
    result={}
    while True:
        while raw[pos].isspace(): pos+=1
        if raw[pos]=='}': break
        key,end=decoder.raw_decode(raw,pos)
        pos=end
        while raw[pos].isspace(): pos+=1
        if raw[pos]!=':': raise ValueError('invalid JSON object')
        pos+=1
        while raw[pos].isspace(): pos+=1
        _,end=decoder.raw_decode(raw,pos)
        result[key]=(pos,end)
        pos=end
        while raw[pos].isspace(): pos+=1
        if raw[pos]==',': pos+=1
        elif raw[pos]!='}': raise ValueError('invalid JSON object')
    return result,pos

def append(raw, updates, release):
    locations,end=spans(raw)
    start,stop=locations['releases']
    old=raw[start:stop]
    has_entries=bool(json.loads(old))
    replaced=old[:-1]+(',' if has_entries else '')+'\n    '+json.dumps(release,ensure_ascii=False,indent=2).replace('\n','\n    ')+'\n  ]'
    changes=[(start,stop,replaced)]
    additions=[]
    for key,value in updates.items():
        encoded=json.dumps(value,ensure_ascii=False)
        if key in locations:
            a,b=locations[key];changes.append((a,b,encoded))
        else: additions.append(json.dumps(key)+': '+encoded)
    if additions: changes.append((end,end,',\n  '+',\n  '.join(additions)+'\n'))
    for a,b,value in sorted(changes,reverse=True): raw=raw[:a]+value+raw[b:]
    return raw

def merge_extra(path, additions):
    path=Path(path)
    data=read_json(path) if path.is_file() else {}
    if not isinstance(data,dict): raise ValueError('invalid step metadata')
    for key,value in additions.items():
        if key in data and data[key]!=value: raise ValueError('conflicting step metadata')
        data[key]=value
    path.write_text(json.dumps(data),encoding='utf-8')


def metadata(path, relative):
    return {'url':BASE_URL+'/'+relative+'/'+path.name,'sha256':hashlib.sha256(path.read_bytes()).hexdigest(),
            'size_bytes':path.stat().st_size,'signature_url':BASE_URL+'/'+relative+'/'+path.name+'.minisig'}

def build(reg, channel, version, source, output, relative, archive, bundle, bootstrap, extra):
    if source.is_file():
        raw=source.read_bytes().decode('utf-8')
        data=read_json(source)
    else:
        data={'product':reg['code'],'product_code':reg['code'],'edition':reg['channel_defaults']['edition'],
              'channel':channel,'status':'reserved','current_version':None,'updated':None,'releases':[]}
        raw=json.dumps(data,indent=2)+'\n'
    validate_channel(data,reg,channel)
    arch=metadata(Path(archive),relative)
    monotonic(data,version,arch['sha256'])
    now=datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
    release={'version':version,'released_at':now,'archive':arch,'bootstrap':metadata(Path(bootstrap),relative) if bootstrap else None}
    if bundle:
        release['docker_bundle']=metadata(Path(bundle),relative)
        release['bundle_url']=release['docker_bundle']['url']
    elif reg.get('legacy_empty_bundle'):
        release['docker_bundle']={'url':BASE_URL+'/'+relative+'/none','sha256':'0','size_bytes':0,'signature_url':BASE_URL+'/'+relative+'/none'}
        release['bundle_url']=release['docker_bundle']['url']
    if extra.is_file():
        additions=read_json(extra)
        if additions.keys() & release.keys(): raise ValueError('step cannot replace artifact metadata')
        release.update(additions)
    updates={'current_version':version,'updated':now}
    if not source.is_file(): updates.update(reg['channel_defaults'])
    if reg.get('normalize_identity'):
        updates.update(product=reg['code'],product_code=reg['code'],**reg['channel_defaults'])
    # Existing historical status semantics are preserved except explicit registry normalization.
    result=append(raw,updates,release)
    validate_channel(json.loads(result),reg,channel)
    output.write_bytes(result.encode('utf-8'))

if __name__=='__main__':
    try:
        if sys.argv[1]=='images':
            merge_extra(sys.argv[4],{'images':images(sys.argv[3],read_json(sys.argv[2]))})
        elif sys.argv[1]=='build':
            _,_,reg,ch,ver,source,out,relative,archive,bundle,bootstrap,extra=sys.argv
            build(read_json(reg),ch,ver,Path(source),Path(out),relative,archive,bundle,bootstrap,Path(extra))
    except (ValueError,OSError,KeyError,TypeError) as exc:
        print('[ERROR] '+str(exc),file=sys.stderr);sys.exit(1)
