# Operational runbook

What to do when things break. Populated progressively across stages.

## Known incidents and responses

_None yet — populated during Stage 5._

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
