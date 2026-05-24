# lamp-controller

Email-controlled Apple Home lamp.

Send a Gmail with subject `lamp ...`, an authenticating attachment, and a
natural-language body (`turn on, warm white, 30%`). A Cloudflare Worker reads
the mail, validates the sender, extracts the command via Claude Haiku, and
queues it. A Swift CLI daemon on the home Mac pulls commands and applies them
via Homebridge.

## Repo layout

| Path | Purpose |
|---|---|
| `worker/` | Cloudflare Worker (TypeScript) — cron + fetch handlers |
| `mac-agent/` | Swift CLI daemon running on the home Mac |
| `homebridge/` | Reference Homebridge config + setup notes |
| `shared/` | Cross-module contracts (JSON schemas) |
| `docs/` | Specs, plans, ops runbook |
| `.github/workflows/` | CI + deploy pipelines |

## Status

See [the design spec](docs/superpowers/specs/2026-05-24-lamp-controller-design.md)
and the [stage plans](docs/superpowers/plans/) for the staged build plan.

## Local development

Each module has its own README:
- [`worker/README.md`](worker/README.md) — Worker setup, tests, deploy
- [`mac-agent/README.md`](mac-agent/README.md) — Swift build, test, install

Operational setup (one-time, on the home Mac) lives in
[`docs/ops/first-time-setup.md`](docs/ops/first-time-setup.md).
