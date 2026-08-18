from __future__ import annotations

import ctypes
import os
import time


class SensitiveClipboardError(RuntimeError):
    pass


def copy_sensitive_text(value: str) -> None:
    """Copy without command-line/stdout exposure and opt out of cloud history."""

    if os.name != "nt":
        raise SensitiveClipboardError("安全剪贴板仅可在 Windows 上使用")
    if not value or "\x00" in value:
        raise SensitiveClipboardError("设备码无法复制到安全剪贴板")

    user32 = ctypes.windll.user32
    kernel32 = ctypes.windll.kernel32
    user32.OpenClipboard.argtypes = [ctypes.c_void_p]
    user32.OpenClipboard.restype = ctypes.c_int
    user32.EmptyClipboard.argtypes = []
    user32.EmptyClipboard.restype = ctypes.c_int
    user32.SetClipboardData.argtypes = [ctypes.c_uint, ctypes.c_void_p]
    user32.SetClipboardData.restype = ctypes.c_void_p
    user32.RegisterClipboardFormatW.argtypes = [ctypes.c_wchar_p]
    user32.RegisterClipboardFormatW.restype = ctypes.c_uint
    user32.CloseClipboard.argtypes = []
    user32.CloseClipboard.restype = ctypes.c_int
    kernel32.GlobalAlloc.argtypes = [ctypes.c_uint, ctypes.c_size_t]
    kernel32.GlobalAlloc.restype = ctypes.c_void_p
    kernel32.GlobalLock.argtypes = [ctypes.c_void_p]
    kernel32.GlobalLock.restype = ctypes.c_void_p
    kernel32.GlobalUnlock.argtypes = [ctypes.c_void_p]
    kernel32.GlobalUnlock.restype = ctypes.c_int
    kernel32.GlobalFree.argtypes = [ctypes.c_void_p]
    kernel32.GlobalFree.restype = ctypes.c_void_p
    opened = False
    for _attempt in range(5):
        if user32.OpenClipboard(None):
            opened = True
            break
        time.sleep(0.05)
    if not opened:
        raise SensitiveClipboardError("无法打开 Windows 剪贴板")

    allocations: list[int] = []

    def set_clipboard_bytes(format_id: int, payload: bytes) -> None:
        handle = kernel32.GlobalAlloc(0x0002, len(payload))
        if not handle:
            raise SensitiveClipboardError("无法安全分配剪贴板内存")
        allocations.append(int(handle))
        pointer = kernel32.GlobalLock(handle)
        if not pointer:
            raise SensitiveClipboardError("无法安全锁定剪贴板内存")
        try:
            ctypes.memmove(pointer, payload, len(payload))
        finally:
            kernel32.GlobalUnlock(handle)
        if not user32.SetClipboardData(format_id, handle):
            raise SensitiveClipboardError("无法写入 Windows 剪贴板")
        allocations.remove(int(handle))  # clipboard now owns this allocation

    try:
        if not user32.EmptyClipboard():
            raise SensitiveClipboardError("无法清空 Windows 剪贴板")
        zero = (0).to_bytes(4, byteorder="little")
        for format_name in (
            "CanIncludeInClipboardHistory",
            "CanUploadToCloudClipboard",
            "ExcludeClipboardContentFromMonitorProcessing",
        ):
            format_id = user32.RegisterClipboardFormatW(format_name)
            if not format_id:
                raise SensitiveClipboardError("无法保护 Windows 剪贴板历史")
            set_clipboard_bytes(format_id, zero)
        set_clipboard_bytes(13, (value + "\x00").encode("utf-16-le"))
    finally:
        for handle in allocations:
            kernel32.GlobalFree(handle)
        user32.CloseClipboard()
