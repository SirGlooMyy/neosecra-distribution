import importlib.util
import json
from pathlib import Path
import sys
import jsonschema
import pytest
from fixtures.publisher import ROOT, Publisher, package

sys.path.insert(0,str(ROOT/'update-server/lib'))
from registry import load_registry, validate_channel, validate_empty_channel, read_json, validate_schema

@pytest.mark.parametrize('product',['hotspot','soc','assessment','pish'])
def test_canonical_records_match_schema(product):
    schema=read_json(ROOT/'schemas/product-registry.schema.json')
    data=read_json(ROOT/'products'/(product+'.json'))
    jsonschema.validate(data,schema)
    assert load_registry(ROOT,product)==data
    assert data['trust_policy']=='minisign-package-v1'

@pytest.mark.parametrize('product',['assessment','pish'])
def test_minisign_policy_preserves_existing_package_contract(product):
    data=load_registry(ROOT,product)
    assert data['bundle']=={'requirement':'optional','format':'docker-save-tar'}
    assert data['images_lock']=={'requirement':'none','format':'none','services':[],'shared_services':[]}
    assert data['channel_defaults']['status']=='available'

def test_existing_channels_pass_unchanged():
    for path in (ROOT/'channels').glob('*.json'):
        before=path.read_bytes();data=read_json(path)
        product=data.get('product_code') or path.stem.rsplit('-',1)[0]
        reg=load_registry(ROOT,product)
        validate_channel(data,reg,path.stem)
        assert path.read_bytes()==before

@pytest.mark.parametrize('mutation,needle',[
    ({'product':'unknown'},'unregistered product'),
    ({'channel':'unknown'},'channel is not registered'),
    ({'product':'../escape'},'invalid product code'),
    ({'channel':'stable;echo'},'channel is not registered'),
    ({'version':'1.0.1;echo'},'numeric semver'),
])
def test_registry_preflight_is_fail_closed(tmp_path,mutation,needle):
    p=Publisher(tmp_path);p.register_fixture();before=p.snapshot()
    result=p.run(**mutation)
    assert result.returncode!=0
    assert needle in result.stdout+result.stderr
    assert p.snapshot()==before

def test_unknown_step_and_free_command_rejected(tmp_path):
    p=Publisher(tmp_path);p.register_fixture();path=p.root/'products/fixtureprod.json'
    data=json.loads(path.read_text());data['steps']=['unknown-step'];path.write_text(json.dumps(data))
    result=p.run();assert result.returncode!=0 and 'unknown-step' in result.stderr
    data['steps']=[];data['command']='echo unsafe';path.write_text(json.dumps(data))
    result=p.run();assert result.returncode!=0 and 'unknown field' in result.stderr

def test_fixture_product_needs_only_registration(tmp_path):
    p=Publisher(tmp_path);p.register_fixture();before=p.snapshot()
    (p.bin/'cosign').unlink()
    result=p.run(dry=True,remote=True)
    assert result.returncode==0,result.stdout+result.stderr
    assert p.snapshot()==before
    assert not (p.tmp/'transfer.log').exists()
    result=p.run();assert result.returncode==0,result.stdout+result.stderr
    data=json.loads((p.www/'channels/fixtureprod-stable.json').read_text())
    assert data['current_version']=='1.0.1'
    assert data['releases'][0]['bootstrap'] is None
    assert (p.www/'releases/fixtureprod/1.0.1/fixtureprod-1.0.1.tar.gz').is_file()
    assert (p.www/'channels/fixtureprod-stable.json.minisig').is_file()

def test_registry_channel_list_is_dynamic(tmp_path):
    p=Publisher(tmp_path);p.register_fixture()
    for path in (p.root/'products').glob('*.json'):
        data=json.loads(path.read_text())
        for channel in data['channels']: p.seed(data['code'],channel)
    result=p.shell([str(p.root/'bin/validate-channels.sh').replace('\\','/'),str(p.root).replace('\\','/')])
    assert result.returncode==0,result.stdout+result.stderr
    assert 'validated 8 registered channels' in result.stdout
    blocked=p.shell([str(p.root/'bin/validate-channels.sh').replace('\\','/'),str(p.root).replace('\\','/')],NEOSECRA_CHANNEL_PUBLIC_KEY=str(tmp_path/'missing.pub').replace('\\','/'))
    assert blocked.returncode!=0 and 'missing explicitly pinned' in blocked.stderr

def test_schema_runtime_validator_rejects_same_invalid_records():
    schema=read_json(ROOT/'schemas/product-registry.schema.json');data=read_json(ROOT/'products/soc.json')
    for invalid in [dict(data,trust_policy='fallback'),dict(data,code='../escape'),dict(data,steps=['../escape']),dict(data,bootstrap='../../external.sh')]:
        with pytest.raises(jsonschema.ValidationError): jsonschema.validate(invalid,schema)
        with pytest.raises(ValueError): validate_schema(invalid,schema)


@pytest.mark.parametrize('status',['reserved','unavailable'])
def test_legacy_empty_channel_is_explicitly_unpublished(status):
    reg=load_registry(ROOT,'assessment')
    data=dict(read_json(ROOT/'channels/assessment-beta.json'),status=status)
    assert validate_empty_channel(data,reg,'assessment-beta')==data


@pytest.mark.parametrize('mutation',[
    {'status':'available'}, {'status':'unknown'}, {'status':None},
    {'current_version':'1.0.0'}, {'current_version':''},
    {'releases':[{'version':'1.0.0'}]}, {'product':'soc'},
])
def test_legacy_empty_channel_rejects_publishable_or_invalid_metadata(mutation):
    reg=load_registry(ROOT,'assessment')
    data=dict(read_json(ROOT/'channels/assessment-beta.json'),**mutation)
    with pytest.raises(ValueError): validate_empty_channel(data,reg,'assessment-beta')


def test_legacy_empty_channel_requires_explicit_null_and_registration():
    reg=load_registry(ROOT,'assessment');data=read_json(ROOT/'channels/assessment-beta.json')
    missing=dict(data);missing.pop('current_version')
    with pytest.raises(ValueError): validate_empty_channel(missing,reg,'assessment-beta')
    with pytest.raises(ValueError): validate_empty_channel(data,dict(reg,legacy_empty_channels=[]),'assessment-beta')
    with pytest.raises(ValueError): validate_empty_channel(data,dict(reg,channels=['stable']),'assessment-beta')


def validator_fixture(tmp_path):
    p=Publisher(tmp_path)
    for path in (p.root/'products').glob('*.json'):
        reg=read_json(path)
        for channel in reg['channels']: p.seed(reg['code'],channel)
    for root in (p.root,p.www):
        beta=root/'channels/assessment-beta.json'
        beta.write_bytes((ROOT/'channels/assessment-beta.json').read_bytes())
        Path(str(beta)+'.minisig').unlink()
    return p


@pytest.mark.parametrize('www_arg',['omitted','empty','present','python-fallback'])
def test_validator_accepts_only_unsigned_reservation_and_counts_seven(tmp_path,www_arg):
    p=validator_fixture(tmp_path);before=p.snapshot()
    if www_arg=='python-fallback':
        (p.bin/'python').write_bytes((p.bin/'python3').read_bytes())
        (p.bin/'python').chmod(0o755)
        (p.bin/'python3').write_text('#!/usr/bin/env bash\nexit 1\n',encoding='utf-8')
    args=[str(p.root/'bin/validate-channels.sh').replace('\\','/'),str(p.root).replace('\\','/')]
    if www_arg=='empty': args.append('')
    if www_arg=='present': args.append(str(p.www).replace('\\','/'))
    result=p.shell(args)
    assert result.returncode==0,result.stdout+result.stderr
    assert result.stdout.strip()=='validated 7 registered channels'
    assert p.snapshot()==before


@pytest.mark.parametrize('failure',[
    'available','release','unregistered','published-unsigned','missing-signed','bad-signature',
    'www-json-drift','www-reservation-signature','www-signed-signature-drift',
])
def test_validator_reservation_exception_remains_fail_closed(tmp_path,failure):
    p=validator_fixture(tmp_path);beta=p.root/'channels/assessment-beta.json'
    data=read_json(beta)
    if failure=='available': data['status']='available'
    if failure in ['release','published-unsigned']:
        data['releases']=read_json(p.root/'channels/assessment-stable.json')['releases']
        if failure=='published-unsigned': data['current_version']=data['releases'][0]['version']
    beta.write_text(json.dumps(data),encoding='utf-8')
    if failure=='unregistered':
        path=p.root/'products/assessment.json';reg=read_json(path);reg['legacy_empty_channels']=[]
        path.write_text(json.dumps(reg),encoding='utf-8')
    if failure=='missing-signed': (p.root/'channels/soc-beta.json.minisig').unlink()
    if failure=='bad-signature': Path(str(beta)+'.minisig').write_text('invalid signature',encoding='utf-8')
    www_beta=p.www/'channels/assessment-beta.json';www_beta.write_bytes(beta.read_bytes())
    if failure=='www-json-drift': www_beta.write_bytes(beta.read_bytes()+b'\n')
    if failure=='www-reservation-signature': Path(str(www_beta)+'.minisig').write_text('stale signature',encoding='utf-8')
    if failure=='www-signed-signature-drift': (p.www/'channels/soc-beta.json.minisig').write_text('invalid signature',encoding='utf-8')
    before=p.snapshot()
    result=p.shell([str(p.root/'bin/validate-channels.sh').replace('\\','/'),str(p.root).replace('\\','/'),str(p.www).replace('\\','/')])
    assert result.returncode!=0,result.stdout+result.stderr
    assert 'validated 7 registered channels' not in result.stdout
    assert p.snapshot()==before
