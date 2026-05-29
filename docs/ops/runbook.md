# Operational runbook

What to do when things break. Populated progressively across stages.

## Known incidents and responses

### Stage 1 — Homebridge unreachable (connection refused)

**Symptom:** `lamp-agent --once` prints `applied=[] stale=[] failed=true`.

**Cause:** Homebridge is not running or is bound to a different port than `homebridge_url` in `config.toml`.

**Response:**
1. `brew services start homebridge` (or `launchctl kickstart -k "gui/$(id -u)/homebridged"` if installed via npm).
2. Confirm UI responds: `curl -s http://127.0.0.1:8581/api/auth/check` should return 401 (not connection refused).
3. Re-run `lamp-agent --once`. If still failing, check `~/.homebridge/homebridge.log` for startup errors.

**Key behaviour:** A failed Homebridge call does NOT ack the command. The command remains in `commands.json` and will be retried on the next poll. Stale commands (> 10 min old) are acked without a Homebridge call and will never be retried — this is correct.

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
