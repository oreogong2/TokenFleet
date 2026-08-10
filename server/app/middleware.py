from __future__ import annotations

from collections.abc import Awaitable, Callable
from ipaddress import (
    IPv4Address,
    IPv4Network,
    IPv6Address,
    IPv6Network,
    ip_address,
    ip_network,
)

from starlette.responses import JSONResponse
from starlette.types import Message, Receive, Scope, Send

CONTENT_SECURITY_POLICY = (
    "default-src 'self'; "
    "base-uri 'none'; "
    "object-src 'none'; "
    "frame-ancestors 'none'; "
    "form-action 'self'; "
    "script-src 'self'; "
    "script-src-attr 'none'; "
    "style-src 'self' 'unsafe-inline'; "
    "img-src 'self' data:; "
    "font-src 'self'; "
    "connect-src 'self'; "
    "manifest-src 'self'"
)
SECURITY_HEADERS = (
    (b"content-security-policy", CONTENT_SECURITY_POLICY.encode("ascii")),
    (b"x-content-type-options", b"nosniff"),
    (b"referrer-policy", b"no-referrer"),
    (
        b"permissions-policy",
        b"camera=(), microphone=(), geolocation=(), payment=(), usb=(), serial=()",
    ),
    (b"x-frame-options", b"DENY"),
)
STRICT_TRANSPORT_SECURITY = b"max-age=31536000; includeSubDomains"
IPAddress = IPv4Address | IPv6Address
IPNetwork = IPv4Network | IPv6Network


def parse_trusted_proxy_cidrs(raw_value: str) -> tuple[IPNetwork, ...]:
    """Parse an explicit comma-separated proxy allow-list.

    Host addresses are accepted as /32 or /128 networks. Invalid or empty
    entries fail startup instead of silently weakening the trust boundary.
    """

    normalized = raw_value.strip()
    if not normalized:
        return ()
    entries = [entry.strip() for entry in normalized.split(",")]
    if any(not entry for entry in entries):
        raise ValueError("TRUSTED_PROXY_CIDRS contains an empty entry")
    return tuple(ip_network(entry, strict=False) for entry in entries)


def trusted_client_ip(
    scope: Scope,
    *,
    trusted_proxy_networks: tuple[IPNetwork, ...],
    trusted_proxy_hops: int,
) -> str | None:
    """Resolve a client only across an explicitly configured proxy chain.

    This supports both raw ASGI peers and Uvicorn's trusted proxy-header
    middleware. In the latter case ``scope['client']`` has already been
    rewritten to the selected X-Forwarded-For address.
    """

    if not trusted_proxy_networks or trusted_proxy_hops < 1:
        return None
    forwarded_for = _single_header(scope, b"x-forwarded-for")
    if forwarded_for is None:
        return None
    raw_addresses = [item.strip() for item in forwarded_for.split(",")]
    if (
        len(raw_addresses) < trusted_proxy_hops
        or len(raw_addresses) > 32
        or any(not item for item in raw_addresses)
    ):
        return None
    try:
        addresses = [ip_address(item) for item in raw_addresses]
        raw_client = scope.get("client")
        if raw_client is None:
            return None
        observed_client = ip_address(str(raw_client[0]))
    except (IndexError, TypeError, ValueError):
        return None

    selected_client = addresses[-trusted_proxy_hops]
    intermediary_proxies = (
        addresses[-(trusted_proxy_hops - 1) :]
        if trusted_proxy_hops > 1
        else []
    )
    if any(
        not _address_in_networks(proxy, trusted_proxy_networks)
        for proxy in intermediary_proxies
    ):
        return None
    if (
        observed_client != selected_client
        and not _address_in_networks(observed_client, trusted_proxy_networks)
    ):
        return None
    return selected_client.compressed


def _trusted_forwarded_proto(
    scope: Scope,
    *,
    trusted_proxy_networks: tuple[IPNetwork, ...],
    trusted_proxy_hops: int,
) -> str | None:
    if trusted_client_ip(
        scope,
        trusted_proxy_networks=trusted_proxy_networks,
        trusted_proxy_hops=trusted_proxy_hops,
    ) is None:
        return None
    forwarded_proto = _single_header(scope, b"x-forwarded-proto")
    if forwarded_proto is None:
        return None
    values = [item.strip().lower() for item in forwarded_proto.split(",")]
    if len(values) < trusted_proxy_hops or any(
        value not in {"http", "https"} for value in values
    ):
        return None
    return values[-trusted_proxy_hops]


def _single_header(scope: Scope, name: bytes) -> str | None:
    values = [
        value
        for header_name, value in scope.get("headers", [])
        if header_name.lower() == name
    ]
    if len(values) != 1:
        return None
    try:
        return values[0].decode("ascii")
    except UnicodeDecodeError:
        return None


def _address_in_networks(
    address: IPAddress, networks: tuple[IPNetwork, ...]
) -> bool:
    return any(
        address.version == network.version and address in network
        for network in networks
    )


class SecurityHeadersMiddleware:
    """Attach the same browser security policy to static, API, and error responses."""

    def __init__(
        self,
        app: Callable[..., Awaitable[None]],
        *,
        production: bool,
        trusted_proxy_networks: tuple[IPNetwork, ...] = (),
        trusted_proxy_hops: int = 0,
    ) -> None:
        self.app = app
        self.production = production
        self.trusted_proxy_networks = trusted_proxy_networks
        self.trusted_proxy_hops = trusted_proxy_hops

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return

        async def send_with_security_headers(message: Message) -> None:
            if message["type"] == "http.response.start":
                headers = list(message.get("headers", []))
                existing = {name.lower() for name, _value in headers}
                for name, value in SECURITY_HEADERS:
                    if name not in existing:
                        headers.append((name, value))
                request_path = str(scope.get("path", ""))
                if (
                    b"cache-control" not in existing
                    and request_path.startswith("/api/v1/")
                ):
                    headers.append((b"cache-control", b"no-store"))
                trusted_forwarded_proto = _trusted_forwarded_proto(
                    scope,
                    trusted_proxy_networks=self.trusted_proxy_networks,
                    trusted_proxy_hops=self.trusted_proxy_hops,
                )
                if (
                    self.production
                    and (
                        scope.get("scheme") == "https"
                        or trusted_forwarded_proto == "https"
                    )
                    and b"strict-transport-security" not in existing
                ):
                    headers.append(
                        (b"strict-transport-security", STRICT_TRANSPORT_SECURITY)
                    )
                message = {**message, "headers": headers}
            await send(message)

        await self.app(scope, receive, send_with_security_headers)


class RequestBodyLimitMiddleware:
    """Bound request buffering before FastAPI parses JSON.

    FastAPI normally materializes request bodies before dependency execution, so
    a limit inside device authentication is too late for a chunked upload. This
    ASGI middleware consumes chunks incrementally, keeps at most ``max_bytes``,
    and only then replays the body to the application.
    """

    def __init__(self, app: Callable[..., Awaitable[None]], max_bytes: int) -> None:
        self.app = app
        self.max_bytes = max_bytes

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return

        content_length = _content_length(scope)
        if content_length is not None and content_length > self.max_bytes:
            await self._reject(scope, receive, send)
            return

        buffered: list[Message] = []
        total = 0
        while True:
            message = await receive()
            if message["type"] == "http.disconnect":
                return
            if message["type"] != "http.request":
                buffered.append(message)
                continue
            chunk = message.get("body", b"")
            total += len(chunk)
            if total > self.max_bytes:
                await self._reject(scope, receive, send)
                return
            buffered.append(message)
            if not message.get("more_body", False):
                break

        index = 0

        async def replay_receive() -> Message:
            nonlocal index
            if index < len(buffered):
                message = buffered[index]
                index += 1
                return message
            return {"type": "http.request", "body": b"", "more_body": False}

        await self.app(scope, replay_receive, send)

    async def _reject(self, scope: Scope, receive: Receive, send: Send) -> None:
        response = JSONResponse(
            status_code=413,
            content={"detail": "request body exceeds two MiB"},
        )
        await response(scope, receive, send)


def _content_length(scope: Scope) -> int | None:
    for name, value in scope.get("headers", []):
        if name.lower() == b"content-length":
            try:
                parsed = int(value)
            except ValueError:
                return None
            return max(parsed, 0)
    return None
