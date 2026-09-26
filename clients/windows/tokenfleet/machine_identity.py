from __future__ import annotations

import hashlib
import uuid

from .protocol import ProtocolError


def fingerprint_for_guid(text: str) -> str:
    try:
        guid = uuid.UUID(text)
    except (ValueError, TypeError, AttributeError) as exc:
        raise ProtocolError("无法确认当前机器身份，尚未发送数据") from exc
    if guid.int == 0:
        raise ProtocolError("无法确认当前机器身份，尚未发送数据")
    value = "TokenFleet machine identity v1:\nwindows\n" + str(guid)
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def current_machine_fingerprint() -> str:
    try:
        import winreg
        with winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE,
                            r"SOFTWARE\Microsoft\Cryptography", 0,
                            winreg.KEY_READ | winreg.KEY_WOW64_64KEY) as key:
            value, kind = winreg.QueryValueEx(key, "MachineGuid")
            if kind != winreg.REG_SZ:
                raise ValueError("invalid machine identity type")
        return fingerprint_for_guid(value)
    except (ImportError, OSError, ValueError) as exc:
        raise ProtocolError("无法确认当前机器身份，尚未发送数据") from exc
