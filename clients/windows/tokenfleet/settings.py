from __future__ import annotations

import json
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any

from .state import atomic_write


class SettingsError(RuntimeError):
    pass


@dataclass(frozen=True)
class ClientSettings:
    version: int = 2
    experimental_sources_enabled: bool = True
    experimental_sources_configured: bool = False

    @classmethod
    def from_object(cls, value: Any) -> "ClientSettings":
        if not isinstance(value, dict):
            raise SettingsError("TokenFleet local settings are invalid")

        if set(value) == {"version", "experimental_sources_enabled"}:
            if value.get("version") != 1 or type(value.get("experimental_sources_enabled")) is not bool:
                raise SettingsError("TokenFleet local settings are invalid")
            # Version 1 was only written by an explicit CLI/dashboard toggle, so
            # its value is user intent rather than an automatically persisted
            # default. Preserve it while migrating to the version 2 model.
            return cls(
                experimental_sources_enabled=value["experimental_sources_enabled"],
                experimental_sources_configured=True,
            )

        if set(value) != {
            "version",
            "experimental_sources_enabled",
            "experimental_sources_configured",
        }:
            raise SettingsError("TokenFleet local settings are invalid")
        if (
            value.get("version") != 2
            or type(value.get("experimental_sources_enabled")) is not bool
            or type(value.get("experimental_sources_configured")) is not bool
        ):
            raise SettingsError("TokenFleet local settings are invalid")
        configured = value["experimental_sources_configured"]
        return cls(
            experimental_sources_enabled=(
                value["experimental_sources_enabled"]
                if configured
                else cls().experimental_sources_enabled
            ),
            experimental_sources_configured=configured,
        )


class SettingsStore:
    def __init__(self, path: Path) -> None:
        self.path = path

    def load(self) -> ClientSettings:
        if not self.path.exists():
            return ClientSettings()
        try:
            return ClientSettings.from_object(
                json.loads(self.path.read_text(encoding="utf-8"))
            )
        except (OSError, UnicodeError, json.JSONDecodeError) as exc:
            raise SettingsError("TokenFleet local settings are unreadable") from exc

    def save(self, settings: ClientSettings) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        atomic_write(
            self.path,
            json.dumps(
                asdict(settings),
                ensure_ascii=True,
                sort_keys=True,
                separators=(",", ":"),
            ).encode("utf-8"),
        )

    def set_experimental_sources(self, enabled: bool) -> ClientSettings:
        settings = ClientSettings(
            experimental_sources_enabled=enabled,
            experimental_sources_configured=True,
        )
        self.save(settings)
        return settings
