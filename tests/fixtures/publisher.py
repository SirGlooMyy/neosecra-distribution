"""Offline publisher harness, including Windows -> Git Bash path conversion."""
import hashlib
import io
import json
import os
import shutil
import subprocess
import sys
import tarfile
from pathlib import Path
import pytest

ROOT=Path(__file__).resolve().parents[2]
FIXTURES=Path(__file__).resolve().parent
BASH=Path(r'C:\Program Files\Git\bin\bash.exe') if os.name=='nt' else shutil.which('bash')

def posix(path):
    value=str(path).replace('\\','/')
    if len(value)>2 and value[1]==':': return '/'+value[0].lower()+value[2:]
    return value

def package(path, payload=None):
    payload=payload or {'payload/readme.txt':b'fixture package\n'}
    with tarfile.open(path,'w:gz') as stream:
        for name,data in payload.items():
            member=tarfile.TarInfo(name);member.size=len(data);member.mode=0o644
            stream.addfile(member,io.BytesIO(data))
    return path

def fake_signature(path):
    Path(str(path)+'.minisig').write_text(hashlib.sha256(path.read_bytes()).hexdigest()+'\n',encoding='utf-8')

class Publisher:
    def __init__(self,tmp,stub_gates=False):
        if not BASH or not Path(BASH).is_file(): pytest.skip('Git Bash/bash is unavailable')
        self.root=tmp/'repo';self.www=tmp/'www';self.bin=tmp/'bin'
        self.root.mkdir(parents=True);self.bin.mkdir(parents=True)
        for relative in ('update-server/lib','products','schemas'):
            shutil.copytree(ROOT/relative,self.root/relative,ignore=shutil.ignore_patterns('__pycache__'))
        for relative in ('update-server/publish.sh','update-server/soc-bundle-lock.py','update-server/bootstrap-hotspot.sh','bootstrap.sh','bin/validate-channels.sh','ci/prerelease-gate.sh','ci/prerelease-gate-hotspot.sh','ci/prerelease-gate-soc.sh'):
            target=self.root/relative;target.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(ROOT/relative,target)
        if stub_gates:
            for gate in (self.root/'ci').glob('*.sh'): shutil.copyfile(FIXTURES/'gate.sh',gate)
        (self.root/'channels').mkdir()
        (self.root/'public-keys').mkdir()
        # Public pin and dummy adapter file; these are not real cryptographic keys.
        (self.root/'public-keys'/'fixture.pub').write_text('test-only public adapter\n',encoding='utf-8')
        self.key=tmp/'adapter-key';self.key.write_text('test-only signing adapter\n',encoding='utf-8')
        for name in ('minisign','rsync','ssh'):
            shutil.copyfile(FIXTURES/name,self.bin/name);(self.bin/name).chmod(0o755)
        python=os.environ.get('NEOSECRA_TEST_PYTHON') or (posix(ROOT/'.codex-python/python.exe') if os.name=='nt' else sys.executable)
        (self.bin/'python3').write_text('#!/usr/bin/env bash\nexec "'+python+'" "$@"\n',encoding='utf-8')
        (self.bin/'python3').chmod(0o755)
        for name in ('cosign','docker','pytest'):
            (self.bin/name).write_text('#!/usr/bin/env bash\nexit 0\n',encoding='utf-8');(self.bin/name).chmod(0o755)
        self.env=os.environ.copy()
        self.env.pop('UPDATE_SERVER_TARGETS',None);self.env.pop('MINISIGN_BIN',None)
        self.env.update(PYTHONDONTWRITEBYTECODE='1',GATE_LOG=posix(tmp/'gate.log'),TRANSFER_LOG=posix(tmp/'transfer.log'))
        self.tmp=tmp

    def register_fixture(self):
        shutil.copyfile(FIXTURES/'fixtureprod.json',self.root/'products/fixtureprod.json')

    def seed(self,product='fixtureprod',channel='stable',version='0.1.0',raw=None):
        data={'product':product,'product_code':product,'edition':'standard','channel':product+'-'+channel,'status':'available','current_version':version,'updated':'2026-01-01T00:00:00Z',
              'releases':[{'version':version,'released_at':'2026-01-01T00:00:00Z','archive':{'url':'https://update.neosecra.com/releases/'+version+'/legacy.tar.gz','sha256':'a'*64,'size_bytes':1,'signature_url':'https://update.neosecra.com/releases/'+version+'/legacy.tar.gz.minisig'},'legacy_extension':{'z':2,'a':1}}]}
        content=raw if raw is not None else json.dumps(data,indent=2).encode()+b'\n'
        source=self.root/'channels'/(product+'-'+channel+'.json');source.write_bytes(content);fake_signature(source)
        (self.www/'channels').mkdir(parents=True,exist_ok=True)
        dest=self.www/'channels'/source.name;shutil.copyfile(source,dest);shutil.copyfile(Path(str(source)+'.minisig'),Path(str(dest)+'.minisig'))
        return source

    def shell(self,args,**extra_env):
        env=dict(self.env,**extra_env)
        return subprocess.run([str(BASH),'-c','export PATH="$1:$PATH"; shift; exec bash "$@"','fixture',posix(self.bin),*map(str,args)],cwd=self.root,env=env,capture_output=True,text=True,timeout=90)

    def run(self,product='fixtureprod',channel='stable',version='1.0.1',archive=None,bundle=None,lock=None,migration=None,dry=False,remote=False,**env):
        archive=archive or package(self.tmp/(product+'-'+version+'.tar.gz'))
        args=[posix(self.root/'update-server/publish.sh'),'--product',product,'--channel',channel,'--version',version,'--archive',posix(archive),'--key',posix(self.key),'--www',posix(self.www)]
        for flag,value in (('--bundle',bundle),('--images-lock',lock),('--migration-metadata',migration)):
            if value: args.extend([flag,posix(value)])
        if dry: args.append('--dry-run')
        if remote: args.extend(['--rsync','fixture@host:/srv/update'])
        return self.shell(args,**env)

    def snapshot(self):
        roots=[self.root/'channels',self.www]
        return {str(p.relative_to(self.tmp)):p.read_bytes() for root in roots if root.exists() for p in root.rglob('*') if p.is_file()}

def migration_off(path):
    data={'migration_required':False,'migration_strategy':'off','backward_compatible_with_previous_app':True,'rollback_safe_without_db_restore':True,'migration_checksum':None,'schema_from':None,'schema_to':None,'estimated_lock_seconds':0,'estimated_temp_space_bytes':0,'backup_required':False}
    path.write_text(json.dumps(data),encoding='utf-8');return path
