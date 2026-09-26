from datetime import date, timedelta

import pytest
from fastapi import HTTPException
from sqlalchemy import select

from app.models import DailyUsage, Organization
from app.pricing import find_price, normalize_model, reprice_usage
from .test_pricing import _price_payload


@pytest.mark.parametrize(('raw', 'canonical'), [
    (' GPT-6-ASTRA ', 'gpt-6-astra'),
    ('cb-gpt-5-6-luna', 'gpt-5.6-luna'),
    ('anthropic/claude-opus-5-5-20260922', 'claude-opus-5.5'),
    ('public/claude-fable-5.1', 'claude-fable-5.1'),
    ('cursor-claude-opus-4-6-2026-08-14', 'claude-opus-4.6'),
    ('gpt-6-astra-20260230', 'gpt-6-astra-20260230'),
    ('gpt-6-astra-preview', 'gpt-6-astra-preview'),
    ('custom-local:claude-opus-5-5', 'custom-local:claude-opus-5-5'),
    ('local/gpt-6-astra', 'local/gpt-6-astra'),
    ('unknown', 'unknown'),
])
def test_model_matching_is_conservative(raw, canonical):
    assert normalize_model(raw) == canonical


def price(harness, *, tool='Codex', model='gpt-5', rate='2', day=None, public=True):
    payload = _price_payload(effective_from=(day or date.today()).isoformat(), input_rate=rate)
    payload.update(tool=tool, model=model, public_estimate=public)
    response = harness.client.post('/api/v1/prices', headers=harness.auth('a_admin'), json=payload)
    assert response.status_code == 201, response.text
    return response.json()['id']


def uploaded_row(harness, *, model='gpt-5', completeness='exact', source='local'):
    device = harness.enroll(admin_name='a_admin', user_name='a_member')
    payload = harness.usage_payload()
    payload['buckets'][0].update(model=model, completeness=completeness, source=source)
    assert harness.signed_post(device, payload).status_code == 200
    with harness.session_factory() as session:
        row = session.scalar(select(DailyUsage).where(DailyUsage.device_id == device.id))
        return row.id, row.usage_date


def state(harness):
    with harness.session_factory() as session:
        return {r.id: {key: getattr(r,key) for key in (
            'org_id','user_id','device_id','usage_date','timezone','tool','model','source',
            'input_tokens','output_tokens','cache_read_tokens','cache_write_tokens',
            'is_deleted','completeness','reported_generated_at','price_version_id',
            'cost_microunits','cost_currency','updated_at',
        )} for r in session.scalars(select(DailyUsage))}


def preview(harness, day, **kwargs):
    with harness.session_factory() as session:
        return reprice_usage(session, org_id=harness.users['a_admin'].org_id,
                             start_date=day, end_date=day, **kwargs)


def apply_preview(harness, day, receipt, **kwargs):
    with harness.session_factory() as session:
        result=reprice_usage(session, org_id=harness.users['a_admin'].org_id,
                             start_date=day,end_date=day,apply=True,
                             expected_ledger_version=receipt['ledger_version_before'],
                             expected_catalog_fingerprint=receipt['catalog_fingerprint'],
                             expected_plan_fingerprint=receipt['plan_fingerprint'],**kwargs)
        session.commit()
        return result


def test_tool_specific_precedes_newer_wildcard_with_date_boundaries(harness):
    day=date.today()
    specific=price(harness, model='GPT-6-ASTRA',day=day-timedelta(days=2))
    common=price(harness, tool='*', model='gpt-6-astra',rate='10',day=day)
    with harness.session_factory() as session:
        org=harness.users['a_admin'].org_id
        assert find_price(session,org_id=org,tool='codex',model='gpt-6-astra-20260901',usage_date=day).id==specific
        assert find_price(session,org_id=org,tool='Hermes',model='PUBLIC/GPT-6-ASTRA',usage_date=day).id==common
        assert find_price(session,org_id=org,tool='Hermes',model='gpt-6-astra',usage_date=day-timedelta(days=1)) is None
        assert find_price(session,org_id=harness.users['b_admin'].org_id,tool='Codex',model='gpt-6-astra',usage_date=day) is None
        for unknown in ('gpt-6-astra-preview','custom-local:gpt-6-astra','unknown'):
            assert find_price(session,org_id=org,tool='Hermes',model=unknown,usage_date=day) is None


def test_alias_conflicting_same_date_prices_fail_closed(harness):
    price(harness,model='GPT-5',rate='2')
    price(harness,model='gpt-5',rate='3')
    with harness.session_factory() as session:
        assert find_price(session,org_id=harness.users['a_admin'].org_id,
                          tool='Codex',model='gpt-5',usage_date=date.today()) is None


def test_ingest_normalized_lookup_preserves_original_keys(harness):
    pid=price(harness,tool='*',model='gpt-5.6-luna')
    rid,_=uploaded_row(harness,model='cb-gpt-5-6-luna',source='source-as-uploaded')
    row=state(harness)[rid]
    assert row['price_version_id']==pid
    assert row['model']=='cb-gpt-5-6-luna' and row['tool']=='Codex' and row['source']=='source-as-uploaded'


def test_preview_and_weekly_backfill_only_missing_exact_prices(harness):
    old_id=price(harness,model='gpt-5',day=date.today()-timedelta(days=1))
    existing,day=uploaded_row(harness)
    missing,_=uploaded_row(harness,model='gpt-6-astra')
    fallback,_=uploaded_row(harness,model='gpt-6-astra',completeness='fallback_estimate')
    tombstone,_=uploaded_row(harness,model='gpt-6-astra')
    with harness.session_factory() as session:
        session.get(DailyUsage,tombstone).is_deleted=True
        session.commit()
    new_id=price(harness,model='gpt-6-astra',rate='10')
    price(harness,model='gpt-5',rate='99')
    before=state(harness)
    receipt=preview(harness,day)
    assert receipt['changed_rows']==1 and receipt['preserved_rows']==1
    assert state(harness)==before
    result=apply_preview(harness,day,receipt)
    after=state(harness)
    assert after[existing]==before[existing] and after[existing]['price_version_id']==old_id
    assert after[missing]['price_version_id']==new_id
    assert after[fallback]==before[fallback] and after[tombstone]==before[tombstone]
    for rid in before:
        for key in before[rid]:
            if key not in ('price_version_id','cost_microunits','cost_currency','updated_at'):
                assert after[rid][key]==before[rid][key]
    again=preview(harness,day)
    second=apply_preview(harness,day,again)
    assert second['changed_rows']==0
    assert second['ledger_version_after']==result['ledger_version_after']
    assert state(harness)==after


def test_explicit_public_history_correction_excludes_private_rows(harness):
    # The uploaded ledger date follows its timezone, independently of the host.
    day=date.fromisoformat(harness.usage_payload()['buckets'][0]['date'])
    price(harness,model='gpt-5',day=day-timedelta(days=1))
    public_row,_=uploaded_row(harness)
    private_id=price(harness,model='private-model',public=False)
    private_row,_=uploaded_row(harness,model='private-model')
    new_id=price(harness,model='gpt-5',rate='99',day=day)
    price(harness,tool='*',model='private-model',rate='99',public=True)
    before=state(harness)
    receipt=preview(harness,day,unpriced_only=False)
    assert receipt['changed_rows']==1
    apply_preview(harness,day,receipt,unpriced_only=False)
    after=state(harness)
    assert after[public_row]['price_version_id']==new_id
    assert after[private_row]==before[private_row] and after[private_row]['price_version_id']==private_id


def test_stale_preview_never_applies_after_catalog_or_ledger_change(harness):
    _,day=uploaded_row(harness)
    receipt=preview(harness,day)
    price(harness)
    before=state(harness)
    with pytest.raises(HTTPException) as rejected:
        apply_preview(harness,day,receipt)
    assert rejected.value.status_code==409
    assert state(harness)==before
    receipt=preview(harness,day)
    with harness.session_factory() as session:
        session.get(Organization,harness.users['a_admin'].org_id).ledger_version+=1
        session.commit()
    with pytest.raises(HTTPException):
        apply_preview(harness,day,receipt)
    assert state(harness)==before


def test_repricing_date_model_scope_and_scan_bound(harness):
    rid,day=uploaded_row(harness,model='GPT-6-ASTRA-20260922')
    other,_=uploaded_row(harness,model='gpt-5')
    pid=price(harness,tool='*',model='gpt-6-astra')
    receipt=preview(harness,day,model='gpt-6-astra')
    assert receipt['changed_rows']==1 and receipt['matched_rows']==1
    apply_preview(harness,day,receipt,model='gpt-6-astra')
    assert state(harness)[rid]['price_version_id']==pid
    assert state(harness)[other]['price_version_id'] is None
    with pytest.raises(HTTPException):
        preview(harness,day,max_scan_rows=1)
    with harness.session_factory() as session:
        assert reprice_usage(session,org_id=harness.users['a_admin'].org_id,
                             start_date=day-timedelta(days=2),end_date=day-timedelta(days=1))['changed_rows']==0


def test_reprice_api_is_admin_only_tenant_scoped_and_preview_first(harness):
    rid,day=uploaded_row(harness)
    price(harness)
    payload={'start_date':day.isoformat(),'end_date':day.isoformat(),'model':'gpt-5'}
    before=state(harness)
    endpoint='/api/v1/prices/reprice'
    assert harness.client.post(endpoint,json=payload).status_code==401
    assert harness.client.post(endpoint,headers=harness.auth('a_member'),json=payload).status_code==403
    other=harness.client.post(endpoint,headers=harness.auth('b_admin'),json=payload)
    assert other.status_code==200 and other.json()['matched_rows']==0
    receipt=harness.client.post(endpoint,headers=harness.auth('a_admin'),json=payload)
    assert receipt.status_code==200 and receipt.json()['changed_rows']==1
    assert state(harness)==before
    assert harness.client.post(endpoint,headers=harness.auth('a_admin'),json={**payload,'apply':True}).status_code==422
    approved={**payload,'apply':True,
              'expected_ledger_version':receipt.json()['ledger_version_before'],
              'expected_catalog_fingerprint':receipt.json()['catalog_fingerprint'],
              'expected_plan_fingerprint':receipt.json()['plan_fingerprint']}
    applied=harness.client.post(endpoint,headers=harness.auth('a_admin'),json=approved)
    assert applied.status_code==200 and applied.json()['changed_rows']==1
    assert state(harness)[rid]['price_version_id'] is not None
    after=state(harness)
    assert harness.client.post(endpoint,headers=harness.auth('a_admin'),json=approved).status_code==409
    assert state(harness)==after
    assert harness.client.post(endpoint,headers=harness.auth('a_admin'),json={**payload,'org_id':harness.users['b_admin'].org_id}).status_code==422


def test_preview_plan_cannot_apply_a_different_scope(harness):
    _,day=uploaded_row(harness)
    price(harness)
    receipt=preview(harness,day,model='gpt-5')
    before=state(harness)
    with pytest.raises(HTTPException) as rejected:
        apply_preview(harness,day,receipt,model=None)
    assert rejected.value.status_code==409
    assert state(harness)==before
