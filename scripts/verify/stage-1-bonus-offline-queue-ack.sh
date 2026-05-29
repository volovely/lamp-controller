#!/usr/bin/env bash
# Stage 1 Task 15 Bonus — offline queue/ack path end-to-end (no real lamp)
# Scenario A: Fresh command + Homebridge unreachable → failed=true, no acked.json
# Scenario B: Stale command + Homebridge unreachable → stale=[...], acked.json written, exit 0
set -euo pipefail

export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0
FAIL=0

run_once() {
    local cfg="$1"
    LAMP_AGENT_CONFIG="$cfg" \
        swift run --package-path "$REPO_ROOT/mac-agent" lamp-agent --once 2>&1 | grep "lamp-agent:"
}

# ── Scenario A: Fresh command, Homebridge unreachable ────────────────────────
echo "==> Scenario A: Fresh command, port 9 (nothing listening)"
TMP_A=$(mktemp -d)
trap 'rm -rf "$TMP_A" "$TMP_B"' EXIT

cat > "$TMP_A/config.toml" <<EOF
homebridge_url   = "http://127.0.0.1:9"
homebridge_token = "unused"
accessory_id     = "lamp-desk"
commands_path    = "$TMP_A/commands.json"
poll_interval_s  = 12
EOF

NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
UUID_FRESH="11111111-1111-1111-1111-aaaaaaaaaaaa"
cat > "$TMP_A/commands.json" <<EOF
[{"id":"$UUID_FRESH","action":"on","brightness":50,"created_at":"$NOW","source_msg_id":"verify-fresh"}]
EOF

OUTPUT_A=$(run_once "$TMP_A/config.toml")
echo "  Output : $OUTPUT_A"

SCENARIO_A_OK=1
if ! echo "$OUTPUT_A" | grep -qF "failed=true"; then
    echo "  FAIL: expected failed=true"
    SCENARIO_A_OK=0
fi
if [ -f "$TMP_A/acked.json" ]; then
    echo "  FAIL: acked.json should NOT exist (command must not be acked on failure)"
    SCENARIO_A_OK=0
fi
if [ "$SCENARIO_A_OK" -eq 1 ]; then
    echo "  PASS: failed=true and acked.json absent"
    PASS=$((PASS + 1))
else
    FAIL=$((FAIL + 1))
fi

# ── Scenario B: Stale command (15 min old), Homebridge unreachable ────────────
echo ""
echo "==> Scenario B: Stale command (15 min old), port 9 (nothing listening)"
TMP_B=$(mktemp -d)

cat > "$TMP_B/config.toml" <<EOF
homebridge_url   = "http://127.0.0.1:9"
homebridge_token = "unused"
accessory_id     = "lamp-desk"
commands_path    = "$TMP_B/commands.json"
poll_interval_s  = 12
EOF

STALE_TIME=$(date -u -v-15M +%Y-%m-%dT%H:%M:%SZ)
UUID_STALE="22222222-2222-2222-2222-bbbbbbbbbbbb"
cat > "$TMP_B/commands.json" <<EOF
[{"id":"$UUID_STALE","action":"on","brightness":80,"created_at":"$STALE_TIME","source_msg_id":"verify-stale"}]
EOF

OUTPUT_B=$(run_once "$TMP_B/config.toml")
echo "  Output : $OUTPUT_B"

SCENARIO_B_OK=1
if ! echo "$OUTPUT_B" | grep -qF "stale=[\"$UUID_STALE\"]"; then
    echo "  FAIL: expected stale to contain UUID"
    SCENARIO_B_OK=0
fi
if ! echo "$OUTPUT_B" | grep -qF "failed=false"; then
    echo "  FAIL: expected failed=false (no Homebridge attempt for stale command)"
    SCENARIO_B_OK=0
fi
if [ ! -f "$TMP_B/acked.json" ]; then
    echo "  FAIL: acked.json should exist (stale command must be acked to prevent re-reads)"
    SCENARIO_B_OK=0
else
    ACKED_CONTENT=$(cat "$TMP_B/acked.json")
    echo "  acked.json: $ACKED_CONTENT"
    if ! echo "$ACKED_CONTENT" | grep -qF "$UUID_STALE"; then
        echo "  FAIL: UUID not present in acked.json"
        SCENARIO_B_OK=0
    fi
fi
if [ "$SCENARIO_B_OK" -eq 1 ]; then
    echo "  PASS: stale command dropped, acked, no Homebridge call"
    PASS=$((PASS + 1))
else
    FAIL=$((FAIL + 1))
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "==> Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
