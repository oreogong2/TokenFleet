"""TokenFleet Windows collector.

The package intentionally depends only on Python's standard library. It reads
local accounting logs, never prompts or source text, and uploads exact daily
aggregates through the TeamSync v1 protocol.
"""

from .constants import APP_VERSION, COLLECTOR_VERSION

__all__ = ["APP_VERSION", "COLLECTOR_VERSION"]
