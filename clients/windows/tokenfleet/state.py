from __future__ import annotations

import json
import os
import tempfile
import uuid
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any


class StateError(RuntimeError):
    pass


@dataclass
class ClientState:
    version: int = 1
    device_public_id: str = ""
    last_sync_at: str | None = None
    last_bucket_count: int = 0
    last_uploaded_tokens: int = 0

    @classmethod
    def new(cls) -> "ClientState":
        return cls(device_public_id=str(uuid.uuid4()))

    @classmethod
    def from_object(cls, value: Any) -> "ClientState":
        if not isinstance(value, dict) or set(value) - {
            "version",
            "device_public_id",
            "last_sync_at",
            "last_bucket_count",
            "last_uploaded_tokens",
        }:
            raise StateError("TokenFleet local state is invalid")
        try:
            version = value["version"]
            public_id = value["device_public_id"]
            parsed_id = uuid.UUID(public_id)
            bucket_count = value.get("last_bucket_count", 0)
            uploaded_tokens = value.get("last_uploaded_tokens", 0)
        except (KeyError, TypeError, ValueError, AttributeError) as exc:
            raise StateError("TokenFleet local state is invalid") from exc
        if (
            type(version) is not int
            or version != 1
            or str(parsed_id) != public_id
            or type(bucket_count) is not int
            or bucket_count < 0
            or type(uploaded_tokens) is not int
            or uploaded_tokens < 0
        ):
            raise StateError("TokenFleet local state is invalid")
        last_sync_at = value.get("last_sync_at")
        if last_sync_at is not None and not isinstance(last_sync_at, str):
            raise StateError("TokenFleet local state is invalid")
        return cls(
            version=version,
            device_public_id=public_id,
            last_sync_at=last_sync_at,
            last_bucket_count=bucket_count,
            last_uploaded_tokens=uploaded_tokens,
        )


class StateStore:
    def __init__(self, path: Path) -> None:
        self.path = path

    def load(self) -> ClientState:
        if not self.path.exists():
            return ClientState.new()
        try:
            raw = self.path.read_text(encoding="utf-8")
            return ClientState.from_object(json.loads(raw))
        except (OSError, UnicodeError, json.JSONDecodeError) as exc:
            raise StateError("TokenFleet local state is unreadable") from exc

    def save(self, state: ClientState) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        payload = json.dumps(
            asdict(state), ensure_ascii=True, sort_keys=True, separators=(",", ":")
        ).encode("utf-8")
        atomic_write(self.path, payload)

    def clear(self) -> None:
        try:
            self.path.unlink(missing_ok=True)
        except OSError as exc:
            raise StateError("TokenFleet local state could not be removed") from exc


def atomic_write(path: Path, payload: bytes) -> None:
    temporary_name: str | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="wb", dir=path.parent, prefix=f".{path.name}.", delete=False
        ) as handle:
            temporary_name = handle.name
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary_name, path)
        temporary_name = None
    except OSError as exc:
        raise StateError("TokenFleet local state could not be saved") from exc
    finally:
        if temporary_name:
            try:
                Path(temporary_name).unlink(missing_ok=True)
            except OSError:
                pass
