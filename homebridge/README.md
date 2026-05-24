# Homebridge integration

Homebridge installation and configuration is done as a one-time manual step
on the home Mac. The Mac agent (`mac-agent/`) talks to Homebridge's local
REST API to control the lamp.

This README is a stub. The full setup steps — install, lamp pairing, plugin
selection, REST API token generation — are filled in during Stage 1 by the
`homebridge-integrator` sub-agent. See the design spec
([`../docs/superpowers/specs/2026-05-24-lamp-controller-design.md`](../docs/superpowers/specs/2026-05-24-lamp-controller-design.md))
for the contract the Mac agent uses.

## Files in this directory (post-Stage 1)

| File | Purpose |
|---|---|
| `config.json.example` | Reference Homebridge config (sanitized) |
| `README.md` | This file — setup walkthrough |
