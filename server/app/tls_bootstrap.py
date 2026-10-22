"""Install the application CA policy before importing outbound HTTP clients."""
from __future__ import annotations

import os
from pathlib import Path
import ssl
import tempfile

from .tls_policy import activate

def initialize_tls_policy() -> None:
    source = Path(os.environ.get("TOKENFLEET_TLS_SOURCE") or ssl.get_default_verify_paths().openssl_cafile)
    output = Path(os.environ.get("TOKENFLEET_TLS_OUTPUT") or tempfile.mkdtemp(prefix="tokenfleet-tls-"))
    activate(source, output)
