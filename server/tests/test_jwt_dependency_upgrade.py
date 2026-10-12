"""Authentication regressions for the pinned PyJWT security upgrade."""
from datetime import datetime, timedelta, timezone

import jwt
import pytest

from .test_auth_boundaries import _bearer, _claims


def test_wrong_human_jwt_signature_is_rejected(harness) -> None:
    token = jwt.encode(_claims(harness), 'test-wrong-key-with-at-least-32-bytes', algorithm='HS256')
    response = harness.client.get('/api/v1/me', headers=_bearer(token))
    assert response.status_code == 401
    assert response.json() == {'detail': 'invalid or expired access token'}


@pytest.mark.parametrize('claim,value', [('exp', []), ('exp', None), ('iat', {}), ('nbf', [])])
def test_malformed_time_claims_return_401_instead_of_an_unhandled_type_error(harness, claim, value):
    claims = _claims(harness)
    claims[claim] = value
    token = jwt.encode(claims, harness.app.state.settings.jwt_secret, algorithm='HS256')
    response = harness.client.get('/api/v1/me', headers=_bearer(token))
    assert response.status_code == 401
    assert response.json() == {'detail': 'invalid or expired access token'}


def test_unverified_decode_cannot_mutate_reused_options_and_bypass_expiry(harness):
    settings = harness.app.state.settings
    claims = _claims(harness)
    claims['exp'] = datetime.now(timezone.utc) - timedelta(minutes=5)
    token = jwt.encode(claims, settings.jwt_secret, algorithm='HS256')
    options = {'verify_signature': False}
    jwt.decode(token, options=options)
    assert options == {'verify_signature': False}
    options['verify_signature'] = True
    with pytest.raises(jwt.ExpiredSignatureError):
        jwt.decode(token, settings.jwt_secret, algorithms=['HS256'],
                   audience=settings.jwt_audience, issuer=settings.jwt_issuer, options=options)
