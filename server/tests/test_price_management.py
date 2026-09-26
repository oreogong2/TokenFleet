from dataclasses import replace
from datetime import date, timedelta

import pytest
from alembic import command
from alembic.config import Config
from sqlalchemy import inspect, select

from app.database import build_engine
from app.models import DailyUsage, PriceManagementCredential, PriceVersion, User, utcnow
from .test_batch2_pricing import uploaded_row, state


def issue(harness, user='a_admin'):
    response = harness.client.post('/api/v1/price-management/credentials',
        headers=harness.auth(user), json={'expires_in_days': 30})
    assert response.status_code == 201, response.text
    assert response.headers['cache-control'] == 'no-store'
    body = response.json()
    return body['id'], {'Authorization': 'Bearer ' + body['credential']}, body['credential']


def payload(**overrides):
    result = dict(tool='*', model='gpt-6-astra', currency='USD', public_estimate=True,
        input_per_million='10', output_per_million='50', cache_read_per_million='1',
        cache_write_per_million='12.5', effective_basis='ledger_first_seen',
        source_url='https://developers.openai.com/api/docs/pricing',
        source_checked_at=date.today().isoformat())
    result.update(overrides)
    return result


def test_price_credential_is_hash_only_and_cannot_use_other_admin_routes(harness):
    cid, headers, token = issue(harness)
    with harness.session_factory() as session:
        row = session.get(PriceManagementCredential, cid)
        assert len(row.token_hash) == 64 and row.token_hash != token
    for path in ('/api/v1/devices', '/api/v1/users', '/api/v1/dashboard/usage', '/api/v1/prices'):
        assert harness.client.get(path, headers=headers).status_code == 401
    for path, body in (
        ('/api/v1/price-management/credentials', {}),
        ('/api/v1/prices/reprice', {'start_date': date.today().isoformat(), 'end_date': date.today().isoformat()}),
        ('/api/v1/enrollment-tokens', {'user_id': harness.users['a_member'].id}),
    ):
        assert harness.client.post(path, headers=headers, json=body).status_code == 401
    assert harness.client.delete('/api/v1/price-management/credentials/' + cid, headers=headers).status_code == 401
    assert harness.client.get('/api/v1/price-management/missing', headers=headers).status_code == 200


def test_credential_issuance_and_revocation_are_admin_and_org_scoped(harness):
    assert harness.client.post('/api/v1/price-management/credentials',
        headers=harness.auth('a_member'), json={}).status_code == 403
    cid, headers, _ = issue(harness)
    assert harness.client.delete('/api/v1/price-management/credentials/' + cid,
        headers=harness.auth('b_admin')).status_code == 404
    assert harness.client.delete('/api/v1/price-management/credentials/' + cid,
        headers=harness.auth('a_admin')).status_code == 204
    assert harness.client.get('/api/v1/price-management/missing', headers=headers).status_code == 401


@pytest.mark.parametrize('condition', ['expired', 'owner_disabled', 'owner_demoted'])
def test_revoked_authority_never_survives_in_a_price_credential(harness, condition):
    cid, headers, _ = issue(harness)
    with harness.session_factory() as session:
        if condition == 'expired':
            session.get(PriceManagementCredential, cid).expires_at = utcnow() - timedelta(seconds=1)
        elif condition == 'owner_disabled':
            session.get(User, harness.users['a_admin'].id).is_active = False
        else:
            from app.models import UserRole
            session.get(User, harness.users['a_admin'].id).role = UserRole.MEMBER
        session.commit()
    assert harness.client.get('/api/v1/price-management/missing', headers=headers).status_code == 401


def test_official_import_resolves_first_seen_and_backfills_only_missing_exact(harness):
    missing, day = uploaded_row(harness, model='cb-gpt-6-astra')
    fallback, _ = uploaded_row(harness, model='gpt-6-astra', completeness='fallback_estimate')
    deleted, _ = uploaded_row(harness, model='gpt-6-astra')
    existing, _ = uploaded_row(harness, model='gpt-6-astra')
    with harness.session_factory() as session:
        session.get(DailyUsage, deleted).is_deleted = True
        # A cost already present is preserved even without a complete reference.
        row = session.get(DailyUsage, existing)
        row.cost_currency, row.cost_microunits = 'USD', 777
        session.commit()
    before = state(harness)
    _, headers, _ = issue(harness)
    response = harness.client.post('/api/v1/price-management/versions', headers=headers, json=payload())
    assert response.status_code == 200, response.text
    receipt = response.json()
    assert receipt['effective_from'] == day.isoformat()
    assert receipt['effective_basis'] == 'ledger_first_seen'
    assert receipt['backfill']['changed_rows'] == 1
    after = state(harness)
    assert after[missing]['cost_microunits'] == 6825
    for rid in (fallback, deleted, existing):
        assert after[rid] == before[rid]
    for rid in before:
        for key in before[rid]:
            if key not in ('price_version_id', 'cost_microunits', 'cost_currency', 'updated_at'):
                assert after[rid][key] == before[rid][key]
    again = harness.client.post('/api/v1/price-management/versions', headers=headers, json=payload())
    assert again.status_code == 200 and again.json()['created'] is False
    assert again.json()['backfill']['changed_rows'] == 0 and state(harness) == after
    conflict = harness.client.post('/api/v1/price-management/versions', headers=headers,
                                  json=payload(input_per_million='99'))
    assert conflict.status_code == 409 and state(harness) == after


def test_official_date_takes_precedence_without_backdating_to_ledger(harness):
    missing, day = uploaded_row(harness, model='gpt-6-astra')
    _, headers, _ = issue(harness)
    response = harness.client.post('/api/v1/price-management/versions', headers=headers,
        json=payload(effective_basis='official_date', effective_from=(day + timedelta(days=1)).isoformat()))
    assert response.status_code == 200
    assert response.json()['backfill']['changed_rows'] == 0
    assert state(harness)[missing]['price_version_id'] is None


@pytest.mark.parametrize('overrides', [
    {'source_url': 'https://pricing.example.com/models'},
    {'source_url': 'https://developers.openai.com.evil.test/api/docs/pricing'},
    {'source_url': 'https://developers.openai.com/api/docs/pricing?access_token=example'},
    {'source_url': 'http://developers.openai.com/api/docs/pricing'},
    {'model': 'custom-local:gpt-6-astra'}, {'model': 'claude-fable-5-1'},
    {'effective_basis': 'official_date'}, {'effective_from': date.today().isoformat()},
    {'source_checked_at': (date.today() + timedelta(days=1)).isoformat()},
    {'public_estimate': False}, {'unpriced_only': False}, {'org_id': 'other'}, {'apply': True},
])
def test_import_cannot_override_scope_or_invent_an_official_source(harness, overrides):
    _, headers, _ = issue(harness)
    response = harness.client.post('/api/v1/price-management/versions', headers=headers,
                                  json=payload(**overrides))
    assert response.status_code == 422


def test_public_catalog_is_versioned_and_does_not_publish_private_or_legacy_prices(harness):
    harness.app.state.settings = replace(harness.app.state.settings, public_org_slug='alpha')
    empty = harness.client.get('/api/v1/public/price-catalog')
    assert empty.status_code == 200 and empty.json()['prices'] == []
    _, headers, _ = issue(harness)
    response = harness.client.post('/api/v1/price-management/versions', headers=headers,
        json=payload(effective_basis='official_date', effective_from=date.today().isoformat()))
    assert response.status_code == 200, response.text
    response = harness.client.get('/api/v1/public/price-catalog')
    body = response.json()
    assert body['version'] != empty.json()['version'] and len(body['prices']) == 1
    assert all(k not in str(body) for k in ('org_id', 'user_id', 'created_by_user_id', 'token_hash'))
    assert harness.client.get('/api/v1/public/price-catalog',
        headers={'If-None-Match': response.headers['etag']}).status_code == 304
    other = harness.client.get('/api/v1/price-management/catalog', headers=harness.auth('b_admin'))
    assert other.status_code == 200 and other.json()['prices'] == []
    pid = body['prices'][0]['id']
    harness.client.patch('/api/v1/prices/' + pid, headers=harness.auth('a_admin'),
                         json={'public_estimate': False})
    hidden = harness.client.get('/api/v1/public/price-catalog')
    assert hidden.json()['revision'] > body['revision']
    assert hidden.json()['prices'] == [] and hidden.headers['etag'] != empty.headers['etag']


def test_inventory_is_private_and_organization_scoped(harness):
    _, day = uploaded_row(harness, model='cb-gpt-6-astra')
    _, headers, _ = issue(harness)
    response = harness.client.get('/api/v1/price-management/missing', headers=headers)
    assert response.status_code == 200
    assert response.json()['models'][0]['first_seen'] == day.isoformat()
    assert response.json()['models'][0]['model'] == 'gpt-6-astra'
    assert harness.client.get('/api/v1/price-management/missing').status_code == 401
    assert harness.client.get('/api/v1/price-management/missing',
        headers=harness.auth('a_member')).status_code == 403
    assert harness.client.get('/api/v1/price-management/missing',
        headers=harness.auth('b_admin')).json()['models'] == []
    assert all(k not in response.text for k in ('user_id', 'device_id', 'email'))


def test_additive_migration_preserves_existing_ledger_schema(tmp_path):
    from pathlib import Path
    server = Path(__file__).resolve().parents[1]
    config = Config(str(server / 'alembic.ini'))
    config.attributes['database_url'] = 'sqlite:///' + str(tmp_path / 'migration.db')
    command.upgrade(config, '9a342e52bb08')
    engine = build_engine(config.attributes['database_url'])
    old_columns = {c['name'] for c in inspect(engine).get_columns('daily_usage')}
    command.upgrade(config, 'head')
    assert {c['name'] for c in inspect(engine).get_columns('daily_usage')} == old_columns
    assert {'source_url', 'source_checked_at', 'effective_basis'} <= {
        c['name'] for c in inspect(engine).get_columns('price_versions')}
    assert 'price_management_credentials' in inspect(engine).get_table_names()
    command.downgrade(config, '9a342e52bb08')
    assert 'price_management_credentials' not in inspect(engine).get_table_names()
    engine.dispose()


def test_verified_catalog_supersedes_legacy_public_rate_but_preserves_priced_history(harness):
    from .test_batch2_pricing import price
    old = price(harness, model='gpt-6-astra', rate='99')
    rid, day = uploaded_row(harness, model='gpt-6-astra')
    before = state(harness)
    _, headers, _ = issue(harness)
    response = harness.client.post('/api/v1/price-management/versions', headers=headers, json=payload())
    assert response.status_code == 200 and state(harness)[rid] == before[rid]
    assert state(harness)[rid]['price_version_id'] == old
    new, _ = uploaded_row(harness, model='gpt-6-astra')
    assert state(harness)[new]['price_version_id'] == response.json()['price_version_id']
    assert state(harness)[new]['cost_microunits'] == 6825


def test_device_catalog_is_signed_and_bound_to_its_organization(harness):
    _, headers, _ = issue(harness)
    assert harness.client.post('/api/v1/price-management/versions', headers=headers,
        json=payload(effective_basis='official_date', effective_from=date.today().isoformat())).status_code == 200
    a = harness.enroll(admin_name='a_admin', user_name='a_member')
    b = harness.enroll(admin_name='b_admin', user_name='b_member')
    path = '/api/v1/device/price-catalog'
    assert harness.client.get(path).status_code == 401
    assert len(harness.signed_get(a, path).json()['prices']) == 1
    assert harness.signed_get(b, path).json()['prices'] == []


@pytest.mark.parametrize('kind', ['read', 'write'])
def test_explicit_unknown_cache_rate_is_not_zero_and_completion_only_backfills_missing(harness, kind):
    harness.app.state.settings = replace(harness.app.state.settings, public_org_slug='alpha')
    def upload(count):
        device = harness.enroll(admin_name='a_admin', user_name='a_member')
        report = harness.usage_payload()
        report['buckets'][0].update(model='gpt-6-astra', input_tokens=100,
            output_tokens=10, cache_read_tokens=0, cache_write_tokens=0)
        report['buckets'][0]['cache_' + kind + '_tokens'] = count
        assert harness.signed_post(device, report).status_code == 200
        with harness.session_factory() as session:
            row = session.scalar(select(DailyUsage).where(DailyUsage.device_id == device.id))
            return row.id
    eligible = upload(0)
    conditional = upload(3)
    before = state(harness)
    _, headers, _ = issue(harness)
    key = 'cache_' + kind + '_per_million'
    request = payload(**{key: None})
    first = harness.client.post('/api/v1/price-management/versions', headers=headers, json=request)
    assert first.status_code == 200, first.text
    assert first.json()['backfill']['changed_rows'] == 1
    after = state(harness)
    assert after[eligible]['cost_microunits'] == 1500
    assert after[conditional] == before[conditional]
    catalog = harness.client.get('/api/v1/public/price-catalog').json()
    assert catalog['prices'][0][key] is None
    missing = harness.client.get('/api/v1/price-management/missing', headers=headers).json()
    assert missing['models'][0]['catalog_backfillable_rows'] == 0
    admin = harness.client.get('/api/v1/prices', headers=harness.auth('a_admin')).json()
    assert admin[0][key] is None and admin[0]['cache_' + kind + '_price_known'] is False
    # Future ingestion with the same conditional rate also stays truly unpriced.
    future = upload(3)
    assert state(harness)[future]['price_version_id'] is None
    completed = harness.client.post('/api/v1/price-management/versions', headers=headers, json=payload())
    assert completed.status_code == 200, completed.text
    assert completed.json()['created'] is False
    assert completed.json()['backfill']['changed_rows'] == 2
    filled = state(harness)
    assert filled[eligible] == after[eligible]  # originally priced rows are frozen
    expected = 1503 if kind == 'read' else 1538
    assert filled[conditional]['cost_microunits'] == expected
    assert filled[future]['cost_microunits'] == expected
    assert harness.client.get('/api/v1/public/price-catalog').json()['revision'] == catalog['revision'] + 1
    for rid in (eligible, conditional):
        for field in before[rid]:
            if field not in ('price_version_id', 'cost_microunits', 'cost_currency', 'updated_at'):
                assert filled[rid][field] == before[rid][field]
    retry = harness.client.post('/api/v1/price-management/versions', headers=headers, json=payload())
    assert retry.status_code == 200 and retry.json()['backfill']['changed_rows'] == 0
    assert state(harness) == filled
    for invalid in (request, payload(input_per_million='9')):
        assert harness.client.post('/api/v1/price-management/versions', headers=headers, json=invalid).status_code == 409
        assert state(harness) == filled


def test_full_public_correction_clears_guessed_cache_cost_but_weekly_preserves_it(harness):
    from .test_batch2_pricing import price, preview, apply_preview
    old = price(harness, model='gpt-6-astra', rate='99')
    rid, day = uploaded_row(harness, model='gpt-6-astra')
    before = state(harness)
    _, headers, _ = issue(harness)
    response = harness.client.post('/api/v1/price-management/versions', headers=headers,
                                  json=payload(cache_write_per_million=None))
    assert response.status_code == 200 and state(harness) == before
    dry = preview(harness, day, unpriced_only=False)
    assert dry['changed_rows'] == 1 and dry['no_price_rows'] == 1
    assert dry['priced_tokens_after'] == '0' and state(harness) == before
    result = apply_preview(harness, day, dry, unpriced_only=False)
    assert result['changed_rows'] == 1
    row = state(harness)[rid]
    assert row['price_version_id'] is row['cost_microunits'] is row['cost_currency'] is None
    for key in before[rid]:
        if key not in ('price_version_id', 'cost_microunits', 'cost_currency', 'updated_at'):
            assert row[key] == before[rid][key]
