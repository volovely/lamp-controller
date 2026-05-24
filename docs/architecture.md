# Architecture overview

This is a one-page summary. The authoritative document is the design spec at
[`docs/superpowers/specs/2026-05-24-lamp-controller-design.md`](superpowers/specs/2026-05-24-lamp-controller-design.md).

## Data flow

```
email → Gmail → Cloudflare Worker (cron) → Workers KV → Mac daemon (poll)
                                                              ↓
                                                    Homebridge → lamp
```

## Components

- **Worker** (`worker/`) — Cloudflare Worker. `scheduled` handler reads Gmail
  every minute, validates, calls Claude Haiku for intent, writes commands to
  KV. `fetch` handler serves pending commands to the Mac.
- **Mac agent** (`mac-agent/`) — Swift CLI daemon. Short-polls the Worker
  every 12 s, executes commands via Homebridge's local REST API, acks back.
- **Homebridge** — off-the-shelf install on the Mac, the bridge to HomeKit.

## Trust boundaries

1. Anyone → Gmail: validated by attachment check + From-allowlist in the Worker.
2. Worker → Mac: bearer token shared via `wrangler secret` and `config.toml`.
3. Mac → Homebridge: localhost-only, bearer-authenticated.

## Build & deploy

CI runs on github-hosted runners. Deploys (`worker/` and `mac-agent/`) run
on a self-hosted Mac runner. See
[`docs/ops/first-time-setup.md`](ops/first-time-setup.md).
