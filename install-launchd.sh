#!/usr/bin/env bash
set -euo pipefail

if [[ "${TOKEN_USAGE_MONITOR_ALLOW_LEGACY_INSTALL:-}" != "YES" ]]; then
  cat >&2 <<'WARNING'
LEGACY PROTOTYPE — NOT A TOKENFLEET INSTALLER

This script belongs to the historical Python/launchd prototype. It cannot
install TokenFleet, connect a device to a TokenFleet community, or enable the
TokenFleet ranking workflow. Follow README.md and docs/INSTALL.md instead.
No changes were made.

Existing prototype maintainers can deliberately run the historical installer
with TOKEN_USAGE_MONITOR_ALLOW_LEGACY_INSTALL=YES.
WARNING
  exit 2
fi

echo "LEGACY PROTOTYPE: installing the historical Python launchd job, not TokenFleet." >&2

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LABEL="com.huangshu.token-usage-monitor"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG_DIR="$SCRIPT_DIR/logs"

mkdir -p "$HOME/Library/LaunchAgents" "$LOG_DIR"

cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/python3</string>
    <string>$SCRIPT_DIR/token_usage_monitor.py</string>
    <string>collect</string>
  </array>
  <key>WorkingDirectory</key>
  <string>$SCRIPT_DIR</string>
  <key>StartInterval</key>
  <integer>1800</integer>
  <key>RunAtLoad</key>
  <true/>
  <key>StandardOutPath</key>
  <string>$LOG_DIR/launchd.out.log</string>
  <key>StandardErrorPath</key>
  <string>$LOG_DIR/launchd.err.log</string>
</dict>
</plist>
PLIST

launchctl bootout "gui/$(id -u)" "$PLIST" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
launchctl kickstart -k "gui/$(id -u)/$LABEL"

echo "Installed $LABEL"
echo "Dashboard: $SCRIPT_DIR/dashboard.html"
