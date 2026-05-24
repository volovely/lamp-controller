# worker

Cloudflare Worker. Exports a `fetch` handler (serves pending commands to the
Mac) and a `scheduled` handler (reads Gmail, queues commands).

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

## Layout

| File | Purpose |
|---|---|
| `src/index.ts` | Worker entrypoint: `fetch` + `scheduled` |
| `wrangler.toml` | Worker config: name, cron, bindings |
| `test/*.spec.ts` | Vitest unit tests |
