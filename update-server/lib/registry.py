#!/usr/bin/env python3
"""Strict, dependency-free registry and historical channel validation."""
import json
import re
import sys
from pathlib import Path

CODE = re.compile(r'^[a-z0-9][a-z0-9._-]*$')
VERSION = re.compile(r'^[0-9]+\.[0-9]+\.[0-9]+$')
SHA256 = re.compile(r'^[0-9a-f]{64}$')

def fail(message):
    raise ValueError(message)

def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            fail('duplicate JSON key: ' + key)
        result[key] = value
    return result

def read_json(path):
    return json.loads(Path(path).read_text(encoding='utf-8'), object_pairs_hook=unique_object)

def validate_schema(value, schema, location='registry'):
    # Only the JSON Schema keywords used by the checked-in registry schema.
    types = {'object':dict,'array':list,'string':str,'boolean':bool,'null':type(None)}
    expected = schema.get('type')
    if expected and not any(type(value) is types[t] for t in ([expected] if isinstance(expected,str) else expected)):
        fail(location + ': invalid type')
    if 'enum' in schema and value not in schema['enum']:
        fail(location + ': invalid choice')
    if isinstance(value,dict):
        missing = set(schema.get('required',[])) - value.keys()
        if missing: fail(location + ': missing ' + ','.join(sorted(missing)))
        properties = schema.get('properties',{})
        if schema.get('additionalProperties') is False and value.keys() - properties.keys():
            fail(location + ': unknown field')
        for key, item in value.items():
            if key in properties: validate_schema(item,properties[key],location+'.'+key)
    elif isinstance(value,list):
        if len(value) < schema.get('minItems',0): fail(location + ': too few items')
        if schema.get('uniqueItems') and len({json.dumps(v,sort_keys=True) for v in value}) != len(value):
            fail(location + ': duplicate item')
        for item in value: validate_schema(item,schema.get('items',{}),location+'[]')
    elif isinstance(value,str):
        if len(value) < schema.get('minLength',0): fail(location + ': too short')
        if 'pattern' in schema and not re.search(schema['pattern'],value): fail(location + ': invalid pattern')

def repo_file(root, relative):
    path = root / relative
    if path.is_symlink() or not path.is_file() or not path.resolve().is_relative_to(root.resolve()):
        fail('missing or unsafe repository file: '+relative)
    return path

def load_registry(root, code):
    if not CODE.fullmatch(code): fail('invalid product code')
    path = root / 'products' / (code+'.json')
    if not path.is_file() or path.is_symlink(): fail('unregistered product: '+code)
    reg = read_json(path)
    validate_schema(reg,read_json(root/'schemas/product-registry.schema.json'))
    if reg['code'] != code: fail('registry filename/product identity mismatch')
    if not set(reg['gate']['channels']) <= set(reg['channels']): fail('gate channel is not registered')
    if not {'archive','version'} <= set(reg['gate']['inputs']): fail('gate must receive archive and version')
    try: re.compile(reg['archive_pattern'])
    except re.error: fail('invalid archive name pattern')
    repo_file(root,reg['gate']['script'])
    if reg['bootstrap']: repo_file(root,reg['bootstrap'])
    for step in reg['steps']:
        repo_file(root,'update-server/lib/steps/'+step+'.sh')
    if not set(reg.get('legacy_empty_channels',[])) <= set(reg['channels']): fail('legacy channel is not registered')
    if reg['migration_metadata']!='none' and 'migration-contract' not in reg['steps']: fail('migration input needs registered migration-contract step')
    lock = reg['images_lock']
    for group in lock['shared_services']:
        if not set(group) <= set(lock['services']): fail('shared image service is not registered')
    for contract in (reg['bundle'],lock):
        if (contract['requirement']=='none') != (contract['format']=='none'): fail('input requirement/format mismatch')
    for allowed in reg['secret_allowlist']:
        if '..' in Path(allowed).parts: fail('unsafe secret test allowlist path')
    if lock['requirement']!='none' and not lock['services']: fail('required image service set is empty')
    optional=lock.get('optional_services',[])
    if set(optional)&set(lock['services']): fail('optional image service is also required')
    if optional and lock['requirement']=='none': fail('optional image services need an image lock')
    archive_path=lock.get('archive_path')
    if archive_path is not None:
        pure=Path(archive_path)
        if pure.is_absolute() or '..' in pure.parts or '\\' in archive_path or lock['requirement']=='none': fail('unsafe image lock archive path')
    if not set(reg.get('pending_channels',[]))<=set(reg['channels']): fail('pending channel is not registered')
    if set(reg.get('pending_channels',[]))&set(reg.get('legacy_empty_channels',[])): fail('channel cannot be both pending and legacy empty')
    if 'bundle-lock' in reg['steps'] and (reg['bundle']['requirement']=='none' or lock['requirement']=='none'):
        fail('bundle-lock step requires declared bundle and image lock formats')
    return reg

def validate_channel(data, reg, name):
    if name.removeprefix(reg['code']+'-') not in reg['channels']: fail('channel is not registered for product')
    if data.get('channel') != name: fail('channel name mismatch')
    if data.get('product') not in [reg['code']]+reg['aliases']: fail('channel product mismatch')
    if data.get('product_code',reg['code']) != reg['code']: fail('channel product_code mismatch')
    if data.get('edition','standard') not in ['standard','enterprise']+reg.get('legacy_editions',[]): fail('invalid channel edition')
    releases = data.get('releases')
    if not isinstance(releases,list): fail('channel releases must be an array')
    seen = set()
    for release in releases:
        version = release.get('version','')
        if not isinstance(version,str) or not VERSION.fullmatch(version) or version in seen:
            fail('invalid or duplicate release version')
        seen.add(version)
        archive = release.get('archive')
        if archive:
            if not SHA256.fullmatch(str(archive.get('sha256',''))) or not archive.get('signature_url') or not archive.get('url'):
                fail('invalid release archive contract')
    current = data.get('current_version')
    if current is not None:
        if current not in seen: fail('current_version is not present in releases')
        if not next(r for r in releases if r['version']==current).get('archive'): fail('current release is not artifact-backed')
    if data.get('status')=='available' and not current:
        fail('available channel has no current release')
    return data

def validate_empty_channel(data, reg, name):
    validate_channel(data,reg,name)
    if name.removeprefix(reg['code']+'-') not in reg.get('legacy_empty_channels',[]):
        fail('unsigned channel is not registered as legacy empty')
    if 'current_version' not in data or data['current_version'] is not None or data['releases'] != [] or data.get('status') not in ['reserved','unavailable']:
        fail('unsigned channel must be empty and unpublished')
    return data

def monotonic(data, version, digest):
    target = tuple(map(int,version.split('.')))
    for release in data['releases']:
        if release['version']==version:
            if (release.get('archive') or {}).get('sha256') != digest:
                fail('immutable release violation: existing version has a different archive hash')
            fail('release version already exists; publish a new patch version')
    if data.get('current_version') and target <= tuple(map(int,data['current_version'].split('.'))):
        fail('publish target is not newer than current_version')

def validate_manifest_trust(path, reg):
    # Lazy import: bundle_lock also uses registry helpers. No YAML dependency
    # is needed for the canonical top-level, single-line policy scalar.
    from bundle_lock import TarReader
    manifests = []
    with TarReader(Path(path)) as stream:
        for member in stream.getmembers():
            if Path(member.name).name not in ('release-manifest.yaml','release-manifest.json'): continue
            if not member.isfile() or member.size > 1024 * 1024:
                fail('missing or unsafe release manifest trust_policy')
            manifests.append(member)
        if len(manifests) > 1: fail('ambiguous release manifest trust_policy: multiple manifests')
        if not manifests: return
        member = manifests[0]
        with stream.extractfile(member) as source:
            text = source.read().decode('utf-8')
        if member.name.endswith('.json'):
            data = json.loads(text,object_pairs_hook=unique_object)
            if not isinstance(data,dict): fail('release manifest must be an object')
            policy = data.get('trust_policy')
        else:
            if any(re.match(r'^(?:---|\.\.\.)(?:\s|$)',line) for line in text.splitlines()):
                fail('release manifest trust_policy requires one canonical YAML document without document markers')
            fields = [line for line in text.splitlines() if re.match(r'''^(?:trust_policy|'trust_policy'|"trust_policy")\s*:''',line)]
            if not fields: fail('release manifest is missing trust_policy; rebuild and sign with the registered policy')
            if len(fields) != 1: fail('duplicate release manifest trust_policy')
            match = re.fullmatch(r'''(?:trust_policy|'trust_policy'|"trust_policy"):[ \t]*(?:(minisign-package-v1|cosign-spdx-v1)|'(minisign-package-v1|cosign-spdx-v1)'|"(minisign-package-v1|cosign-spdx-v1)")(?:[ \t]+#.*)?[ \t]*''',fields[0])
            if not match: fail('invalid release manifest trust_policy; use a canonical top-level policy scalar')
            policy = next(value for value in match.groups() if value is not None)
        if policy not in ('minisign-package-v1','cosign-spdx-v1'):
            fail('missing or unsupported release manifest trust_policy')
        if policy != reg['trust_policy']:
            fail('release manifest/registry trust_policy mismatch: expected '+reg['trust_policy'])

def images(path, reg):
    rows = {}
    seen = {}
    for line in Path(path).read_text(encoding='utf-8').splitlines():
        line = line.strip()
        if not line or line.startswith('#'): continue
        if '=' not in line: fail('invalid image lock entry')
        name, value = (p.strip() for p in line.split('=',1))
        if name in rows or not CODE.fullmatch(name): fail('invalid or duplicate image name')
        if '@' not in value: fail('mutable '+reg['code'].upper()+' image reference')
        reference,digest = value.rsplit('@',1)
        if not re.fullmatch(r'[a-z0-9][a-z0-9./:_-]*',reference) or reference.endswith(':latest'):
            fail('invalid or mutable image reference')
        if not re.fullmatch(r'sha256:[0-9a-f]{64}',digest): fail('image must be pinned to lowercase sha256')
        previous = seen.get(digest)
        if previous and (reference != rows[previous]['reference'] or not any({name,previous} <= set(g) for g in reg['images_lock']['shared_services'])):
            fail('duplicate image digest is not an allowed share')
        rows[name] = {'reference':reference,'digest':digest}
        seen[digest]=name
    required=set(reg['images_lock']['services']); optional=set(reg['images_lock'].get('optional_services',[]))
    if not required <= set(rows) or set(rows)-required-optional: fail('images lock must match compose services exactly')
    # Profile services (Assessment: openvas, zap, dast-egress) are pinned like the rest but
    # flagged, so a stack without that profile still matches the signed mapping.
    for name in rows:
        if name in optional: rows[name]['optional']=True
    return rows

def main():
    command, root_text, *args = sys.argv[1:]
    root = Path(root_text)
    if command=='list':
        for path in sorted((root/'products').glob('*.json')):
            reg = load_registry(root,path.stem)
            for channel in reg['channels']: print(reg['code']+'-'+channel)
        return
    reg = load_registry(root,args[0])
    if command=='validate-manifest':
        from archive import inspect
        inspect(args[1],reg['secret_allowlist'])
        if len(args)>2 and args[2]: inspect(args[2],docker=True)
        validate_manifest_trust(args[1],reg); return
    if command=='validate-channel':
        validate_channel(read_json(args[2]),reg,args[0]+'-'+args[1]); return
    if command=='validate-lock-in-archive':
        # The package carries the image lock it was built with; it must be the lock being published.
        _,archive,lock=args
        member_path=reg['images_lock'].get('archive_path')
        if not member_path: return
        from bundle_lock import TarReader
        with TarReader(Path(archive)) as stream:
            matches=[m for m in stream.getmembers() if m.isfile() and m.name.split('/',1)[-1]==member_path]
            if len(matches)!=1: fail('archive does not carry exactly one '+member_path)
            with stream.extractfile(matches[0]) as source: packaged=source.read()
        normalise=lambda data:data.replace(b'\r\n',b'\n')
        if normalise(packaged)!=normalise(Path(lock).read_bytes()): fail('archive image lock differs from --images-lock')
        return
    if command=='plan':
        _,channel,version,archive,bundle,lock,migration = args
        if not CODE.fullmatch(channel) or channel not in reg['channels']: fail('channel is not registered for product')
        if not VERSION.fullmatch(version): fail('version must match numeric semver')
        # Validate required inputs before reading an archive or creating a stage.
        for label,provided,require in [('images-lock',lock,reg['images_lock']['requirement']),('bundle',bundle,reg['bundle']['requirement']),('migration-metadata',migration,reg['migration_metadata'])]:
            if require=='required' and not provided: fail('--'+label+' is required')
            if require=='none' and provided: fail('--'+label+' is not registered for product')
            if provided and (not Path(provided).is_file() or Path(provided).is_symlink()): fail('missing or unsafe --'+label)
        if bundle:
            name=Path(bundle).name
            reserved={Path(archive).name,Path(archive).name+'.sha256',Path(archive).name+'.minisig','bootstrap.sh','bootstrap.sh.sha256','bootstrap.sh.minisig'}
            if not re.fullmatch(r'[a-zA-Z0-9][a-zA-Z0-9._-]*',name) or name in reserved or name.endswith(('.minisig','.sha256')):
                fail('unsafe or conflicting bundle filename')
        if 'bundle-lock' in reg['steps'] and bool(bundle)!=bool(lock):
            fail('--bundle and --images-lock are required together by bundle-lock step')
        if not Path(archive).is_file() or Path(archive).is_symlink(): fail('missing or unsafe archive')
        if not re.fullmatch(reg['archive_pattern'],Path(archive).name): fail('archive name does not match registry')
        validate_manifest_trust(archive,reg)
        if lock: images(lock,reg)
        rel = 'releases/'+(reg['code']+'/' if reg['release_layout']=='product-version' else '')+version
        fields = [reg['bootstrap'] or '',reg['gate']['script'],reg['trust_policy'],rel,'1' if channel in reg['gate']['channels'] else '0',','.join(reg['steps']),','.join(reg['gate']['inputs'])]
        sys.stdout.buffer.write(('\0'.join(fields)+'\0').encode())

if __name__=='__main__':
    try: main()
    except (ValueError,OSError,KeyError,TypeError) as exc:
        print('[ERROR] '+str(exc),file=sys.stderr); sys.exit(1)
