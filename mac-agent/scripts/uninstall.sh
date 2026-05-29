#!/usr/bin/env bash
set -euo pipefail

PLIST_LABEL="com.lamp.agent"
PLIST_DEST="$HOME/Library/LaunchAgents/${PLIST_LABEL}.plist"
BIN_DEST="/usr/local/bin/lamp-agent"

echo "==> Unloading the agent"
launchctl bootout "gui/$(id -u)/${PLIST_LABEL}" 2>/dev/null || true

echo "==> Removing LaunchAgent plist"
rm -f "$PLIST_DEST"

echo "==> Removing binary (may prompt for sudo)"
sudo rm -f "$BIN_DEST"

echo "==> Done. Config and state under ~/.config/lamp-agent and ~/.local/state/lamp-agent were left in place."
