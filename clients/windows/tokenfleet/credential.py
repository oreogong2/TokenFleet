from __future__ import annotations

import ctypes
import json
import os
import re
import uuid
from ctypes import wintypes
from dataclasses import dataclass
from pathlib import Path
from typing import Protocol

from .constants import DPAPI_ENTROPY, DPAPI_FILE_MAGIC, SIGNING_KEY_DERIVATION
from .state import atomic_write


class CredentialError(RuntimeError):
    pass


class CredentialUnavailable(CredentialError):
    pass


class DataProtector(Protocol):
    def protect(self, value: bytes) -> bytes: ...

    def unprotect(self, value: bytes) -> bytes: ...


@dataclass(frozen=True)
class DeviceCredential:
    server_origin: str
    device_id: str
    device_public_id: str
    device_secret: str
    signing_key_derivation: str = SIGNING_KEY_DERIVATION
    version: int = 1

    def validate(self) -> "DeviceCredential":
        try:
            device_public_id = str(uuid.UUID(self.device_public_id))
            device_id = str(uuid.UUID(self.device_id))
        except (ValueError, AttributeError) as exc:
            raise CredentialUnavailable("stored device identity is invalid") from exc
        if (
            self.version != 1
            or device_public_id != self.device_public_id
            or device_id != self.device_id
            or self.signing_key_derivation != SIGNING_KEY_DERIVATION
            or not re.fullmatch(r"[A-Za-z0-9_-]{16,256}", self.device_secret)
        ):
            raise CredentialUnavailable("stored device credential is invalid")
        return self

    def encoded(self) -> bytes:
        value = {
            "device_id": self.device_id,
            "device_public_id": self.device_public_id,
            "device_secret": self.device_secret,
            "server_origin": self.server_origin,
            "signing_key_derivation": self.signing_key_derivation,
            "version": self.version,
        }
        return json.dumps(
            value, ensure_ascii=True, sort_keys=True, separators=(",", ":")
        ).encode("utf-8")

    @classmethod
    def decode(cls, payload: bytes) -> "DeviceCredential":
        try:
            value = json.loads(payload.decode("utf-8"))
        except (UnicodeError, json.JSONDecodeError) as exc:
            raise CredentialUnavailable("stored device credential is invalid") from exc
        expected = {
            "device_id",
            "device_public_id",
            "device_secret",
            "server_origin",
            "signing_key_derivation",
            "version",
        }
        if not isinstance(value, dict) or set(value) != expected:
            raise CredentialUnavailable("stored device credential is invalid")
        try:
            credential = cls(**value)
        except TypeError as exc:
            raise CredentialUnavailable("stored device credential is invalid") from exc
        if not all(
            isinstance(item, str)
            for item in (
                credential.server_origin,
                credential.device_id,
                credential.device_public_id,
                credential.device_secret,
                credential.signing_key_derivation,
            )
        ) or type(credential.version) is not int:
            raise CredentialUnavailable("stored device credential is invalid")
        return credential.validate()


class DPAPIProtector:
    """Windows CurrentUser DPAPI with interactive credential UI forbidden."""

    class _DATA_BLOB(ctypes.Structure):
        _fields_ = [("cbData", wintypes.DWORD), ("pbData", ctypes.POINTER(ctypes.c_byte))]

    def __init__(self, entropy: bytes = DPAPI_ENTROPY) -> None:
        if os.name != "nt":
            raise CredentialUnavailable("Windows DPAPI is unavailable on this platform")
        self.entropy = entropy
        try:
            self._crypt32 = ctypes.WinDLL("crypt32", use_last_error=True)
            self._kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
        except (AttributeError, OSError) as exc:
            raise CredentialUnavailable("Windows DPAPI is unavailable") from exc
        blob_pointer = ctypes.POINTER(self._DATA_BLOB)
        self._crypt32.CryptProtectData.argtypes = [
            blob_pointer,
            wintypes.LPCWSTR,
            blob_pointer,
            wintypes.LPVOID,
            wintypes.LPVOID,
            wintypes.DWORD,
            blob_pointer,
        ]
        self._crypt32.CryptProtectData.restype = wintypes.BOOL
        self._crypt32.CryptUnprotectData.argtypes = [
            blob_pointer,
            ctypes.POINTER(wintypes.LPWSTR),
            blob_pointer,
            wintypes.LPVOID,
            wintypes.LPVOID,
            wintypes.DWORD,
            blob_pointer,
        ]
        self._crypt32.CryptUnprotectData.restype = wintypes.BOOL
        self._kernel32.LocalFree.argtypes = [wintypes.HLOCAL]
        self._kernel32.LocalFree.restype = wintypes.HLOCAL

    @staticmethod
    def _blob(value: bytes) -> tuple["DPAPIProtector._DATA_BLOB", object]:
        buffer = ctypes.create_string_buffer(value, len(value))
        pointer = ctypes.cast(buffer, ctypes.POINTER(ctypes.c_byte))
        return DPAPIProtector._DATA_BLOB(len(value), pointer), buffer

    def protect(self, value: bytes) -> bytes:
        return self._transform(value, protect=True)

    def unprotect(self, value: bytes) -> bytes:
        return self._transform(value, protect=False)

    def _transform(self, value: bytes, *, protect: bool) -> bytes:
        if not value:
            raise CredentialUnavailable("empty DPAPI payload")
        source, source_buffer = self._blob(value)
        entropy, entropy_buffer = self._blob(self.entropy)
        destination = self._DATA_BLOB()
        description = wintypes.LPWSTR()
        flags = 0x1  # CRYPTPROTECT_UI_FORBIDDEN; CurrentUser scope is the default.
        if protect:
            success = self._crypt32.CryptProtectData(
                ctypes.byref(source),
                "TokenFleet TeamSync credential",
                ctypes.byref(entropy),
                None,
                None,
                flags,
                ctypes.byref(destination),
            )
        else:
            success = self._crypt32.CryptUnprotectData(
                ctypes.byref(source),
                ctypes.byref(description),
                ctypes.byref(entropy),
                None,
                None,
                flags,
                ctypes.byref(destination),
            )
        # Keep the ctypes input buffers alive through the native call.
        _ = (source_buffer, entropy_buffer)
        try:
            if not success:
                raise CredentialUnavailable("Windows DPAPI operation failed")
            return ctypes.string_at(destination.pbData, destination.cbData)
        finally:
            if destination.pbData:
                self._kernel32.LocalFree(ctypes.cast(destination.pbData, wintypes.HLOCAL))
            if description:
                self._kernel32.LocalFree(ctypes.cast(description, wintypes.HLOCAL))


class CredentialStore:
    def __init__(self, path: Path, protector: DataProtector | None = None) -> None:
        self.path = path
        self.protector = protector if protector is not None else DPAPIProtector()

    @property
    def exists(self) -> bool:
        return self.path.is_file()

    def prepare(self) -> None:
        probe = b"TokenFleet DPAPI availability probe"
        if self.protector.unprotect(self.protector.protect(probe)) != probe:
            raise CredentialUnavailable("Windows DPAPI round trip failed")
        self.path.parent.mkdir(parents=True, exist_ok=True)
        probe_path = self.path.parent / ".credential-write-probe"
        try:
            atomic_write(probe_path, b"probe")
            probe_path.unlink(missing_ok=True)
        except (OSError, RuntimeError) as exc:
            raise CredentialUnavailable("credential directory is not writable") from exc

    def save(self, credential: DeviceCredential) -> None:
        credential.validate()
        self.path.parent.mkdir(parents=True, exist_ok=True)
        protected = self.protector.protect(credential.encoded())
        atomic_write(self.path, DPAPI_FILE_MAGIC + protected)

    def load(self) -> DeviceCredential:
        try:
            payload = self.path.read_bytes()
        except FileNotFoundError as exc:
            raise CredentialUnavailable("this device is not connected") from exc
        except OSError as exc:
            raise CredentialUnavailable("device credential is unreadable") from exc
        if not payload.startswith(DPAPI_FILE_MAGIC) or len(payload) <= len(DPAPI_FILE_MAGIC):
            raise CredentialUnavailable("device credential is invalid")
        cleartext = bytearray(self.protector.unprotect(payload[len(DPAPI_FILE_MAGIC) :]))
        try:
            return DeviceCredential.decode(bytes(cleartext))
        finally:
            for index in range(len(cleartext)):
                cleartext[index] = 0

    def clear(self) -> None:
        try:
            self.path.unlink(missing_ok=True)
        except OSError as exc:
            raise CredentialError("device credential could not be removed") from exc
