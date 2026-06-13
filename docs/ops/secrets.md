# Secrets registry

A canonical list of every secret in the system, where it lives, who provisions
it, and how to rotate.

| Secret | Where | Provisioned by | Used by | Rotation |
|---|---|---|---|---|
| `IMAP_USER` | `wrangler secret` (Cloudflare) | user, one-time | Worker `gmail.ts` | rare |
| `IMAP_APP_PASSWORD` | `wrangler secret` | user, via Google App Passwords UI | Worker `gmail.ts` | revoke + regenerate when needed |
| `ANTHROPIC_API_KEY` | `wrangler secret` (Cloudflare) | user, via console.anthropic.com | Worker `llm.ts` (Claude Haiku 4.5 intent extraction) | rotate yearly |
| `RELAY_SHARED_SECRET` | `wrangler secret` (Cloudflare) + Apps Script `RELAY_SECRET` property | user generates with `openssl rand -hex 32`; sets identical value in both places | Worker `auth.ts` (`POST /ingest` bearer check), Apps Script relay | rotate together |
| `VALIDATION_API_KEY` | `wrangler secret` | user, from 3rd-party validator | Worker `validation.ts` | per provider policy |
| `MAC_SHARED_SECRET` | `wrangler secret` + `~/.config/lamp-agent/config.toml` on Mac | user generates with `openssl rand -hex 32`; sets identical value in both places | Worker `auth.ts`, Mac `WorkerClient.swift` | rotate together |
| `ALLOWED_SENDERS` | `wrangler secret` (comma-separated) | user | Worker `gmail.ts` | as needed |
| `homebridge_token` | `~/.config/lamp-agent/config.toml` on Mac | Homebridge UI generates | Mac `HomebridgeClient.swift` | regenerate via Homebridge UI |
| `CLOUDFLARE_API_TOKEN` | GitHub repo secret | user, scoped token from Cloudflare dashboard | `deploy-worker.yml` | rotate yearly |
| `CLOUDFLARE_ACCOUNT_ID` | GitHub repo secret | user | `deploy-worker.yml` | n/a (not secret in practice) |

## Provisioning commands (reference)

```bash
# Worker secrets — run from worker/ directory
wrangler secret put IMAP_USER
wrangler secret put IMAP_APP_PASSWORD
wrangler secret put ANTHROPIC_API_KEY
wrangler secret put RELAY_SHARED_SECRET
wrangler secret put MAC_SHARED_SECRET
wrangler secret put VALIDATION_API_KEY
wrangler secret put ALLOWED_SENDERS

# GitHub repo secrets
gh secret set CLOUDFLARE_API_TOKEN
gh secret set CLOUDFLARE_ACCOUNT_ID
```

## Never commit

- `*.local`, `config.toml` (committed: `config.toml.example` only)
- `.env*`
- `secrets/`
- Anything with the suffix `.key` or `.pem`
