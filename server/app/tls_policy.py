"""Project TLS policy: keep the source roots except two distrusted fingerprints.

Run prepare during deployment, or activate before importing network clients.
No network, credentials, application data, or platform trust store is changed.
"""
from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import ssl
import stat
import tempfile

DENIED = frozenset({
    "86a1ecba089c4a8d3bbe2734c612ba341d813e043cf9e8a862cd5c57a36bbe6b",
    "d7a7a0fb5d7e2731d771e9484ebcdef71d5f0c3e0a2948782bc83ee0ea699ef4",
})
PEM = re.compile(rb"-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----", re.S)

def private_output(output: Path, *, create: bool = False) -> Path:
    """Use only caller-owned output beneath trusted directory ancestors."""
    output = output.absolute()
    if output.is_symlink():
        raise ValueError("TLS policy directory must not be a symlink")
    # Resolve parent aliases once and use the canonical path thereafter.
    parent = output.parent.resolve(strict=True)
    uid = os.geteuid()
    for ancestor in (parent, *parent.parents):
        info = ancestor.stat()
        shared_sticky = info.st_uid == 0 and bool(info.st_mode & stat.S_ISVTX)
        if info.st_uid not in {0, uid} or (info.st_mode & 0o022 and not shared_sticky):
            raise ValueError("TLS policy parent is not trusted")
    output = parent / output.name
    if create:
        output.mkdir(mode=0o700, exist_ok=True)
    fd = os.open(output, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        info = os.fstat(fd)
        if info.st_uid != uid or info.st_mode & 0o022:
            raise ValueError("TLS policy directory must be owned and writable only by this user")
    finally:
        os.close(fd)
    return output

def roots(data: bytes) -> dict[str, bytes]:
    result = {}
    for block in PEM.findall(data):
        der = ssl.PEM_cert_to_DER_cert(block.decode("ascii"))
        result[hashlib.sha256(der).hexdigest()] = block + b"\n"
    if not result:
        raise ValueError("CA source has no certificates")
    return result

def atomic_write(path: Path, data: bytes) -> None:
    if path.is_symlink():
        raise ValueError("TLS output must not be a symlink")
    if path.is_file() and path.read_bytes() == data:
        return
    fd, name = tempfile.mkstemp(prefix=".tls-", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(data)
            f.flush()
            os.fchmod(f.fileno(), 0o644)
            os.fsync(f.fileno())
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)

def check(output: Path) -> dict[str, str]:
    output = private_output(output)
    bundle, empty = output / "ca-bundle.pem", output / "empty-ca-dir"
    if output.is_symlink() or bundle.is_symlink() or empty.is_symlink():
        raise ValueError("TLS policy paths must not be symlinks")
    if not empty.is_dir() or any(empty.iterdir()):
        raise ValueError("TLS CA directory must remain empty")
    data = bundle.read_bytes()
    if set(roots(data)) & DENIED:
        raise ValueError("TLS policy contains a distrusted root")
    manifest = json.loads((output / "manifest.json").read_text())
    if manifest.get("schema") != 1 or manifest.get("sha256") != hashlib.sha256(data).hexdigest():
        raise ValueError("TLS policy manifest mismatch")
    ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT).load_verify_locations(cafile=str(bundle))
    return {"SSL_CERT_FILE": str(bundle), "SSL_CERT_DIR": str(empty), "REQUESTS_CA_BUNDLE": str(bundle)}

def prepare(source: Path, output: Path) -> dict[str, str]:
    source, output = source.absolute(), output.absolute()
    if source.resolve() == (output / "ca-bundle.pem").resolve():
        raise ValueError("TLS policy must be refreshed from its original source")
    output = private_output(output, create=True)
    fd = os.open(output / ".lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o644)
    with os.fdopen(fd, "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        original = source.read_bytes()
        certs = roots(original)
        kept = {h: b for h, b in certs.items() if h not in DENIED}
        if not kept:
            raise ValueError("TLS policy would contain no trusted roots")
        data = b"".join(kept.values())
        # Parse before replacing a usable file.
        ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT).load_verify_locations(cadata=data.decode("ascii"))
        empty = output / "empty-ca-dir"
        if empty.is_symlink():
            raise ValueError("TLS CA directory must not be a symlink")
        empty.mkdir(mode=0o755, exist_ok=True)
        if any(empty.iterdir()):
            raise ValueError("TLS CA directory must remain empty")
        manifest = {"schema": 1, "source": str(source), "source_sha256": hashlib.sha256(original).hexdigest(),
                    "sha256": hashlib.sha256(data).hexdigest(), "source_count": len(certs),
                    "trusted_count": len(kept), "removed": sorted(set(certs) - set(kept))}
        atomic_write(output / "ca-bundle.pem", data)
        atomic_write(output / "manifest.json", json.dumps(manifest, sort_keys=True, indent=2).encode() + b"\n")
        return check(output)

def activate(source: Path, output: Path) -> None:
    os.environ.update(prepare(source, output))

def main() -> None:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("operation", choices=["prepare", "check", "run"])
    p.add_argument("--source", type=Path)
    p.add_argument("--output", type=Path, required=True)
    # Options must precede the command; '--' separates the executed argv.
    argv = __import__("sys").argv[1:]
    boundary = argv.index("--") if "--" in argv else len(argv)
    a = p.parse_args(argv[:boundary])
    command = argv[boundary + 1:]
    if a.operation != "check" and a.source is None:
        p.error("--source is required")
    env = check(a.output) if a.operation == "check" else prepare(a.source, a.output)
    if a.operation == "run":
        if not command:
            p.error("run requires -- command")
        os.execvpe(command[0], command, dict(os.environ, **env))
    print(json.dumps({"ok": True, "variables": sorted(env)}))

if __name__ == "__main__":
    main()
