import json
from datetime import datetime, timedelta, timezone
from pathlib import Path
import subprocess

import pytest

from workspace_watcher.scoring.ai import LocalProvider, extract, _validate_choice, compact_projects, compare, current_comparisons
from workspace_watcher.scoring.evidence import EvidenceStore, record, union_seconds
from workspace_watcher.scoring.sources import Attribution, ingest_jsonl, ingest_documents, ingest_git, ingest_chatgpt
from workspace_watcher.scoring.engine import calculate, composite

NOW=datetime(2026,9,27,tzinfo=timezone.utc)


def observation(source='source',value=None):
    return record(source_type='codex',source_id=source,project_id='a',category='conversation_excerpt',
                  value=value or {'text':'The next release is blocked by login.'},at=NOW.isoformat(),reference='file#byte=0')


class FakeProvider:
    identity='fake-local-model'
    calls=0
    fail=False
    def infer(self,instruction,payload):
        self.calls+=1
        if self.fail:raise OSError('offline')
        if 'evidence_id' in payload:
            return {'claims':[{'category':'blocker','text':'Login blocks release.','reference':payload['evidence_id'],'confidence':.8}]},'fake-v1'
        p=payload['projects'][0]
        # Stable preference independent of prompt order.
        return {'winner':'a','rationale':[{'project_id':p['id'],'reason':'Based on supplied urgency.','references':[p['metrics']['urgency']['reference']]}]},'fake-v1'


def test_incremental_codex_cwd_and_partial_line(tmp_path):
    root=tmp_path/'Alpha';root.mkdir()
    attribution=Attribution([{'id':'a','name':'Alpha','path':'Alpha','status':'active'}],tmp_path)
    path=tmp_path/'conversation.jsonl'
    meta={'type':'session_meta','payload':{'cwd':str(root)}}
    message={'timestamp':NOW.isoformat(),'type':'response_item','payload':{'type':'message','role':'assistant','content':[{'type':'output_text','text':'Implemented authentication.'}]}}
    path.write_text(json.dumps(meta)+'\n'+json.dumps(message)+'\n')
    store=EvidenceStore(tmp_path/'evidence.db')
    assert ingest_jsonl(store,path,'codex',attribution,10)['ingested']==1
    assert ingest_jsonl(store,path,'codex',attribution,10)['ingested']==0
    with path.open('a') as f:f.write(json.dumps(message))
    assert ingest_jsonl(store,path,'codex',attribution,10)['ingested']==0
    with path.open('a') as f:f.write('\n')
    assert ingest_jsonl(store,path,'codex',attribution,10)['ingested']==1
    assert len(store.records())==2
    path.write_text(json.dumps(meta)+'\n')
    assert ingest_jsonl(store,path,'codex',attribution,10)['reset']
    assert store.records()==[]


def test_claude_roles_and_ambiguous_attribution(tmp_path):
    root=tmp_path/'Alpha';root.mkdir()
    attribution=Attribution([{'id':'a','name':'Alpha','path':'Alpha','status':'active'}, {'id':'b','name':'Alpha','path':'Other','status':'active'}],tmp_path)
    assert attribution.event({'title':'Alpha terminal'}) is None
    assert attribution.path(str(root))==('a',1.0,'explicit path')
    path=tmp_path/'claude.jsonl';path.write_text(json.dumps({'timestamp':NOW.isoformat(),'cwd':str(root),'message':{'role':'user','content':'This matters'}})+'\n')
    store=EvidenceStore(tmp_path/'evidence.db')
    assert ingest_jsonl(store,path,'claude',attribution,10)['ingested']==1
    assert store.records()[0]['origin']=='human'


def test_interval_union_deduplicates_overlapping_sensors():
    assert union_seconds([(NOW,NOW+timedelta(hours=2)),(NOW+timedelta(hours=1),NOW+timedelta(hours=3))])==10800


def test_ai_extraction_cache_stale_dependencies_and_offline(tmp_path):
    store=EvidenceStore(tmp_path/'evidence.db');r=observation();store.ingest('source',[r])
    provider=FakeProvider()
    assert extract(store,provider,3)['calls']==1
    assert extract(store,provider,3)['calls']==0
    claims=[e for e in store.summary()['records'] if e['provenance']=='llm_extracted']
    assert len(claims)==1 and not claims[0]['stale']
    store.ingest('source',[observation(value={'text':'Now fixed'})],reset=True)
    assert next(e for e in store.summary()['records'] if e['provenance']=='llm_extracted')['stale']
    provider.fail=True
    assert extract(store,provider,1)['errors']==['offline']
    assert len(store.records())==2


def test_ai_rejects_fabricated_citations(tmp_path):
    store=EvidenceStore(tmp_path/'evidence.db');store.ingest('source',[observation()])
    class Bad(FakeProvider):
        def infer(self,*args):return {'claims':[{'category':'blocker','text':'x','reference':'fabricated','confidence':.9}]},'bad'
    assert extract(store,Bad(),1)['errors']
    assert all(e['provenance']=='observed' for e in store.records())


@pytest.mark.parametrize('url',['https://api.openai.com/v1','http://192.168.1.2:1234/v1','http://localhost:1234/v1?forward=x','http://user@localhost/v1'])
def test_cloud_inference_forbidden(url):
    with pytest.raises(ValueError):LocalProvider(url,'model')


def test_document_hash_reprocessing_and_git_is_only_evidence(tmp_path):
    root=tmp_path/'project';root.mkdir();p=root/'README.md';p.write_text('Goal: ship a release.')
    store=EvidenceStore(tmp_path/'evidence.db')
    assert ingest_documents(store,root,'a',10)['ingested']==1
    assert ingest_documents(store,root,'a',10)['ingested']==0
    subprocess.run(['git','init','-q',str(root)],check=True)
    subprocess.run(['git','-C',str(root),'add','README.md'],check=True)
    subprocess.run(['git','-C',str(root),'-c','user.name=Test','-c','user.email=test@example.invalid','-c','commit.gpgsign=false','commit','-qm','Initial docs'],check=True)
    assert ingest_git(store,root,'a',10)['ingested']==1
    assert ingest_git(store,root,'a',10)['ingested']==0
    assert any(e['category']=='git_commit' for e in store.records())
    assert calculate(sessions=[],now=NOW)['progress']['state']=='unknown'


def test_chatgpt_export_resume_and_explicit_mapping(tmp_path):
    path=tmp_path/'export.json'
    path.write_text(json.dumps([{'id':'c','mapping':{str(i):{'message':{'author':{'role':'user'},'content':{'parts':['Plan a feature']},'create_time':NOW.timestamp()}} for i in range(3)}}]))
    store=EvidenceStore(tmp_path/'evidence.db')
    assert ingest_chatgpt(store,path,'a',1)['ingested']==1
    assert ingest_chatgpt(store,path,'a',1)['ingested']==1
    assert ingest_chatgpt(store,path,'a',1)['complete']
    assert ingest_chatgpt(store,path,'a',1)['ingested']==0
    assert len(store.records())==3


def test_pairwise_cache_invalidation_and_call_budget(tmp_path):
    profile={'id':'x','name':'Urgent','weights':{'urgency':1},'missing_policy':'require_all','allow_provisional':False}
    rows=[]
    for pid in ['a','b']:
        dims=calculate(sessions=[],ratings={'urgency':5},now=NOW)
        rows.append({'id':pid,'name':pid,'dimensions':dims,'composites':{'x':composite(dims,profile,now=NOW)}})
    class Profiles:
        def profiles(self):return {'x':profile}
    class Service:
        store=Profiles()
        def projects(self,**kwargs):return {'projects':rows}
    service=Service();store=EvidenceStore(tmp_path/'evidence.db');provider=FakeProvider()
    assert compare(service,store,provider,'x',1)['calls']==0
    result=compare(service,store,provider,'x',2)
    assert result['calls']==2 and result['comparisons'][0]['winner']=='a'
    assert compare(service,store,provider,'x',2)['calls']==0
    assert not current_comparisons(rows,store.summary(),{'x':profile})[0]['stale']
    rows[0]['dimensions']['urgency']['value']=75
    assert current_comparisons(rows,store.summary(),{'x':profile})[0]['stale']


def test_activitywatch_afk_intersection_and_weak_title_attribution(tmp_path,monkeypatch):
    from workspace_watcher.scoring.sources import ingest_activitywatch
    attribution=Attribution([{'id':'a','name':'Alpha','path':'Alpha','status':'active'}],tmp_path)
    def event(eid,start,end,data):
        return {'id':eid,'timestamp':(NOW+timedelta(seconds=start)).isoformat(),'duration':end-start,'data':data}
    buckets={'afk':{'type':'afkstatus','hostname':'host'},'editor':{'type':'app.editor.activity','hostname':'host'},'window':{'type':'currentwindow','hostname':'host'}}
    values={'afk':[event(1,0,60,{'status':'not-afk'}),event(2,60,100,{'status':'afk'})],
            'editor':[event(3,0,100,{'file':str(tmp_path/'Alpha/main.py')})],
            'window':[event(4,0,100,{'title':'Alpha editor'})]}
    class Response:
        def __init__(self,value):self.value=value
        def __enter__(self):return self
        def __exit__(self,*args):pass
        def read(self):return json.dumps(self.value).encode()
    def request(url,**kwargs):
        return Response(buckets if url.endswith('buckets/') else values[url.split('/buckets/')[1].split('/')[0]])
    monkeypatch.setattr('workspace_watcher.scoring.sources.urlopen',request)
    store=EvidenceStore(tmp_path/'evidence.db')
    result=ingest_activitywatch(store,attribution,100)
    assert sum(x['ingested'] for x in result['buckets'])==2
    records=store.records()
    assert all(e['value']['not_afk_seconds']==60 for e in records)
    assert sorted(e['confidence'] for e in records)==[.45,1.0]
    assert ingest_activitywatch(store,attribution,100)['buckets']==[]


def test_document_symlink_cannot_read_outside_project(tmp_path):
    root=tmp_path/'project';root.mkdir();outside=tmp_path/'private';outside.mkdir()
    (outside/'plan.md').write_text('private')
    (root/'docs').symlink_to(outside,target_is_directory=True)
    store=EvidenceStore(tmp_path/'evidence.db')
    assert ingest_documents(store,root,'a',100)['ingested']==0


def test_pairwise_prompt_order_disagreement_is_a_tie(tmp_path):
    profile={'id':'x','name':'Urgency','weights':{'urgency':1}}
    rows=[]
    for pid in ['a','b']:
        dims=calculate(sessions=[],ratings={'urgency':5},now=NOW)
        rows.append({'id':pid,'name':pid,'dimensions':dims,'composites':{'x':composite(dims,profile)}})
    class Profiles:
        def profiles(self):return {'x':profile}
    class Service:
        store=Profiles()
        def projects(self,**kwargs):return {'projects':rows}
    class PositionBiased(FakeProvider):
        def infer(self,instruction,payload):
            p=payload['projects'][0]
            return {'winner':p['id'],'rationale':[{'project_id':p['id'],'reason':'First candidate.','references':[p['metrics']['urgency']['reference']]}]},'biased'
    result=compare(Service(),EvidenceStore(tmp_path/'evidence.db'),PositionBiased(),'x',2)
    assert result['comparisons'][0]['winner'] is None
    assert not result['comparisons'][0]['order_consistent']


def test_changed_or_deleted_document_invalidates_before_reingestion(tmp_path):
    root=tmp_path/'p';root.mkdir();path=root/'README.md';path.write_text('Blocked by authentication')
    store=EvidenceStore(tmp_path/'evidence.db')
    ingest_documents(store,root,'a',10)
    extract(store,FakeProvider(),1)
    assert all(not r['stale'] for r in store.summary()['records'])
    path.write_text('Authentication is fixed now.')
    assert all(r['stale'] for r in store.summary()['records'])
    assert extract(store,FakeProvider(),1)['calls']==0
    ingest_documents(store,root,'a',10)
    assert any(not r['stale'] for r in store.summary()['records'])
    path.unlink()
    assert all(r['stale'] for r in store.summary()['records'])
