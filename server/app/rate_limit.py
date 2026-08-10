from __future__ import annotations

import math
import threading
import time
from collections import deque


class LoginRateLimiter:
    """A small, process-local sliding-window limiter for login attempts."""

    def __init__(
        self,
        *,
        attempts: int,
        window_seconds: int,
        ip_attempts: int | None = None,
        max_keys: int = 10_000,
    ) -> None:
        self.attempts = attempts
        self.ip_attempts = ip_attempts or attempts * 5
        self.window_seconds = window_seconds
        self.max_keys = max_keys
        self._events: dict[str, deque[float]] = {}
        self._lock = threading.Lock()
        self._operations = 0

    def consume(self, account_key: str, ip_key: str | None = None) -> int | None:
        """Record configured buckets or return whole retry seconds when blocked.

        The account bucket is always active. The caller supplies an IP bucket
        only after resolving a direct peer or a configured trusted-proxy chain;
        invalid configured chains are rejected before reaching this limiter.
        """

        now = time.monotonic()
        cutoff = now - self.window_seconds
        with self._lock:
            self._operations += 1
            if self._operations % 256 == 0 or len(self._events) >= self.max_keys:
                self._purge_expired(cutoff)

            account_events = self._bucket(account_key)
            self._trim(account_events, cutoff)
            retry_after = self._retry_after(account_events, self.attempts, now)
            ip_events = None
            if ip_key is not None:
                ip_events = self._bucket(ip_key, protected={account_key})
                self._trim(ip_events, cutoff)
                retry_after = max(
                    retry_after,
                    self._retry_after(ip_events, self.ip_attempts, now),
                )
            if retry_after:
                return retry_after
            account_events.append(now)
            if ip_events is not None:
                ip_events.append(now)
            return None

    def clear(self, account_key: str) -> None:
        with self._lock:
            self._events.pop(account_key, None)

    def _bucket(
        self, key: str, protected: set[str] | None = None
    ) -> deque[float]:
        events = self._events.get(key)
        if events is not None:
            return events
        if len(self._events) >= self.max_keys:
            # Keep memory bounded even under high-cardinality random accounts.
            # Evict the least-recently-used bucket; the per-IP bucket remains a
            # second line of defense against email rotation.
            candidates = set(self._events) - (protected or set())
            oldest_key = min(
                candidates,
                key=lambda candidate: self._events[candidate][-1]
                if self._events[candidate]
                else float("-inf"),
            )
            self._events.pop(oldest_key, None)
        events = deque()
        self._events[key] = events
        return events

    def _purge_expired(self, cutoff: float) -> None:
        for key in list(self._events):
            events = self._events[key]
            self._trim(events, cutoff)
            if not events:
                self._events.pop(key, None)

    @staticmethod
    def _trim(events: deque[float], cutoff: float) -> None:
        while events and events[0] <= cutoff:
            events.popleft()

    def _retry_after(
        self, events: deque[float], limit: int, now: float
    ) -> int:
        if len(events) < limit:
            return 0
        return max(1, math.ceil(events[0] + self.window_seconds - now))


class PublicReadRateLimiter:
    """Bounded process-local limiter shared by anonymous public read routes."""

    def __init__(self, *, attempts: int, window_seconds: int, max_keys: int) -> None:
        self.attempts = attempts
        self.window_seconds = window_seconds
        self.max_keys = max_keys
        self._events: dict[str, deque[float]] = {}
        self._lock = threading.Lock()
        self._operations = 0

    def consume(self, key: str) -> int | None:
        now = time.monotonic()
        cutoff = now - self.window_seconds
        with self._lock:
            self._operations += 1
            if self._operations % 256 == 0 or len(self._events) >= self.max_keys:
                self._purge_expired(cutoff)
            events = self._events.get(key)
            if events is None:
                if len(self._events) >= self.max_keys:
                    oldest_key = min(
                        self._events,
                        key=lambda candidate: self._events[candidate][-1]
                        if self._events[candidate]
                        else float("-inf"),
                    )
                    self._events.pop(oldest_key, None)
                events = deque()
                self._events[key] = events
            self._trim(events, cutoff)
            if len(events) >= self.attempts:
                return max(
                    1,
                    math.ceil(events[0] + self.window_seconds - now),
                )
            events.append(now)
            return None

    def _purge_expired(self, cutoff: float) -> None:
        for key in list(self._events):
            events = self._events[key]
            self._trim(events, cutoff)
            if not events:
                self._events.pop(key, None)

    @staticmethod
    def _trim(events: deque[float], cutoff: float) -> None:
        while events and events[0] <= cutoff:
            events.popleft()
