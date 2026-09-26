from __future__ import annotations
import io
import json
import tempfile
import unittest
import urllib.error
from pathlib import Path
from unittest import mock

import test_client
from test_collectors import write_jsonl, codex_usage
from tokenfleet.collectors import CollectionDiagnostics, CollectionResult, collect_usage
from tokenfleet.client import TokenFleetClient
from tokenfleet.credential import DeviceCredential
from tokenfleet.http_client import NetworkError
from tokenfleet.state import StateStore


class BatchOneRegressions(unittest.TestCase):
    def client(self, root, transport, buckets=None):
        credential = DeviceCredential('https://community.example.com',
            '11111111-1111-4111-8111-111111111111',
            '22222222-2222-4222-8222-222222222222', 'fixture_device_value_1234567890')
        return TokenFleetClient(machine_fingerprint=lambda: "a" * 64, credential_store=test_client.MemoryDeviceStore(credential),
            state_store=StateStore(root / 'state.json'), source_home=root,
            community_origin=credential.server_origin, transport=transport,
            collector=lambda *args, **kwargs: CollectionResult(
                buckets if buckets is not None else [dict(test_client.ClientTests.bucket)], CollectionDiagnostics()))

    def test_codex_recovery_and_other_session_survive_bad_record(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            rows = [{'type': 'session_meta', 'payload': {'id': 'fixture-session'}},
                    {'type': 'turn_context', 'payload': {'model': 'gpt-5'}}]
            for total in [50, 100, 6, 150]:
                rows.append({'type': 'event_msg', 'timestamp': '2026-08-09T00:00:00Z',
                    'payload': {'type': 'token_count', 'info': {'total_token_usage': codex_usage(total, 0, 0)}}})
            write_jsonl(root / '.codex/sessions/a.jsonl', rows)
            other = [{'type': 'session_meta', 'payload': {'id': 'fixture-other'}},
                     {'type': 'turn_context', 'payload': {'model': 'gpt-5'}},
                     {'type': 'event_msg', 'timestamp': '2026-08-09T00:00:00Z',
                      'payload': {'type': 'token_count', 'info': {'total_token_usage': codex_usage(10, 0, 0)}}}]
            write_jsonl(root / '.codex/sessions/b.jsonl', other)
            result = collect_usage(root, history_days=366)
            self.assertEqual(result.total_tokens, 160)
            self.assertEqual(result.diagnostics.skipped_records['Codex'], 1)

    def test_http_error_does_not_retain_validation_inputs(self):
        raw = {'detail': [{'loc': ['body', 'buckets', 0, 'model'], 'input': 'PRIVATE_SENTINEL'}]}
        error = urllib.error.HTTPError('https://community.example.com', 422, 'bad', {},
                                      io.BytesIO(json.dumps(raw).encode()))
        parsed = NetworkError.from_http(error)
        self.assertEqual(parsed.rejected_indices, (0,))
        self.assertNotIn('PRIVATE_SENTINEL', str(parsed.__dict__) + str(parsed))

    def test_clock_retry_gets_new_timestamp_nonce_and_then_succeeds(self):
        class Transport(test_client.FixtureTransport):
            def post_bytes(self, *args, **kwargs):
                result = super().post_bytes(*args, **kwargs)
                if len(self.uploads) == 1:
                    raise NetworkError('clock', status=401, server_time=2000)
                return result
        with tempfile.TemporaryDirectory() as temporary:
            transport = Transport('22222222-2222-4222-8222-222222222222')
            client = self.client(Path(temporary), transport)
            with mock.patch('tokenfleet.client.time.time', return_value=1000):
                summary = client.sync()
            self.assertEqual(summary.buckets, 1)
            first, second = [item[2] for item in transport.uploads]
            self.assertEqual(first['X-Timestamp'], '1000')
            self.assertEqual(second['X-Timestamp'], '2000')
            self.assertNotEqual(first['X-Nonce'], second['X-Nonce'])
            self.assertIsNone(client.state_store.load().last_sync_error)

    def test_rejected_bucket_is_not_counted_as_uploaded(self):
        class Transport(test_client.FixtureTransport):
            def post_bytes(self, *args, **kwargs):
                result = super().post_bytes(*args, **kwargs)
                if len(self.uploads) == 1:
                    raise NetworkError('invalid', status=422, rejected_indices=(0,))
                return result
        with tempfile.TemporaryDirectory() as temporary:
            transport = Transport('22222222-2222-4222-8222-222222222222')
            buckets = [dict(test_client.ClientTests.bucket), dict(test_client.ClientTests.bucket, model='gpt-fixture-two')]
            client = self.client(Path(temporary), transport, buckets)
            summary = client.sync()
            self.assertEqual(summary.buckets, 1)
            self.assertEqual(summary.total_tokens, 100)
            state = client.state_store.load()
            self.assertEqual(state.last_uploaded_tokens, 100)
            self.assertEqual(state.last_omitted_bucket_count, 1)
            self.assertEqual(len(json.loads(transport.uploads[-1][1])['buckets']), 1)

    def test_failure_preserves_success_and_does_not_log_response(self):
        class Transport(test_client.FixtureTransport):
            def post_bytes(self, *args, **kwargs):
                raise RuntimeError('PRIVATE_SENTINEL')
        with tempfile.TemporaryDirectory() as temporary:
            client = self.client(Path(temporary), Transport('22222222-2222-4222-8222-222222222222'))
            state = client.state_store.load()
            state.last_sync_at = '2026-08-01T00:00:00Z'
            client.state_store.save(state)
            with self.assertRaises(RuntimeError):
                client.sync()
            state = client.state_store.load()
            self.assertEqual(state.last_sync_at, '2026-08-01T00:00:00Z')
            self.assertEqual(state.consecutive_sync_failures, 1)
            self.assertNotIn('PRIVATE_SENTINEL', client.state_store.path.read_text())
