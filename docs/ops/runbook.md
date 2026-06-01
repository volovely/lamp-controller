# Operational runbook

What to do when things break. Populated progressively across stages.

## Architecture note

The lamp is controlled by the **Lamp Controller desktop app** (`mac-app/`), which
runs on the home Mac, polls the Cloudflare Worker, and drives the lamp via
in-process Apple HomeKit. There is no launchd daemon for the lamp agent — the app runs as a **menu-bar
app** (💡 icon in the menu bar, no Dock icon) and **auto-starts polling** on
launch. It must be running; click the 💡 menu and confirm it shows **●
Running**. Use **Stop**/**Start** in that menu to control polling and **Quit**
to exit. The Activity window appears on launch and can be closed without
quitting (polling continues); reopen it from **Show Activity…**.

---

## Known incidents and responses

### Lamp Controller app — HomeKit call fails

**Symptom:** The app is running but the lamp does not change after a command is
issued.

**Causes and checks:**

1. **"Home Access" not granted.** If the app has never been allowed, macOS
   silently blocks Home calls. Check **System Settings → Privacy & Security →
   Home** — "Lamp Controller" should be listed and enabled. If not, quit the app,
   remove it from the list if present, relaunch, and click **Allow** when prompted.

2. **Accessory name mismatch.** `homekit_accessory_name` in `config.toml`
   must match the name exactly as it appears in Apple Home (case-sensitive,
   spaces included). Open the Home app to verify the exact name.

3. **Mac logged out of Apple ID.** The app uses the same Apple ID as the Home.
   Check **System Settings → Apple ID** — the account must be signed in.

**Key behaviour:** A failed HomeKit call does NOT ack the command. The command
remains in the Worker queue and will be retried on the next poll. Stale commands
(> 10 min old) are acked without a HomeKit call and will never be retried — this
is correct.

---

### Stage 1 — Homebridge unreachable (connection refused)

**Symptom:** `lamp-agent --once` (CLI smoke-test) prints `applied=[] stale=[] failed=true`.

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
   (`Lamp Off`, `Lamp Warm 50` … `Lamp Cool 100`). Names must match `shortcut_prefix`.
2. Test one directly: `shortcuts run "Lamp Warm 50"` — the lamp should change.
3. Ensure the Mac is logged into the same Apple ID as the Home and stays awake.

**Key behaviour:** a failed `shortcuts run` (non-zero exit) does NOT ack the
command, so it retries on the next poll. The agent snaps brightness to the
nearest of {25, 50, 100} and color to Warm/Neutral/Cool, so exact values are approximate.

## Common checks

- **Is the Worker alive?** `curl https://lamp-controller.<account>.workers.dev/health`
- **Is the Lamp Controller app running?** Look for the 💡 icon in the menu bar on the home Mac; its menu should show **● Running**. If the icon is absent, the app was quit — relaunch it (it auto-starts). If it shows **○ Stopped**, click **Start**.
- **Is the self-hosted runner online?** Repo Settings → Actions → Runners.

## Log locations

| Component | Location |
|---|---|
| Worker | `wrangler tail` (live) or Cloudflare dashboard |
| Mac agent (CLI) | `~/Library/Logs/lamp-agent.log` |
| Lamp Controller app | Console.app → filter by "LampController" |
| Homebridge | `~/.homebridge/homebridge.log` |
