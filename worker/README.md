# worker

Cloudflare Worker. Exports a `fetch` handler that serves four routes:
ingests lamp commands from the Gmail relay, and serves the Mac agent's command
queue.

## Setup

```bash
pnpm install
```

## Test

```bash
pnpm test           # vitest
pnpm typecheck      # tsc --noEmit
pnpm deploy:dry     # wrangler deploy --dry-run
```

## Deploy

Done via GitHub Actions on push to `main` (see `.github/workflows/deploy-worker.yml`,
added in Stage 2). Local manual deploy:

```bash
pnpm deploy
```

Requires `CLOUDFLARE_API_TOKEN` and `CLOUDFLARE_ACCOUNT_ID` env vars.

## Routes

| Method | Path | Description |
|---|---|---|
| `POST` | `/ingest` | Receive a mail message from the Apps Script relay; call Claude Haiku 4.5 to extract a command; write to KV |
| `GET` | `/commands` | Mac agent polls for the next pending command |
| `POST` | `/ack` | Mac agent acknowledges a processed command |
| `GET` | `/health` | Liveness check |

## Ingestion architecture

Email → `v.lamp.controller@gmail.com` → Google Apps Script relay (`gmail-relay/`) →
`POST /ingest` → Claude Haiku 4.5 → Workers KV → Mac agent (`GET /commands`).

The relay runs every 1 minute via a time trigger, finds unread `subject:lamp`
messages, and POSTs each one to `/ingest`. The Worker does auth verification,
deduplication (`seen:<msgId>` KV key), LLM extraction, and queues the result.
There is no cron trigger on the Worker side.

## Secrets

Set via `wrangler secret put`:

| Secret | Used by |
|---|---|
| `ANTHROPIC_API_KEY` | `POST /ingest` — Claude Haiku 4.5 call |
| `RELAY_SHARED_SECRET` | `POST /ingest` — bearer the Apps Script relay sends |
| `MAC_SHARED_SECRET` | `GET /commands`, `POST /ack` — bearer the Mac agent sends |

## Layout

| File | Purpose |
|---|---|
| `src/index.ts` | Worker entrypoint: `fetch` (routes) |
| `src/ingest.ts` | `/ingest` handler: auth, dedup, LLM, KV write |
| `src/llm.ts` | Anthropic extraction: Haiku 4.5 → validated command |
| `src/schema.ts` | Zod schemas for env, KV, LLM output, and ingest payload |
| `src/auth.ts` | Shared bearer-token verification helper |
| `src/http.ts` | Shared JSON response helper |
| `src/kv.ts` | KV read/write helpers |
| `wrangler.toml` | Worker config: name, bindings (no cron) |
| `test/*.spec.ts` | Vitest unit tests |
