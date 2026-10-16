import json
from pathlib import Path
import sqlite3
import threading
from types import SimpleNamespace
from urllib.request import Request, urlopen
from urllib.error import HTTPError

import pytest

from workspace_watcher.core_api import serve
from workspace_watcher.intents import IntentFolderSettings
from workspace_watcher.scoring.service import ScoringService
from workspace_watcher.scoring.store import ScoringStore


@pytest.fixture
def local(tmp_path):
    db=tmp_path/'Logs'/'core.db';db.parent.mkdir()
    with sqlite3.connect(db) as conn:
        conn.execute('CREATE TABLE projects(id TEXT PRIMARY KEY,name TEXT,path TEXT,status TEXT)')
        conn.execute('CREATE TABLE sessions(id TEXT,project_id TEXT,status TEXT,started_at TEXT,ended_at TEXT,active_seconds REAL)')
        conn.executemany('INSERT INTO projects VALUES (?,?,?,?)', [('a','Alpha','Projects/Alpha','active'),('b','Beta','Projects/Beta','active')])
    for pid,name in [('a','Alpha'),('b','Beta')]:
        d=tmp_path/'Projects'/name;d.mkdir(parents=True)
        (d/'Project.betterproject').write_text(json.dumps({'formatVersion':1,'documentID':pid,'workspaceProjectID':pid,'notionProjectID':'remote-'+pid}))
    return ScoringService(db,tmp_path)


def test_read_model_creates_no_scoring_file_or_document_changes(local):
    docs={p:p.read_bytes() for p in local.root.glob('Projects/*/Project.betterproject')}
    assert len(local.projects()['projects'])==2
    assert not local.store.path.exists()
    assert all(p.read_bytes()==raw for p,raw in docs.items())


def test_explicit_manual_import_preview_idempotence_and_clear_precedence(local,tmp_path):
    cache=tmp_path/'cache.json';cache.write_text(json.dumps({'projects':[{'id':'remote-a','ratings':{'urgency':5,'legacy':3}}]}))
    assert local.import_manual_cache(cache)['candidates']==[{'id':'a','changed':True}]
    assert not local.store.path.exists()
    local.import_manual_cache(cache,apply=True)
    assert local.import_manual_cache(cache,apply=True)['candidates']==[{'id':'a','changed':False}]
    assert local.projects()['projects'][0]['dimensions']['urgency']['value']==100
    doc=local.root/'Projects/Alpha/Project.betterproject';d=json.loads(doc.read_text());d['localState']={'ratings':{}};doc.write_text(json.dumps(d))
    row=next(p for p in local.projects()['projects'] if p['id']=='a')
    assert row['dimensions']['urgency']['value'] is None
    assert local.store.records('manual_import')['a']['payload']['ratings']['legacy']==3


def test_malformed_document_does_not_break_other_projects(local):
    (local.root/'Projects/Alpha/Project.betterproject').write_text('{')
    rows=local.projects()['projects']
    assert len(rows)==2 and rows[0]['warnings']


def test_profiles_and_inputs_persist_with_revision_guards(local):
    p={'id':'urgent','name':'Urgent','weights':{'urgency':1}}
    assert local.save('profile','urgent',p)['revision']==1
    with pytest.raises(ValueError,match='revision conflict'):local.save('profile','urgent',p)
    assert local.save('profile','urgent',p,1)['revision']==2
    assert 'urgent' in ScoringStore(local.store.path).profiles()
    with pytest.raises(ValueError,match='unknown project'):local.save('inputs','missing',{'version':1})
    local.save('inputs','a',{'version':1,'cadence_days':7})
    assert local.store.records('inputs')['a']['revision']==1


def test_scoring_writes_rejected_inside_observed_project(local):
    local.store=ScoringStore(local.root/'Projects/Alpha/scoring.db')
    with pytest.raises(ValueError,match='outside'):local.save('inputs','a',{'version':1})
    assert not local.store.path.exists()


def test_real_http_query_profile_and_error_contract(local):
    config=SimpleNamespace(database_path=local.database,workspace_root=local.root,intent_settings=IntentFolderSettings.for_workspace(local.root))
    server=serve(config,port=0)
    thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
    def request(path,body=None):
        req=Request(f'http://127.0.0.1:{server.server_port}'+path,data=json.dumps(body).encode() if body is not None else None,headers={'Content-Type':'application/json'})
        try:
            with urlopen(req,timeout=3) as response:return response.status,json.load(response)['data']
        except HTTPError as error:return error.code,json.load(error)['data']
    try:
        status,catalog=request('/v1/scoring/catalog');assert status==200 and 'importance' in catalog['dimensions']
        assert request('/v1/scoring/query',{'view':'needs-data'})[0]==200
        assert request('/v1/scoring/query',{'query':{'dimension':'fake','op':'gt','value':0}})[0]==400
        assert request('/v1/scoring/profiles',{'id':'x','payload':{'id':'x','name':'X','weights':{'urgency':1}}})[0]==200
        assert request('/v1/scoring/projects')[0]==200
        assert request('/v1/scoring/query',{'profile_id':'unknown'})[0]==400
    finally:
        server.shutdown();thread.join();server.server_close()


def test_bad_outcomes_preserve_independent_manual_judgment(local):
    doc=local.root/'Projects/Alpha/Project.betterproject'
    data=json.loads(doc.read_text())
    data['localState']={'ratings':{'urgency':5},'scoring':{'version':1,'scopes':[{'id':'broken'}]}}
    doc.write_text(json.dumps(data))
    row=next(r for r in local.projects()['projects'] if r['id']=='a')
    assert row['dimensions']['urgency']['value']==100
    assert row['dimensions']['progress']['state']=='unknown'
    assert row['warnings']


def test_unobserved_lower_bound_starts_at_sensing_or_discovery_whichever_is_later(tmp_path):
    from datetime import datetime, timezone
    db = tmp_path/'Logs'/'core.db'; db.parent.mkdir()
    with sqlite3.connect(db) as conn:
        conn.execute('CREATE TABLE projects(id TEXT PRIMARY KEY,name TEXT,path TEXT,status TEXT,discovered_at TEXT)')
        conn.execute('CREATE TABLE sessions(id TEXT,project_id TEXT,status TEXT,started_at TEXT,ended_at TEXT,active_seconds REAL,files_json TEXT)')
        conn.executemany('INSERT INTO projects VALUES (?,?,?,?,?)', [('old','Old','Projects/Old','active','2026-09-01T00:00:00+00:00'),
                                                                    ('new','New','Projects/New','active','2026-10-05T00:00:00+00:00')])
        # Sensing began with a session in another project; a bulk session that was discarded still marks coverage.
        conn.execute("INSERT INTO sessions VALUES ('s','other','discarded','2026-09-12T00:00:00+00:00','2026-09-12T00:10:00+00:00',600,'[]')")
    service = ScoringService(db, tmp_path)
    now = datetime(2026, 10, 15, tzinfo=timezone.utc)
    ages = {p['id']: p['dimensions']['activity_age'] for p in service.projects(now=now)['projects']}
    assert round(ages['old']['raw_value']) == 33 and ages['old']['window']['unobserved_since'].startswith('2026-09-12')
    assert round(ages['new']['raw_value']) == 10 and ages['new']['window']['unobserved_since'].startswith('2026-10-05')
    assert all(a['state'] == 'provisional' for a in ages.values())
