from datetime import datetime, timedelta, timezone
import math
import pytest

from workspace_watcher.scoring.engine import calculate, composite
from workspace_watcher.scoring.model import METRICS, validate_inputs, validate_profile
from workspace_watcher.scoring.query import select

NOW = datetime(2026,9,27,12,tzinfo=timezone.utc)


def session(i="s", days=1, hours=2, status="completed"):
    end = NOW-timedelta(days=days)
    return {"id":i,"status":status,"started_at":(end-timedelta(hours=hours)).isoformat(),
            "ended_at":end.isoformat(),"active_seconds":hours*3600}


def coverage(days=100):
    return {"version":1,"observation":{"start":(NOW-timedelta(days=days)).isoformat(),"end":NOW.isoformat(),"complete":True}}


def scope_inputs():
    return {"version":1,"project_scope_id":"release","next_scope_id":"release","scopes":[
        {"id":"release","revision":"r1","defined":True,"blocked":False,"leaves":[
            {"id":"a","weight":3,"accepted":True}, {"id":"b","weight":1,"accepted":False,"remaining_hours":8}]}]}


def test_missing_is_not_zero_and_no_outcomes_from_activity():
    empty = calculate(sessions=[],now=NOW)
    assert all(v["value"] is None for v in empty.values())
    active = calculate(sessions=[session()],now=NOW)
    assert active["investment_observed"]["raw_value"] == 2
    assert active["investment_observed"]["state"] == "provisional"
    for k in ["progress","near_done","finishability","momentum_7d","importance","neglect"]:
        assert active[k]["state"] == "unknown"


def test_confirmed_zero_and_known_measurements():
    scores = calculate(sessions=[],inputs=coverage(),now=NOW)
    for k in ["investment_7d","activity_30d","consistency_84d"]:
        assert scores[k]["value"] == 0
        assert scores[k]["state"] == "known"
    assert scores["activity_age"]["value"] is None


def test_all_history_no_twenty_row_limit_and_ignore_discarded_open_duplicates():
    sessions = [session(str(i),days=i,hours=2) for i in range(1,41)]
    scores = calculate(sessions=sessions+[sessions[0],session("bad",status="discarded"),session("open",status="open")],now=NOW)
    assert scores["investment_observed"]["raw_value"] == 80
    assert scores["investment_7d"]["raw_value"] == 12  # seventh-day session ends at boundary
    assert scores["activity_age"]["raw_value"] == 1


def test_boundary_session_proportional_allocation():
    scores = calculate(sessions=[session(days=6.99,hours=24)],now=NOW)
    assert scores["investment_7d"]["raw_value"] == pytest.approx(.24)


@pytest.mark.parametrize("mutation",[{"active_seconds":float("nan")},{"ended_at":"bad"},{"ended_at":(NOW+timedelta(days=1)).isoformat()}])
def test_invalid_sessions_cannot_poison_scores(mutation):
    bad = {**session(),**mutation}
    scores = calculate(sessions=[bad],inputs=coverage(),now=NOW)
    assert scores["investment_observed"]["value"] is None
    assert scores["investment_observed"]["coverage"]["invalid_sessions"] == 1


def test_manual_legacy_formula_cost_direction_and_coverage():
    scores = calculate(sessions=[],ratings={"qualityOfLife":5},now=NOW)
    assert scores["manual_assessment"]["value"] == pytest.approx(50+50/21,abs=.0001)
    scores = calculate(sessions=[],ratings={"effort":5},now=NOW)
    assert scores["manual_assessment"]["value"] == pytest.approx(50-50/21,abs=.0001)
    assert scores["progress"]["value"] is None
    assert scores["importance"]["value"] is None


def test_manual_custom_configuration_and_zero_weights():
    config = {"enabled_groups":["timeExecution"],"enabled_metrics":["effort"],"group_weights":{"timeExecution":0}}
    scores = calculate(sessions=[],ratings={"effort":1},manual_config=config,now=NOW)
    assert scores["manual_assessment"]["value"] == 100
    assert scores["manual_assessment"]["state"] == "known"


def test_independent_judgment_not_influenced_by_effort():
    ratings = {"personalImportance":5,"goalAlignment":3,"dependencyImportance":1,"urgency":1}
    a = calculate(sessions=[],ratings=ratings,now=NOW)
    b = calculate(sessions=[session()],ratings=ratings,now=NOW)
    assert a["importance"]["value"] == b["importance"]["value"] == 65
    assert a["urgency"]["value"] == 0
    assert a["potential"]["value"] is None


def test_scope_progress_and_finishability():
    scores = calculate(sessions=[],inputs=scope_inputs(),now=NOW)
    assert scores["progress"]["value"] == scores["near_done"]["value"] == 75
    assert scores["finishability"]["value"] == 50
    assert scores["momentum_7d"]["value"] is None


def test_missing_estimates_do_not_mean_easy_and_completed_target_not_actionable():
    inputs=scope_inputs();del inputs["scopes"][0]["leaves"][1]["remaining_hours"]
    assert calculate(sessions=[],inputs=inputs,now=NOW)["finishability"]["value"] is None
    inputs["scopes"][0]["leaves"][1]["accepted"] = True
    assert calculate(sessions=[],inputs=inputs,now=NOW)["finishability"]["value"] is None


def test_delivery_history_reopens_and_duplicate_accepts():
    inputs=scope_inputs();s=inputs["scopes"][0]
    s.update(history_start=(NOW-timedelta(days=100)).isoformat(),planned_weight_per_week=3,
             events=[{"id":str(i),"leaf_id":"a","kind":kind,"at":(NOW-timedelta(days=days)).isoformat()}
                     for i,(kind,days) in enumerate([("accept",20),("accept",10),("reopen",5),("accept",1)])])
    scores=calculate(sessions=[],inputs=inputs,now=NOW)
    assert scores["momentum_7d"]["value"] == 0  # was accepted before window; redoing it creates no new net delivery
    assert scores["momentum_30d"]["raw_value"]["net_accepted_weight"] == 3
    s["leaves"][0]["accepted"] = False
    with pytest.raises(ValueError,match="disagrees"):
        calculate(sessions=[],inputs=inputs,now=NOW)


def test_staleness_needs_cadence_and_activation_not_discovery():
    ratings={"personalImportance":5,"goalAlignment":5,"dependencyImportance":5}
    s=calculate(sessions=[session(days=14)],ratings=ratings,inputs={**coverage(),"cadence_days":7},now=NOW)
    assert s["staleness"]["value"] == s["neglect"]["value"] == 50
    assert calculate(sessions=[],inputs={"version":1,"cadence_days":7},now=NOW)["staleness"]["value"] is None


def test_composite_fixed_denominator_and_provisional_opt_in():
    dimensions=calculate(sessions=[],ratings={"urgency":5},now=NOW)
    p={"id":"x","name":"X","weights":{"urgency":1,"progress":1}}
    assert composite(dimensions,p,now=NOW)["state"] == "unknown"
    p["missing_policy"]="fixed_zero"
    score=composite(dimensions,p,now=NOW)
    assert score["value"] == 50
    assert score["state"] == "provisional"
    assert score["components"]["progress"]["imputed"]
    p["weights"]={"investment_observed":1};p["missing_policy"]="require_all"
    dimensions=calculate(sessions=[session()],now=NOW)
    assert composite(dimensions,p)["value"] is None
    p["allow_provisional"]=True
    assert composite(dimensions,p)["state"] == "provisional"


@pytest.mark.parametrize("weights",[{"no":1},{"urgency":float("nan")},{"urgency":-1},{"urgency":0},{"activity_age":1}])
def test_profile_validation(weights):
    with pytest.raises(ValueError):validate_profile({"id":"x","name":"X","weights":weights})


def test_queries_null_last_both_directions_and_needs_data():
    rows=[{"id":str(i),"name":str(i),"dimensions":calculate(sessions=[],ratings=r,now=NOW)}
          for i,r in enumerate([{}, {"urgency":1}, {"urgency":5}])]
    assert [r["id"] for r in select(rows,sort="urgency",direction="desc")] == ["2","1","0"]
    assert [r["id"] for r in select(rows,sort="urgency",direction="asc")] == ["1","2","0"]
    assert len(select(rows,view="needs-data")) == 3
    assert select(rows,view="active-without-delivery") == []
    with pytest.raises(ValueError):select([],query={"dimension":"oops","op":"gt","value":0})


def test_contract_rejects_duplicate_scope_leaves():
    inputs=scope_inputs();inputs["scopes"][0]["leaves"].append(inputs["scopes"][0]["leaves"][0])
    with pytest.raises(ValueError,match="duplicate leaf"):validate_inputs(inputs)


def test_small_finishes_excludes_blocked_or_unknown_blockers():
    inputs=scope_inputs()
    def row():return {'id':'a','name':'A','dimensions':calculate(sessions=[],inputs=inputs,now=NOW)}
    assert len(select([row()],view='small-finishes'))==1
    inputs['scopes'][0]['blocked']=True
    assert select([row()],view='small-finishes')==[]
    del inputs['scopes'][0]['blocked']
    assert select([row()],view='small-finishes')==[]


@pytest.mark.parametrize('config',[{'enabled_groups':['bogus']},{'enabled_metrics':['effort','effort']},{'group_weights':{'timeExecution':float('inf')}},'bad'])
def test_malformed_manual_configuration_rejected(config):
    with pytest.raises(ValueError):calculate(sessions=[],manual_config=config,now=NOW)


@pytest.mark.parametrize('files',[['Projects/P/.sites-runtime/wrangler/dev-registry/p'],['Projects/P/.git/FETCH_HEAD'],['Projects/P/.DS_Store'],['Projects/P/tests/__pycache__/x.pyc'],['Projects/P/Project.betterproject'],[]])
def test_background_or_directory_only_sessions_do_not_rank_as_work(files):
    import json
    s={**session(), 'files_json':json.dumps(files)}
    scores=calculate(sessions=[s],now=NOW)
    assert scores['investment_observed']['value'] is None
    assert scores['activity_age']['value'] is None
    assert len(scores['investment_observed']['coverage']['excluded_sessions'])==1
    assert scores['investment_observed']['coverage']['excluded_observed_hours']==2


def test_mixed_and_capped_samples_are_not_prorated_or_silently_dropped():
    mixed={**session(),'files':['Projects/P/src/main.py','Projects/P/.git/index']}
    score=calculate(sessions=[mixed],inputs=coverage(),now=NOW)['investment_observed']
    assert score['raw_value']==2 and score['state']=='provisional'
    assert score['coverage']['mixed_background_sessions']==1
    capped={**session(),'files':[f'Projects/P/.git/objects/{i}' for i in range(100)]}
    score=calculate(sessions=[capped],now=NOW)['investment_observed']
    assert score['raw_value']==2 and score['coverage']['capped_file_samples']==1


def test_noise_does_not_refresh_last_meaningful_activity():
    older={**session('real',days=5),'files':['Projects/P/main.py']}
    newer={**session('noise',days=1),'files':['Projects/P/.DS_Store']}
    score=calculate(sessions=[older,newer],now=NOW)
    assert score['activity_age']['raw_value']==5
    assert score['investment_observed']['raw_value']==2


def test_unobserved_project_reports_a_labelled_lower_bound_not_a_measurement():
    since = NOW - timedelta(days=33)
    scores = calculate(sessions=[], now=NOW, unobserved_since=since)
    age = scores["activity_age"]
    assert age["raw_value"] == pytest.approx(33)
    assert age["state"] == "provisional"
    assert age["window"]["bound"] == "lower"
    assert age["explanation"].startswith("At least 33 days")
    # Without a sensing start the age stays unknown, and a real session always wins.
    assert calculate(sessions=[], now=NOW)["activity_age"]["value"] is None
    observed = calculate(sessions=[session(days=2)], now=NOW, unobserved_since=since)["activity_age"]
    assert observed["raw_value"] == pytest.approx(2) and observed["source"] == "core.db:completed sessions"
    # Only bulk/background sessions: still a lower bound from sensing, not from those sessions.
    import json
    noisy = {**session(days=1), "files_json": json.dumps([".DS_Store"])}
    assert calculate(sessions=[noisy], now=NOW, unobserved_since=since)["activity_age"]["window"]["bound"] == "lower"
