# Operational runbook

What to do when things break. Populated progressively across stages.

## Known incidents and responses

### Stage 1 — HomeKit backend (`lamp_backend = "homekit"`)

**Symptom:** `lamp-agent --once` prints `failed=true` and the lamp doesn't change.

**Causes and checks:**

1. **Helper app path wrong or not built.** Confirm `homekit_helper_path` in
   `config.toml` points to a real `.app` bundle. If the path is missing or
   stale, build the helper:
   ```bash
   cd mac-agent/homekit-helper
   export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
   xcodebuild -project LampHomeKitHelper.xcodeproj -scheme LampHomeKitHelper \
     -destination 'platform=macOS,variant=Mac Catalyst' \
     -derivedDataPath build -allowProvisioningUpdates build
   ```

2. **"Home Access" not granted.** If the helper has never been allowed, macOS
   silently blocks Home calls. Re-run discovery to trigger the prompt and click
   **Allow**:
   ```bash
   LAMP_HK_RESULT=/tmp/r open -W "/path/to/LampHomeKitHelper.app" --args --discover
   cat /tmp/r
   ```
   Also check System Settings → Privacy & Security → Home to confirm the
   helper is listed and enabled.

3. **Accessory name mismatch.** `homekit_accessory_name` in `config.toml`
   must match the name exactly as it appears in Apple Home (case-sensitive,
   spaces included). Use `--discover` (or `--verbose`) to list all home names
   and accessory names:
   ```bash
   LAMP_HK_RESULT=/tmp/r open -W "/path/to/LampHomeKitHelper.app" --args --discover --verbose
   cat /tmp/r
   ```
   Update `homekit_accessory_name` to match exactly.

4. **Mac logged out of Apple ID.** The helper uses the same Apple ID as the
   Home. Check System Settings → Apple ID — the account must be signed in.
   A signed-out or switched account causes all Home calls to fail.

**Key behaviour:** A failed HomeKit call does NOT ack the command. The command
remains in `commands.json` (or the Worker queue) and will be retried on the
next poll. Stale commands (> 10 min old) are acked without a HomeKit call and
will never be retried — this is correct.

---

### Stage 1 — Homebridge unreachable (connection refused)

**Symptom:** `lamp-agent --once` prints `applied=[] stale=[] failed=true`.

**Cause:** Homebridge is not running or is bound to a different port than `homebridge_url` in `config.toml`.

**Response:**
1. `brew services start homebridge` (or `launchctl kickstart -k "gui/$(id -u)/homebridged"` if installed via npm).
2. Confirm UI responds: `curl -s http://127.0.0.1:8581/api/auth/check` should return 401 (not connection refused).
3. Re-run `lamp-agent --once`. If still failing, check `~/.homebridge/homebridge.log` for startup errors.

**Key behaviour:** A failed Homebridge call does NOT ack the command. The command remains in `commands.json` and will be retried on the next poll. Stale commands (> 10 min old) are acked without a Homebridge call and will never be retried — this is correct.

### Stage 1 — Shortcuts backend (`lamp_backend = "shortcuts"`)

**Symptom:** `lamp-agent --once` prints `failed=true` and the lamp doesn't change.

**Cause:** `shortcuts run "<name>"` failed — the named preset doesn't exist, the
Mac isn't logged into the Home's Apple ID, or the GUI session is locked/logged out.

**Response:**
1. List shortcuts: `shortcuts list | grep Lamp` — confirm the grid exists
   (`Lamp Off`, `Lamp Warm 25` … `Lamp Cool 100`). Names must match `shortcut_prefix`.
2. Test one directly: `shortcuts run "Lamp Warm 50"` — the lamp should change.
3. Ensure the Mac is logged into the same Apple ID as the Home and stays awake
   (the LaunchAgent runs in the GUI session; a locked/logged-out session blocks Home access).

**Key behaviour:** a failed `shortcuts run` (non-zero exit) does NOT ack the
command, so it retries on the next poll. The agent snaps brightness to the
nearest of {25, 50, 100} and color to Warm/Neutral/Cool, so exact values are approximate.

## Common checks

- **Is the Worker alive?** `curl https://lamp-controller.<account>.workers.dev/health`
- **Is the Mac agent running?** `launchctl list | grep com.lamp.agent`
- **Is the self-hosted runner online?** Repo Settings → Actions → Runners.

## Log locations

| Component | Location |
|---|---|
| Worker | `wrangler tail` (live) or Cloudflare dashboard |
| Mac agent | `~/Library/Logs/lamp-agent.log` |
| Homebridge | `~/.homebridge/homebridge.log` |
