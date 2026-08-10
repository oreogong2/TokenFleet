#!/usr/bin/env bash
set -euo pipefail

echo "LEGACY PROTOTYPE: this removes only the historical Python launchd job; it does not uninstall TokenFleet." >&2

LABEL="com.huangshu.token-usage-monitor"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

launchctl bootout "gui/$(id -u)" "$PLIST" >/dev/null 2>&1 || true
rm -f "$PLIST"

echo "Uninstalled $LABEL"
