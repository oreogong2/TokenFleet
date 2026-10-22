"""Install the application CA policy before importing outbound HTTP clients."""
from __future__ import annotations

import os
from pathlib import Path
import ssl

from .tls_policy import activate

def initialize_tls_policy() -> None:
    source = Path(os.environ.get("TOKENFLEET_TLS_SOURCE") or ssl.get_default_verify_paths().openssl_cafile)
    state = Path(os.environ.get("XDG_STATE_HOME") or Path.home() / ".local" / "state")
    output = Path(os.environ.get("TOKENFLEET_TLS_OUTPUT") or state / "tokenfleet" / "tls-policy")
    activate(source, output)
