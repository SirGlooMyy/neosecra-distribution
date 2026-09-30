import hashlib
import importlib
import io
import json
import os
from pathlib import Path
import sys
import tarfile
import pytest
from fixtures.publisher import ROOT, Publisher, package, migration_off, fake_signature
from test_soc_publish_contract import _lock, _write_bundle, _write_package

sys.path.insert(0,str(ROOT/'update-server/lib'))
from channel import spans


def success(result): assert result.returncode==0,result.stdout+result.stderr

def soc_inputs(tmp):
    lock=tmp/'images.lock';_lock(lock)
    archive=tmp/'soc-1.0.1.tar.gz';_write_package(archive,lock)
    bundle=tmp/'soc-1.0.1-bundle.tar.gz';_write_bundle(bundle,lock)
    return archive,bundle,lock

def test_soc_stable_uses_registered_gate_and_final_archive(tmp_path):
    p=Publisher(tmp_path,stub_gates=True)
    archive,bundle,lock=soc_inputs(tmp_path)
    old_digest=hashlib.sha256(archive.read_bytes()).hexdigest()
    success(p.run(product='soc',archive=archive,bundle=bundle,lock=lock))
    channel=json.loads((p.www/'channels/soc-stable.json').read_text())
    digest=channel['releases'][0]['archive']['sha256']
    assert digest!=old_digest
    gate=(tmp_path/'gate.log').read_text()
    assert gate.startswith('prerelease-gate-soc.sh\t'+digest)
    assert gate.rstrip().endswith('/soc-1.0.1.tar.gz')

def test_transformed_archive_keeps_basename_checksum_and_signature(tmp_path):
    p=Publisher(tmp_path,stub_gates=True)
    archive,bundle,lock=soc_inputs(tmp_path)
    success(p.run(product='soc',channel='beta',archive=archive,bundle=bundle,lock=lock))
    final=p.www/'releases/soc/1.0.1/soc-1.0.1.tar.gz'
    assert final.is_file()
    assert Path(str(final)+'.sha256').read_text() in {hashlib.sha256(final.read_bytes()).hexdigest()+marker+final.name+'\n' for marker in ('  ',' *')}
    assert Path(str(final)+'.minisig').is_file()
    with tarfile.open(final) as stream: assert stream.extractfile('soc-1.0.1/release/bundle.lock') is not None

@pytest.mark.parametrize('failure', [{'FAIL_SIGN':'channel'},{'FAIL_VERIFY':'channel'},{'FAIL_GATE':'1'},{'FAIL_TRANSFER':'1'}])
def test_failed_publish_leaves_active_pairs_byte_identical(tmp_path,failure):
    p=Publisher(tmp_path,stub_gates=True);p.register_fixture();p.seed();before=p.snapshot()
    result=p.run(remote='FAIL_TRANSFER' in failure,**failure)
    assert result.returncode!=0
    expected='signing failed' if 'FAIL_SIGN' in failure else 'verification failed' if 'FAIL_VERIFY' in failure else 'gate failed' if 'FAIL_GATE' in failure else None
    if expected: assert expected in result.stdout+result.stderr
    assert p.snapshot()==before
    assert not (p.www/'.publish-lock').exists()
    assert not list(p.www.glob('.publish.*'))

def test_source_and_www_receive_identical_signed_pair(tmp_path):
    p=Publisher(tmp_path);p.register_fixture();success(p.run())
    for suffix in ('','.minisig'):
        name='fixtureprod-stable.json'+suffix
        assert (p.root/'channels'/name).read_bytes()==(p.www/'channels'/name).read_bytes()

def test_rsync_only_transfers_this_publication_without_delete(tmp_path):
    p=Publisher(tmp_path);p.register_fixture();(p.www/'unrelated').mkdir(parents=True)
    unrelated=p.www/'unrelated/keep.bin';unrelated.write_bytes(b'untouched')
    success(p.run(remote=True))
    trace=(tmp_path/'transfer.log').read_text()
    assert '--delete' not in trace
    assert 'StrictHostKeyChecking=yes' in trace
    assert '/upload/' in trace and '.publish-incoming.' in trace
    assert '/signer/' not in trace and 'adapter-key' not in trace
    assert unrelated.read_bytes()==b'untouched'

@pytest.mark.parametrize('product',['soc','pish'])
def test_unregistered_bootstrap_is_not_published(tmp_path,product):
    p=Publisher(tmp_path,stub_gates=True)
    options={}
    if product=='soc':
        archive,bundle,lock=soc_inputs(tmp_path);options=dict(archive=archive,bundle=bundle,lock=lock,channel='beta')
    success(p.run(product=product,**options))
    channel=json.loads((p.www/'channels'/(product+'-'+options.get('channel','stable')+'.json')).read_text())
    assert channel['releases'][0]['bootstrap'] is None
    assert not (p.www/'releases'/product/'1.0.1/bootstrap.sh').exists()

def test_two_products_same_version_do_not_collide(tmp_path):
    p=Publisher(tmp_path,stub_gates=True);p.register_fixture()
    first=package(tmp_path/'first.tar.gz',{'payload/first':b'first'})
    second=package(tmp_path/'second.tar.gz',{'payload/second':b'second'})
    success(p.run(archive=first));success(p.run(product='pish',archive=second))
    assert (p.www/'releases/fixtureprod/1.0.1/first.tar.gz').read_bytes()==first.read_bytes()
    assert (p.www/'releases/pish/1.0.1/second.tar.gz').read_bytes()==second.read_bytes()

def test_assessment_retains_legacy_bootstrap_layout(tmp_path):
    p=Publisher(tmp_path,stub_gates=True);success(p.run(product='assessment'))
    release=json.loads((p.www/'channels/assessment-stable.json').read_text())['releases'][0]
    assert release['bootstrap']['url']=='https://update.neosecra.com/releases/1.0.1/bootstrap.sh'
    assert (p.www/'releases/1.0.1/bootstrap.sh').read_bytes()==(p.root/'bootstrap.sh').read_bytes()

def test_dry_run_does_not_change_channels_artifacts_or_remote(tmp_path):
    p=Publisher(tmp_path);p.register_fixture();p.seed();before=p.snapshot()
    success(p.run(dry=True,remote=True));assert p.snapshot()==before
    assert not (tmp_path/'transfer.log').exists()
    assert not (tmp_path/'gate.log').exists()

def test_old_release_bytes_and_urls_are_preserved(tmp_path):
    p=Publisher(tmp_path);p.register_fixture();source=p.seed()
    old=source.read_bytes().decode();a,b=spans(old)[0]['releases'];old_releases=old[a+1:b-1]
    success(p.run())
    new=source.read_bytes().decode()
    assert old_releases in new
    assert json.loads(new)['releases'][0]==json.loads(old)['releases'][0]

def test_hotspot_field_set_matches_current_candidate_contract(tmp_path):
    p=Publisher(tmp_path,stub_gates=True)
    migration=migration_off(tmp_path/'migration.json')
    success(p.run(product='hotspot',channel='candidate',migration=migration))
    new=json.loads((p.www/'channels/hotspot-candidate.json').read_text())['releases'][-1]
    old=json.loads((ROOT/'channels/hotspot-candidate.json').read_text())['releases'][-1]
    assert set(new)==set(old)
    assert set(new['migration_contract'])==set(old['migration_contract'])
    assert new['bootstrap']['sha256']==hashlib.sha256((p.root/'update-server/bootstrap-hotspot.sh').read_bytes()).hexdigest()
    assert new['backup_required'] is False

@pytest.mark.parametrize('name',['payload/.env','payload/private.key','payload/private.pem','payload/store.p12','payload/id_rsa','payload/id_ed25519','payload/.env.production'])
def test_secret_looking_archive_member_blocks_publish(tmp_path,name):
    p=Publisher(tmp_path);p.register_fixture();p.seed();before=p.snapshot()
    archive=package(tmp_path/'secret.tar.gz',{name:b'test-only data'})
    result=p.run(archive=archive)
    assert result.returncode!=0 and 'secret-looking file' in result.stdout+result.stderr
    assert p.snapshot()==before

@pytest.mark.parametrize('name',['../escape','/absolute','payload/../escape','C:/escape','payload\\escape'])
def test_archive_traversal_blocks_publish(tmp_path,name):
    p=Publisher(tmp_path);p.register_fixture()
    result=p.run(archive=package(tmp_path/'unsafe.tar.gz',{name:b'fixture'}))
    assert result.returncode!=0 and 'unsafe archive path' in result.stdout+result.stderr

def test_archive_symlink_is_rejected(tmp_path):
    p=Publisher(tmp_path);p.register_fixture();archive=tmp_path/'link.tar.gz'
    with tarfile.open(archive,'w:gz') as stream:
        member=tarfile.TarInfo('payload/link');member.type=tarfile.SYMTYPE;member.linkname='../../outside';stream.addfile(member)
    result=p.run(archive=archive)
    assert result.returncode!=0 and 'unsafe archive link' in result.stdout+result.stderr

def test_exact_test_secret_allowlist_only(tmp_path):
    p=Publisher(tmp_path);p.register_fixture();reg=p.root/'products/fixtureprod.json'
    data=json.loads(reg.read_text());data['secret_allowlist']=['tests/fixtures/test.pem'];reg.write_text(json.dumps(data))
    success(p.run(archive=package(tmp_path/'test.tar.gz',{'fixtureprod/tests/fixtures/test.pem':b'fixture'})))
    result=p.run(version='1.0.2',archive=package(tmp_path/'outside.tar.gz',{'payload/private.pem':b'fixture'}))
    assert result.returncode!=0

@pytest.mark.parametrize('version',['0.0.1','0.1.0'])
def test_anti_rollback_and_immutable_version_are_preserved(tmp_path,version):
    p=Publisher(tmp_path);p.register_fixture();p.seed();before=p.snapshot()
    result=p.run(version=version)
    assert result.returncode!=0
    assert 'not newer' in result.stderr or 'immutable release violation' in result.stderr
    assert p.snapshot()==before

def test_required_trust_tool_has_no_fallback(tmp_path):
    p=Publisher(tmp_path,stub_gates=True)
    (p.bin/'cosign').unlink()
    result=p.run(product='pish')
    assert result.returncode!=0 and 'cosign is required' in result.stderr

def test_source_drift_blocks_before_activation(tmp_path):
    p=Publisher(tmp_path);p.register_fixture();source=p.seed()
    source.write_bytes(source.read_bytes()+b'\n');fake_signature(source);before=p.snapshot()
    result=p.run();assert result.returncode!=0 and 'source drift' in result.stderr
    assert p.snapshot()==before

def test_reusing_identical_release_across_channels_preserves_artifacts(tmp_path):
    p=Publisher(tmp_path,stub_gates=True)
    archive,bundle,lock=soc_inputs(tmp_path)
    success(p.run(product='soc',channel='beta',archive=archive,bundle=bundle,lock=lock))
    release=p.www/'releases/soc/1.0.1';before={f.name:f.read_bytes() for f in release.iterdir()}
    success(p.run(product='soc',channel='stable',archive=archive,bundle=bundle,lock=lock))
    assert {f.name:f.read_bytes() for f in release.iterdir()}==before

def test_activation_rename_failure_restores_both_pairs(tmp_path,monkeypatch):
    activate=importlib.import_module('activate')
    pairs=[];before={}
    for name in ('www','source'):
        root=tmp_path/name;root.mkdir();old=root/'channel.json';new=root/'candidate.json'
        old.write_bytes(b'old');fake_signature(old);new.write_bytes(b'new');fake_signature(new)
        pairs.append((new,old));before[old]=old.read_bytes();before[Path(str(old)+'.minisig')]=Path(str(old)+'.minisig').read_bytes()
    monkeypatch.setattr(activate,'signature',lambda *args: None)
    original=activate.os.replace;calls=0
    def failure(source,destination):
        nonlocal calls
        calls+=1
        if calls==4: raise OSError('injected rename failure')
        return original(source,destination)
    monkeypatch.setattr(activate.os,'replace',failure)
    with pytest.raises(OSError): activate.activate(pairs,tmp_path/'keyring')
    assert all(path.read_bytes()==content for path,content in before.items())


def test_registered_steps_compose_for_a_new_product(tmp_path):
    p=Publisher(tmp_path);p.register_fixture()
    reg=json.loads((p.root/'products/soc.json').read_text())
    reg.update(code='fixtureprod',aliases=[],migration_metadata='required',steps=['bundle-lock','migration-contract'],gate={'script':'ci/prerelease-gate.sh','channels':['stable'],'inputs':['archive','version','trust-policy','registry']})
    (p.root/'products/fixtureprod.json').write_text(json.dumps(reg))
    archive,bundle,lock=soc_inputs(tmp_path)
    success(p.run(archive=archive,bundle=bundle,lock=lock,migration=migration_off(tmp_path/'migration.json')))
    release=json.loads((p.www/'channels/fixtureprod-stable.json').read_text())['releases'][0]
    assert release['images'] and release['migration_contract']
    assert release['backup_required'] is False


def test_gate_cannot_mutate_final_bundle(tmp_path):
    p=Publisher(tmp_path,stub_gates=True)
    gate=p.root/'ci/prerelease-gate-soc.sh'
    gate.write_text('#!/usr/bin/env bash\nwhile [[ $# -gt 0 ]]; do if [[ "$1" == --bundle ]]; then printf mutation >> "$2"; fi; shift 2; done\n',encoding='utf-8')
    archive,bundle,lock=soc_inputs(tmp_path)
    before=p.snapshot();result=p.run(product='soc',archive=archive,bundle=bundle,lock=lock)
    assert result.returncode!=0 and 'modified the final release inputs' in result.stderr
    assert p.snapshot()==before


def test_verified_channel_inodes_are_renamed_without_copy(tmp_path,monkeypatch):
    activate=importlib.import_module('activate');pairs=[];verified={}
    for name in ('www','source'):
        root=tmp_path/name;root.mkdir();candidate=root/'candidate.json';destination=root/'channel.json'
        candidate.write_bytes(b'verified');fake_signature(candidate);pairs.append((candidate,destination))
    def record(candidate,keyring):
        verified[candidate]=(candidate.stat().st_ino,Path(str(candidate)+'.minisig').stat().st_ino)
    monkeypatch.setattr(activate,'signature',record)
    activate.activate(pairs,tmp_path/'public-keys')
    for candidate,destination in pairs:
        assert (destination.stat().st_ino,Path(str(destination)+'.minisig').stat().st_ino)==verified[candidate]


@pytest.mark.parametrize('existing_version,should_pass',[('0.1.0',True),('2.0.0',False)])
def test_remote_activation_checks_signed_existing_version_offline(tmp_path,monkeypatch,existing_version,should_pass):
    import remote
    from channel import metadata
    root=tmp_path/'remote';incoming='.publish-incoming.fixture';stage=root/incoming
    relative='releases/fixtureprod/1.0.1';release=stage/relative;release.mkdir(parents=True)
    payload=release/'fixtureprod-1.0.1.tar.gz';package(payload)
    digest=hashlib.sha256(payload.read_bytes()).hexdigest()
    Path(str(payload)+'.sha256').write_text(digest+'  '+payload.name+'\n');fake_signature(payload)
    reg=json.loads((ROOT/'tests/fixtures/fixtureprod.json').read_text());(stage/'registry.json').write_text(json.dumps(reg))
    data={'product':'fixtureprod','product_code':'fixtureprod','edition':'standard','channel':'fixtureprod-stable','status':'available','current_version':'1.0.1','releases':[{'version':'1.0.1','archive':metadata(payload,relative),'bootstrap':None}]}
    candidate=stage/'channels/fixtureprod-stable.json';candidate.parent.mkdir();candidate.write_text(json.dumps(data));fake_signature(candidate)
    existing=root/'channels/fixtureprod-stable.json';existing.parent.mkdir()
    old=dict(data,current_version=existing_version,releases=[dict(data['releases'][0],version=existing_version)])
    existing.write_text(json.dumps(old));fake_signature(existing)
    before={p.name:p.read_bytes() for p in existing.parent.iterdir()}
    def adapter(file,keyring):
        assert Path(str(file)+'.minisig').read_text().strip()==hashlib.sha256(Path(file).read_bytes()).hexdigest()
    monkeypatch.setattr(remote,'signature',adapter)
    monkeypatch.setattr(remote,'artifact',lambda file,keyring: adapter(file,keyring))
    import activate
    monkeypatch.setattr(activate,'signature',adapter)
    if should_pass:
        remote.publish(root,incoming,relative,candidate.name)
        assert json.loads(existing.read_text())['current_version']=='1.0.1'
        assert (root/relative/payload.name).is_file()
    else:
        with pytest.raises(ValueError,match='not newer'): remote.publish(root,incoming,relative,candidate.name)
        assert {p.name:p.read_bytes() for p in existing.parent.iterdir()}==before
        assert not (root/relative).exists()
    assert not stage.exists()


@pytest.mark.parametrize('failure',[None,'signature','attestation'])
def test_cosign_gate_authenticates_artifact_images_offline(tmp_path,monkeypatch,failure):
    import cosign_gate
    from types import SimpleNamespace
    digest='sha256:'+'a'*64
    manifest={'product':'fixtureprod','version':'1.0.1','images':{'backend':{'reference':'registry.example/backend:1.0.1','digest':digest}}}
    sbom={'spdxVersion':'SPDX-2.3','packages':[{'name':'fixture'}]}
    archive=package(tmp_path/'attested.tar.gz',{'payload/release-manifest.json':json.dumps(manifest).encode(),'payload/backend.spdx.json':json.dumps(sbom).encode()})
    calls=[]
    def tool(command,**kwargs):
        calls.append(command)
        reject=(failure=='signature' and command[1]=='verify') or (failure=='attestation' and command[1]=='verify-attestation')
        return SimpleNamespace(returncode=1 if reject else 0)
    monkeypatch.setattr(cosign_gate.subprocess,'run',tool)
    if failure:
        with pytest.raises(ValueError,match='verification failed'): cosign_gate.check(archive,'1.0.1',[tmp_path/'pinned.pub'])
    else:
        cosign_gate.check(archive,'1.0.1',[tmp_path/'pinned.pub'])
        assert {c[1] for c in calls}=={'verify','verify-attestation'}
    assert all(c[-1]=='registry.example/backend:1.0.1@'+digest for c in calls)


def test_cosign_gate_rejects_missing_spdx_and_mutable_images(tmp_path):
    import cosign_gate
    manifest={'version':'1.0.1','images':{'backend':{'reference':'registry.example/backend:1.0.1','digest':'sha256:'+'a'*64}}}
    archive=package(tmp_path/'missing.tar.gz',{'payload/release-manifest.json':json.dumps(manifest).encode()})
    with pytest.raises(ValueError,match='SPDX SBOMs are missing'): cosign_gate.contract(archive,'1.0.1')
    manifest['images']['backend'].pop('digest')
    archive=package(tmp_path/'mutable.tar.gz',{'payload/release-manifest.json':json.dumps(manifest).encode()})
    with pytest.raises(ValueError,match='not immutable'): cosign_gate.contract(archive,'1.0.1')



def test_activation_rejects_different_signed_candidates(tmp_path,monkeypatch):
    activate=importlib.import_module('activate');pairs=[]
    for name in ('www','source'):
        root=tmp_path/name;root.mkdir();candidate=root/'candidate.json';destination=root/'channel.json'
        candidate.write_bytes(name.encode());fake_signature(candidate);destination.write_bytes(b'old');fake_signature(destination);pairs.append((candidate,destination))
    monkeypatch.setattr(activate,'signature',lambda *args: None)
    with pytest.raises(ValueError,match='SHA-256 mismatch'): activate.activate(pairs,tmp_path/'pins')
    assert all(destination.read_bytes()==b'old' for _,destination in pairs)


@pytest.mark.parametrize('name',['fixtureprod-1.0.1.tar.gz.minisig','bootstrap.sh.sha256','bundle.minisig'])
def test_bundle_cannot_shadow_signed_artifacts(tmp_path,name):
    p=Publisher(tmp_path);p.register_fixture();bundle=package(tmp_path/name,{'manifest.json':b'[]'})
    before=p.snapshot();result=p.run(bundle=bundle)
    assert result.returncode!=0 and 'conflicting bundle filename' in result.stderr
    assert p.snapshot()==before

@pytest.mark.parametrize('product,flag',[('soc','--bundle'),('hotspot','--migration-metadata')])
def test_missing_required_inputs_fail_before_active_staging(tmp_path,product,flag):
    p=Publisher(tmp_path);lock=None
    if product=='soc': lock=tmp_path/'images.lock';_lock(lock)
    result=p.run(product=product,channel='stable',lock=lock)
    assert result.returncode!=0 and flag+' is required' in result.stderr
    assert not p.www.exists()


def test_optional_registered_steps_skip_absent_inputs(tmp_path):
    p=Publisher(tmp_path);p.register_fixture();reg=json.loads((p.root/'products/soc.json').read_text())
    reg.update(code='fixtureprod',aliases=[],migration_metadata='optional',steps=['bundle-lock','migration-contract'],gate={'script':'ci/prerelease-gate.sh','channels':['stable'],'inputs':['archive','version','trust-policy','registry']})
    reg['bundle']['requirement']='optional';reg['images_lock']['requirement']='optional'
    (p.root/'products/fixtureprod.json').write_text(json.dumps(reg))
    success(p.run())
    release=json.loads((p.www/'channels/fixtureprod-stable.json').read_text())['releases'][0]
    assert 'images' not in release and 'migration_contract' not in release and 'docker_bundle' not in release


def test_activation_backup_write_failure_cleans_temporaries(tmp_path,monkeypatch):
    import activate
    candidate=tmp_path/'candidate.json'
    destination=tmp_path/'active.json'
    candidate.write_bytes(b'new')
    Path(str(candidate)+'.minisig').write_bytes(b'new signature')
    destination.write_bytes(b'old')
    Path(str(destination)+'.minisig').write_bytes(b'old signature')
    monkeypatch.setattr(activate,'signature',lambda *args: None)
    def failed_flush(fd): raise OSError('injected backup disk failure')
    monkeypatch.setattr(activate.os,'fsync',failed_flush)
    with pytest.raises(OSError,match='backup disk failure'):
        activate.activate([(candidate,destination)],tmp_path)
    assert destination.read_bytes()==b'old'
    assert Path(str(destination)+'.minisig').read_bytes()==b'old signature'
    assert not list(tmp_path.glob('.publish-backup-*'))


@pytest.mark.parametrize('manifest_pin',['digest','reference'])
def test_cosign_gate_rejects_lock_manifest_digest_disagreement(tmp_path,manifest_pin):
    import cosign_gate
    reference='registry.example/image'
    manifest_digest='sha256:'+('1'*64)
    lock_digest='sha256:'+('2'*64)
    row={'reference':reference,'digest':manifest_digest} if manifest_pin=='digest' else {'reference':reference+'@'+manifest_digest}
    archive=package(tmp_path/'mismatch.tar.gz',{
        'release/release-manifest.json':json.dumps({'version':'1.0.1','images':{'backend':row}}).encode(),
        'release/images.lock':('backend='+reference+'@'+lock_digest+'\n').encode(),
        'release/package.spdx.json':json.dumps({'spdxVersion':'SPDX-2.3','packages':[{'name':'fixture'}]}).encode(),
    })
    with pytest.raises(ValueError,match='digest differs from manifest'):
        cosign_gate.contract(archive,'1.0.1')
