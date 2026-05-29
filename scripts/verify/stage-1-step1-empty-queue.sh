#!/usr/bin/env bash
# Stage 1 Task 15 Step 1 — empty queue, no hardware
# Proves: lamp-agent --once with empty commands.json prints
#   "applied=[] stale=[] failed=false" and exits 0 with no Homebridge dependency.
set -euo pipefail

export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/config.toml" <<EOF
homebridge_url   = "http://127.0.0.1:8581"
homebridge_token = "placeholder"
accessory_id     = "lamp-desk"
commands_path    = "$TMP/commands.json"
poll_interval_s  = 12
EOF

echo "[]" > "$TMP/commands.json"

echo "==> Running lamp-agent --once (empty queue)"
OUTPUT=$(LAMP_AGENT_CONFIG="$TMP/config.toml" \
    swift run --package-path "$REPO_ROOT/mac-agent" lamp-agent --once 2>&1 | grep "lamp-agent:")

echo "$OUTPUT"

if echo "$OUTPUT" | grep -qF "applied=[] stale=[] failed=false"; then
    echo "PASS: got expected output"
    exit 0
else
    echo "FAIL: unexpected output"
    exit 1
fi
