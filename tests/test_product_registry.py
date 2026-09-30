import importlib.util
import json
from pathlib import Path
import sys
import jsonschema
import pytest
from fixtures.publisher import ROOT, Publisher, package

sys.path.insert(0,str(ROOT/'update-server/lib'))
from registry import load_registry, validate_channel, read_json, validate_schema

@pytest.mark.parametrize('product',['hotspot','soc','assessment','pish'])
def test_canonical_records_match_schema(product):
    schema=read_json(ROOT/'schemas/product-registry.schema.json')
    data=read_json(ROOT/'products'/(product+'.json'))
    jsonschema.validate(data,schema)
    assert load_registry(ROOT,product)==data

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
    result=p.run(dry=True,remote=True)
    assert result.returncode==0,result.stdout+result.stderr
    assert p.snapshot()==before
    assert not (p.tmp/'transfer.log').exists()
    result=p.run();assert result.returncode==0,result.stdout+result.stderr
    data=json.loads((p.www/'channels/fixtureprod-stable.json').read_text())
    assert data['current_version']=='1.0.1'
    assert data['releases'][0]['bootstrap'] is None
    assert (p.www/'releases/fixtureprod/1.0.1/fixtureprod-1.0.1.tar.gz').is_file()

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
