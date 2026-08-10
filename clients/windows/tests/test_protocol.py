from __future__ import annotations

import unittest

from tokenfleet.protocol import (
    ProtocolError,
    canonical_json,
    daily_payload,
    normalize_origin,
    signed_headers,
    validate_ingest_response,
)


class ProtocolTests(unittest.TestCase):
    def test_normalizes_only_https_origins(self) -> None:
        self.assertEqual(normalize_origin("https://Example.COM/"), "https://example.com")
        self.assertEqual(normalize_origin("https://example.com:8443"), "https://example.com:8443")
        for value in (
            "http://example.com",
            " https://example.com",
            "https://user@example.com",
            "https://example.com/path",
            "https://example.com?x=1",
            "https://example.com/#fragment",
            "https://example.com/%2e",
        ):
            with self.subTest(value=value), self.assertRaises(ProtocolError):
                normalize_origin(value)

    def test_hmac_matches_team_sync_v1_golden_vector(self) -> None:
        payload = daily_payload(
            [
                {
                    "date": "2026-08-09",
                    "timezone": "Asia/Shanghai",
                    "tool": "Codex",
                    "model": "gpt-5",
                    "source": "local",
                    "input_tokens": 1,
                    "output_tokens": 2,
                    "cache_read_tokens": 3,
                    "cache_write_tokens": 4,
                    "completeness": "exact",
                }
            ],
            collector_version="0.2.0-windows.1",
            generated="2026-08-09T01:02:03Z",
        )
        body = canonical_json(payload)
        self.assertEqual(
            body.decode(),
            '{"buckets":[{"cache_read_tokens":3,"cache_write_tokens":4,'
            '"completeness":"exact","date":"2026-08-09","input_tokens":1,'
            '"model":"gpt-5","output_tokens":2,"source":"local",'
            '"timezone":"Asia/Shanghai","tool":"Codex"}],'
            '"collector_version":"0.2.0-windows.1",'
            '"generated_at":"2026-08-09T01:02:03Z","schema_version":1}',
        )
        headers = signed_headers(
            device_id="8c004b75-b425-42c5-a3ce-74bf665922b8",
            device_secret="fixture_secret_1234567890",
            body=body,
            timestamp=1_786_240_000,
            nonce="01234567-89ab-4def-8123-456789abcdef",
        )
        self.assertEqual(
            headers["X-Signature"],
            "fbedc2ee28be0432b29b33e606ebd976f39818ceb8a94387b7a55cf0a45a046f",
        )

    def test_hmac_matches_the_server_owned_golden_vector(self) -> None:
        body = (
            b'{"schema_version":1,"collector_version":"0.2.0","generated_at":'
            b'"2026-08-09T01:30:00Z","buckets":[{"date":"2026-08-09",'
            b'"timezone":"Asia/Shanghai","tool":"Codex","model":"gpt-5",'
            b'"source":"local","input_tokens":120,"output_tokens":80,'
            b'"cache_read_tokens":1000,"cache_write_tokens":50,'
            b'"completeness":"exact"}]}'
        )
        headers = signed_headers(
            device_id="8c004b75-b425-42c5-a3ce-74bf665922b8",
            device_secret="test-device-secret-00000000000000000000",
            body=body,
            timestamp=1_786_240_000,
            nonce="123e4567-e89b-12d3-a456-426614174000",
        )
        self.assertEqual(
            headers["X-Signature"],
            "b6f61ec4a68f4693d1baa5115584db1cde917fbc80c376e8d6166af25334bb42",
        )

    def test_payload_rejects_duplicate_and_non_integer_counts(self) -> None:
        bucket = {
            "date": "2026-08-09",
            "timezone": "Asia/Shanghai",
            "tool": "Codex",
            "model": "gpt-5",
            "source": "local",
            "input_tokens": 1,
            "output_tokens": 2,
            "cache_read_tokens": 3,
            "cache_write_tokens": 4,
            "completeness": "exact",
        }
        with self.assertRaises(ProtocolError):
            daily_payload([bucket, bucket], collector_version="test")
        invalid = dict(bucket, input_tokens=True)
        with self.assertRaises(ProtocolError):
            daily_payload([invalid], collector_version="test")

    def test_validates_complete_server_accounting(self) -> None:
        result = validate_ingest_response(
            {"created": 1, "updated": 2, "unchanged": 3, "ledger_version": 4},
            expected_count=6,
        )
        self.assertEqual(result["ledger_version"], 4)
        with self.assertRaises(ProtocolError):
            validate_ingest_response(
                {"created": 1, "updated": 2, "unchanged": 2, "ledger_version": 4},
                expected_count=6,
            )


if __name__ == "__main__":
    unittest.main()
