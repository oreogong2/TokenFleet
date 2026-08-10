from __future__ import annotations

import json
import ssl
import urllib.error
import urllib.request
from dataclasses import dataclass
from typing import Any, Protocol

from .constants import MAX_RESPONSE_BYTES
from .protocol import ProtocolError, canonical_json, endpoint


class NetworkError(RuntimeError):
    pass


class JSONTransport(Protocol):
    def post(
        self,
        url: str,
        value: dict[str, Any],
        *,
        headers: dict[str, str] | None = None,
        expected_status: int,
    ) -> Any: ...


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):  # type: ignore[no-untyped-def]
        raise NetworkError("TokenFleet server redirects are not allowed")


@dataclass
class HTTPSJSONTransport:
    timeout_seconds: float = 30.0

    def __post_init__(self) -> None:
        context = ssl.create_default_context()
        self._opener = urllib.request.build_opener(
            _NoRedirect(), urllib.request.HTTPSHandler(context=context)
        )

    def post(
        self,
        url: str,
        value: dict[str, Any],
        *,
        headers: dict[str, str] | None = None,
        expected_status: int,
    ) -> Any:
        body = canonical_json(value)
        return self.post_bytes(
            url,
            body,
            headers=headers,
            expected_status=expected_status,
        )

    def post_bytes(
        self,
        url: str,
        body: bytes,
        *,
        headers: dict[str, str] | None = None,
        expected_status: int,
    ) -> Any:
        request_headers = {"Content-Type": "application/json"}
        request_headers.update(headers or {})
        request = urllib.request.Request(
            url=url,
            data=body,
            headers=request_headers,
            method="POST",
        )
        try:
            with self._opener.open(request, timeout=self.timeout_seconds) as response:
                status = response.status
                content_length = response.headers.get("Content-Length")
                if content_length and int(content_length) > MAX_RESPONSE_BYTES:
                    raise NetworkError("TokenFleet server response is too large")
                payload = response.read(MAX_RESPONSE_BYTES + 1)
        except NetworkError:
            raise
        except urllib.error.HTTPError as exc:
            # Never include the response body: enrollment responses can carry a
            # device secret and proxy error pages can reflect request values.
            raise NetworkError(f"TokenFleet server returned HTTP {exc.code}") from None
        except (urllib.error.URLError, OSError, TimeoutError, ValueError) as exc:
            raise NetworkError("TokenFleet server could not be reached securely") from exc
        if status != expected_status:
            raise NetworkError(f"TokenFleet server returned HTTP {status}")
        if len(payload) > MAX_RESPONSE_BYTES:
            raise NetworkError("TokenFleet server response is too large")
        try:
            return json.loads(payload.decode("utf-8"))
        except (UnicodeError, json.JSONDecodeError) as exc:
            raise ProtocolError("TokenFleet server returned invalid JSON") from exc


def enrollment_endpoint(origin: str) -> str:
    from .constants import ENROLLMENT_PATH

    return endpoint(origin, ENROLLMENT_PATH)


def usage_endpoint(origin: str) -> str:
    from .constants import DAILY_USAGE_PATH

    return endpoint(origin, DAILY_USAGE_PATH)
