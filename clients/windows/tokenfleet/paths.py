from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class ClientPaths:
    root: Path
    data: Path
    state: Path
    credential: Path
    community_config: Path
    community_digest: Path
    install_marker: Path

    @classmethod
    def default(cls) -> "ClientPaths":
        local_app_data = os.environ.get("LOCALAPPDATA")
        if not local_app_data:
            if os.name == "nt":
                raise RuntimeError("LOCALAPPDATA is unavailable")
            local_app_data = str(Path.home() / ".local" / "share")
        root = Path(local_app_data) / "TokenFleet"
        data = root / "data"
        # The launcher imports this module from ...\TokenFleet\app\tokenfleet.
        # Keep the public, pinned community configuration bound to that app
        # directory; LOCALAPPDATA remains appropriate only for per-user data.
        app = Path(__file__).resolve().parent.parent
        return cls(
            root=root,
            data=data,
            state=data / "state.json",
            credential=data / "credential.dpapi",
            community_config=app / "community.json",
            community_digest=app / "community.sha256",
            install_marker=root / ".installed",
        )


def default_source_home() -> Path:
    profile = os.environ.get("USERPROFILE")
    return Path(profile) if profile else Path.home()
