import importlib.util
import json
import os
from pathlib import Path
from urllib.error import HTTPError

import pytest

spec = importlib.util.spec_from_file_location('price_maintenance', Path(__file__).resolve().parents[2] / 'script/price_maintenance.py')
maintenance = importlib.util.module_from_spec(spec)
spec.loader.exec_module(maintenance)


class Reply:
    def __init__(self, body): self.body = body
    def __enter__(self): return self
    def __exit__(self, *args): pass
    def read(self, size): return self.body[:size]


class FakeOpener:
    def __init__(self, body=None, error=None):
        self.body, self.error, self.requests = body, error, []
    def open(self, request, timeout):
        self.requests.append(request)
        if self.error: raise self.error
        return Reply(json.dumps(self.body).encode())


def test_credentials_are_read_only_from_private_files_and_jwt_is_rejected(tmp_path):
    path = tmp_path / 'credential'
    token = 'tfprice_' + 'a' * 43
    path.write_text(token)
    path.chmod(0o600)
    assert maintenance.read_credential(path) == token
    path.chmod(0o644)
    with pytest.raises(maintenance.MaintenanceError): maintenance.read_credential(path)
    path.chmod(0o600)
    path.write_text('not-a-price-credential')
    with pytest.raises(maintenance.MaintenanceError): maintenance.read_credential(path)
    link = tmp_path / 'link'
    link.symlink_to(path)
    with pytest.raises(maintenance.MaintenanceError): maintenance.read_credential(link)


@pytest.mark.parametrize('origin', ['http://localhost', 'https://user:pass@example.com',
    'https://example.com/private', 'https://example.com?token=example', 'https://example.com:8443'])
def test_origin_cannot_disable_tls_or_embed_a_credential(origin):
    with pytest.raises(maintenance.MaintenanceError): maintenance.PriceAdminClient(origin, 'example')


def test_only_price_endpoints_are_called_and_transport_errors_do_not_echo_secrets(capsys):
    token = 'tfprice_' + 'b' * 43
    error = HTTPError('https://example.com', 302, token, {}, None)
    fake = FakeOpener(error=error)
    client = maintenance.PriceAdminClient('https://example.com', token, fake)
    with pytest.raises(maintenance.MaintenanceError) as caught:
        client.request('versions', {})
    assert str(caught.value) == 'price API returned HTTP 302' and token not in str(caught.value)
    assert len(fake.requests) == 1
    assert fake.requests[0].get_header('Authorization') == 'Bearer ' + token
    with pytest.raises(maintenance.MaintenanceError): client.request('reprice')
    assert len(fake.requests) == 1
    assert token not in capsys.readouterr().out + capsys.readouterr().err
    assert maintenance.NoRedirect().redirect_request(None, None, 302, '', {}, 'https://other.example.com') is None


def test_receipt_is_private_and_import_cannot_accept_broad_repricing(tmp_path):
    reply = {'price_version_id': 'example', 'created': True, 'effective_from': '2026-09-01',
             'effective_basis': 'ledger_first_seen', 'backfill': {'unpriced_only': True, 'changed_rows': 2},
             'catalog_version': 'example'}
    fake = FakeOpener(body=reply)
    client = maintenance.PriceAdminClient('https://example.com', 'example', fake)
    result = maintenance.import_versions(client, [{'model': 'example-model'}])
    assert result['backfilled_exact_rows'] == 2
    path = tmp_path / 'receipt.json'
    maintenance.write_private(path, result)
    assert path.stat().st_mode & 0o777 == 0o600
    assert json.loads(path.read_text()) == result
    reply['backfill']['unpriced_only'] = False
    with pytest.raises(maintenance.MaintenanceError): maintenance.import_versions(client, [{}])
    reply['credential'] = 'example-secret'
    with pytest.raises(maintenance.MaintenanceError): maintenance.import_versions(client, [{}])
