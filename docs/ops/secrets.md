# Secrets registry

A canonical list of every secret in the system, where it lives, who provisions
it, and how to rotate.

### Active (Stage 3)

| Secret | Where | Provisioned by | Used by | Rotation |
|---|---|---|---|---|
| `ANTHROPIC_API_KEY` | `wrangler secret` (Cloudflare) | user, via console.anthropic.com | Worker `llm.ts` (Claude Haiku 4.5 intent extraction) | rotate yearly |
| `RELAY_SHARED_SECRET` | `wrangler secret` (Cloudflare) + Apps Script `RELAY_SECRET` property | user generates with `openssl rand -hex 32`; sets identical value in both places | Worker `auth.ts` (`POST /ingest` bearer check), Apps Script relay | rotate together |
| `MAC_SHARED_SECRET` | `wrangler secret` + `~/.config/lamp-agent/config.toml` on Mac | user generates with `openssl rand -hex 32`; sets identical value in both places | Worker `auth.ts`, Mac `WorkerClient.swift` | rotate together |
| `homebridge_token` | `~/.config/lamp-agent/config.toml` on Mac | Homebridge UI generates | Mac `HomebridgeClient.swift` | regenerate via Homebridge UI |
| `CLOUDFLARE_API_TOKEN` | GitHub repo secret | user, scoped token from Cloudflare dashboard | `deploy-worker.yml` | rotate yearly |
| `CLOUDFLARE_ACCOUNT_ID` | GitHub repo secret | user | `deploy-worker.yml` | n/a (not secret in practice) |

### Stage 4 — not yet implemented (do not provision)

| Secret | Where | Provisioned by | Used by | Rotation |
|---|---|---|---|---|
| `VALIDATION_API_KEY` | `wrangler secret` | user, from 3rd-party validator | Worker attachment validation | per provider policy |
| `ALLOWED_SENDERS` | `wrangler secret` (comma-separated) | user | Worker sender allowlist | as needed |

## Provisioning commands (reference)

```bash
# Worker secrets — run from worker/ directory

# Stage 3 (active)
wrangler secret put ANTHROPIC_API_KEY
wrangler secret put RELAY_SHARED_SECRET
wrangler secret put MAC_SHARED_SECRET

# Stage 4 — not yet implemented; do not provision yet
# wrangler secret put VALIDATION_API_KEY
# wrangler secret put ALLOWED_SENDERS

# GitHub repo secrets
gh secret set CLOUDFLARE_API_TOKEN
gh secret set CLOUDFLARE_ACCOUNT_ID
```

## Never commit

- `*.local`, `config.toml` (committed: `config.toml.example` only)
- `.env*`
- `secrets/`
- Anything with the suffix `.key` or `.pem`
