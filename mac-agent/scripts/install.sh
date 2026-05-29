#!/usr/bin/env bash
set -euo pipefail

# Build a release binary and install lamp-agent as a launchd LaunchAgent.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAC_AGENT_DIR="$(dirname "$SCRIPT_DIR")"

BIN_DEST="/usr/local/bin/lamp-agent"
PLIST_LABEL="com.lamp.agent"
PLIST_DEST="$HOME/Library/LaunchAgents/${PLIST_LABEL}.plist"
CONFIG_DIR="$HOME/.config/lamp-agent"
STATE_DIR="$HOME/.local/state/lamp-agent"

echo "==> Building release binary"
( cd "$MAC_AGENT_DIR" && swift build -c release )
BIN_SRC="$MAC_AGENT_DIR/.build/release/lamp-agent"

echo "==> Installing binary to $BIN_DEST (may prompt for sudo)"
sudo install -m 0755 "$BIN_SRC" "$BIN_DEST"

echo "==> Creating config and state directories"
mkdir -p "$CONFIG_DIR" "$STATE_DIR" "$HOME/Library/Logs"
chmod 700 "$CONFIG_DIR" "$STATE_DIR"
if [ ! -f "$CONFIG_DIR/config.toml" ]; then
    install -m 0600 "$MAC_AGENT_DIR/Resources/config.toml.example" "$CONFIG_DIR/config.toml"
    echo "    Wrote starter config to $CONFIG_DIR/config.toml — edit it before the agent will work."
fi

echo "==> Installing LaunchAgent to $PLIST_DEST"
mkdir -p "$HOME/Library/LaunchAgents"
sed "s|__HOME__|$HOME|g" "$MAC_AGENT_DIR/Resources/com.lamp.agent.plist" > "$PLIST_DEST"

echo "==> Loading the agent"
launchctl bootout "gui/$(id -u)/${PLIST_LABEL}" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST_DEST"
launchctl enable "gui/$(id -u)/${PLIST_LABEL}"

echo "==> Done. Check logs at $HOME/Library/Logs/lamp-agent.log"
