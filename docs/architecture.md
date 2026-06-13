# Architecture overview

This is a one-page summary. The authoritative document is the design spec at
[`docs/superpowers/specs/2026-05-24-lamp-controller-design.md`](superpowers/specs/2026-05-24-lamp-controller-design.md).

## Data flow

```
email → Gmail → Apps Script relay (gmail-relay/) → Cloudflare Worker (POST /ingest)
                                                              ↓
                                                        Workers KV → Mac daemon (poll)
                                                                            ↓
                                                                  Homebridge → lamp
```

## Components

- **Gmail relay** (`gmail-relay/`) — Google Apps Script bound to the lamp
  Gmail account. A 1-minute time trigger polls `is:unread subject:lamp`,
  POSTs each message to the Worker `POST /ingest`, then marks messages read
  (or replies on failure) per the verdict. All Gmail mutations live here; the
  Worker never speaks a mail protocol.
- **Worker** (`worker/`) — Cloudflare Worker. `POST /ingest` verifies the
  relay bearer token, dedupes via `seen:<msgId>` KV, calls Claude Haiku 4.5
  for intent extraction, and writes `command:<uuid>` to KV. `GET /commands`
  and `POST /ack` serve the Mac agent (unchanged from Stage 2).
- **Mac agent** (`mac-agent/`) — Swift CLI daemon. Short-polls the Worker
  every 12 s, executes commands via Homebridge's local REST API, acks back.
- **Homebridge** — off-the-shelf install on the Mac, the bridge to HomeKit.

## Trust boundaries

1. Anyone → relay → Worker: bearer-authenticated with `RELAY_SHARED_SECRET`
   (256-bit, distinct from `MAC_SHARED_SECRET`). No sender allowlist in Stage 3
   (accepted residual risk — closed in Stage 4 with attachment validation and
   an optional `ALLOWED_SENDERS` check).
2. Worker → Mac: bearer token shared via `wrangler secret` and `config.toml`.
3. Mac → Homebridge: localhost-only, bearer-authenticated.

## Build & deploy

CI runs on github-hosted runners. Deploys (`worker/` and `mac-agent/`) run
on a self-hosted Mac runner. See
[`docs/ops/first-time-setup.md`](ops/first-time-setup.md).
