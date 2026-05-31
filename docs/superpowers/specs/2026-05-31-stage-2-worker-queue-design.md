# Stage 2 — Worker queue Design

**Date:** 2026-05-31
**Status:** Approved (design)
**Owner:** @volovely
**Parent spec:** [`2026-05-24-lamp-controller-design.md`](2026-05-24-lamp-controller-design.md)
**Builds on:** Stage 1 ([`2026-05-29-stage-1-mac-to-lamp-design.md`](2026-05-29-stage-1-mac-to-lamp-design.md))

## Purpose

Move the command queue off the Mac's local file and into the cloud: a Cloudflare
Worker backed by Workers KV serves pending commands to the Mac over HTTPS with
bearer auth, and deletes them on ack. No email, no LLM yet (Stage 3). Commands
are inserted manually with `wrangler kv put` for the demo.

This stage de-risks the Worker↔Mac contract, KV mechanics, bearer-secret
distribution, and the real ack/delete flow — before any email producer exists.

**Demoable:** `wrangler kv key put --binding=COMMANDS command:<uuid> '{…}'` →
the Mac polls within ~15 s, the lamp obeys, and the KV key is deleted (acked).

## Non-goals (this stage)

- No email/IMAP, no LLM (Stage 3).
- No attachment validation (Stage 4).
- No `POST /commands` enqueue endpoint — commands enter KV via `wrangler kv put`
  (or, from Stage 3, the Worker's own `scheduled` handler).
- No Durable Objects / Cloudflare Queues — a plain KV namespace is sufficient
  for one lamp with one pull-consumer.
- No change to the lamp-control backends (HomeKit helper stays the default).

## Architecture & data flow

```
wrangler kv put command:<uuid> '{…}'      (Stage 2 demo input; Stage 3: scheduled handler writes these)
        │
        ▼
Cloudflare Worker  (KV namespace: COMMANDS)
   fetch handler:
     GET  /commands  → list keys prefix "command:", return {commands:[…]}   [Bearer]
     POST /ack       → delete the given command:<id> keys                    [Bearer]
     GET  /health    → {ok:true}                                            [open]
        ▲   │
        │   │ HTTPS, Authorization: Bearer <MAC_SHARED_SECRET>
        │   ▼
mac-agent  WorkerCommandSource  (new CommandSource backend)
     pending() → GET /commands → [Command]
     ack(ids)  → POST /ack {ids}
        │
        ▼  (unchanged Stage 1 pipeline)
   PollLoop → CommandExecutor → LampClient(.homekit) → lamp
```

The Mac side plugs into the existing `CommandSource { pending, ack }` seam built
in Stage 1. `PollLoop`'s dedup (`AckStore`), stale-guard (>10 min), and backoff
(2→5→15→30 s) are unchanged. The one behavioural difference from the file source:
`ack` now **deletes** the command from KV (the file source's `ack` was a no-op,
relying on `acked.json`), exercising the real Worker↔Mac ack flow.

## Worker components (`worker/`)

| File | Responsibility |
|---|---|
| `src/index.ts` | Router: dispatch `GET /commands`, `POST /ack`, `GET /health`; else 404. Keeps the `scheduled` no-op stub for Stage 3. |
| `src/auth.ts` | `requireBearer(request, env)` — constant-time compare of the `Authorization: Bearer` token against `env.MAC_SHARED_SECRET`; returns a 401 `Response` on missing/mismatch, `null` on success. |
| `src/kv.ts` | `listCommands(env)` (list prefix `command:`, `get` each value, JSON-parse, skip+log malformed) and `deleteCommands(env, ids)` (delete `command:<id>` for each id). |
| `src/schema.ts` | Zod `Command` schema mirroring `shared/command-schema.json` (incl. `color_temp_k`). `/commands` validates each KV value and drops non-conforming entries (defense against a bad manual `kv put`). |
| `wrangler.toml` | Add the `COMMANDS` KV namespace binding. Keep `compatibility_date`, `nodejs_compat`, and the cron trigger stub (used in Stage 3). |
| `test/*.spec.ts` | vitest: auth 401s, `/commands` returns+validates, `/ack` deletes, `/health` ok, unknown path 404, malformed `/ack` body 400. |

### Worker → Mac contract

`GET /commands` (Mac → Worker), `Authorization: Bearer <MAC_SHARED_SECRET>` →
`200`:

```json
{
  "commands": [
    { "id": "uuid-1", "action": "on",  "brightness": 30, "color_temp_k": 2700,
      "created_at": "2026-05-31T10:00:00Z", "source_msg_id": "manual" }
  ]
}
```

Each element conforms to `shared/command-schema.json`. (Note: this supersedes the
parent spec's `GET /commands` example, which still showed the pre-Stage-1
`color: {hex}` field — the contract is now `color_temp_k`.)

`POST /ack` (Mac → Worker), bearer + `{"ids":["uuid-1"]}` → `204` (keys deleted).
Malformed body → `400`.

`GET /health` → `200 {"ok":true}` (no auth). All other paths → `404`.

### KV namespace `COMMANDS`

- `command:<uuid>` → the Command JSON. Listed and served by `/commands`,
  deleted by `/ack`. Written by `wrangler kv put` (Stage 2) or the `scheduled`
  handler (Stage 3).
- (`seen:<gmail_msg_id>` from the parent spec is a Stage 3 concern; not used here.)

KV caveats, both acceptable at this scale: list-after-write is eventually
consistent (a freshly `put` command may take a few seconds to appear — within the
demo's ~15 s budget), and `list()` returns ≤1000 keys/page (the queue is near-empty).

## Mac agent components (`mac-agent/`)

| File | Responsibility |
|---|---|
| `Sources/LampAgent/WorkerCommandSource.swift` | `CommandSource.worker(baseURL:sharedSecret:session:)`. `pending()` → `GET {baseURL}/commands` (bearer) → decode `{commands:[Command]}` via `Command.jsonDecoder` (lossy per-element, like the file source). `ack(ids)` → `POST {baseURL}/ack {ids}` (bearer) → expect 204. Verifies the response URL host matches the configured `worker_url` host (parent-spec invariant); mismatch throws. |
| `Sources/LampAgent/Config.swift` | Add `enum CommandSourceKind { case worker, file }`, `commandSource` (default `.worker`), `workerURL: URL?`, `sharedSecret: String?`. Validation: `.worker` requires `worker_url` + `shared_secret`; `.file` requires `commands_path`. |
| `Sources/lamp-agent/main.swift` | Build the `CommandSource` by `config.commandSource` (switch mirroring the lamp-backend switch): `.worker` → `.worker(...)`, `.file` → `.file(at:)`. |
| `Tests/LampAgentTests/WorkerCommandSourceTests.swift` | `URLProtocol` stub (same pattern as `LampClientHomebridgeTests`): `pending` decodes the array + sends bearer; `ack` posts `{ids}` + bearer and treats 204 as success; non-2xx throws; host-mismatch rejected. |
| `Tests/LampAgentTests/ConfigTests.swift` | Extend: `.worker` default; worker requires url+secret (else throws); `.file` still parses. |

Errors (transport failure, non-2xx, host mismatch) throw out of `pending`/`ack`;
`PollLoop` already treats a failed cycle as un-acked + retry-with-backoff, and the
stale-guard still drops commands older than 10 minutes.

## Config additions (`config.toml`)

```toml
command_source  = "worker"          # "worker" (default) | "file"
worker_url      = "https://lamp-controller.<subdomain>.workers.dev"
shared_secret   = "<= MAC_SHARED_SECRET, openssl rand -hex 32>"

# file source (Stage 1, still available for offline testing):
# command_source = "file"
# commands_path  = "~/.local/state/lamp-agent/commands.json"

poll_interval_s = 12                 # existing
# lamp_backend / homekit_* / shortcut_* / homebridge_* — unchanged from Stage 1
```

## Secrets

`MAC_SHARED_SECRET` is the Worker↔Mac bearer token — the secret distribution this
stage de-risks:

1. Generate once: `openssl rand -hex 32`.
2. Worker side: `cd worker && wrangler secret put MAC_SHARED_SECRET` (paste value).
3. Mac side: put the **identical** value in `~/.config/lamp-agent/config.toml`
   as `shared_secret` (mode 0600).

Already listed in `docs/ops/secrets.md`; first-time-setup gets a Stage 2 section.
Rotation = regenerate and update both places together.

## Error handling

| Failure | Behavior |
|---|---|
| Bad/missing bearer (Worker) | `401`, no body leak. |
| Unknown path (Worker) | `404`. |
| Malformed `/ack` body (Worker) | `400`. |
| Malformed KV value (Worker) | Skipped + `console.log`; never 500s the request. |
| Worker unreachable / non-2xx (Mac) | `pending`/`ack` throw → `PollLoop` leaves commands un-acked → retried with backoff. |
| Response host ≠ `worker_url` host (Mac) | Throw; do not process (anti-redirect/spoof guard). |
| Stale command (>10 min) | Dropped by the existing stale-guard; acked so it doesn't relinger. |

## Testing

- **Worker (vitest + miniflare / workers test pool):** auth 401 on `/commands` and
  `/ack` without/with-wrong token; `/commands` returns valid commands and drops a
  malformed KV entry; `/ack` deletes the named keys (assert via a follow-up list);
  `/health` → `{ok:true}`; unknown path → 404; malformed `/ack` body → 400.
- **Mac (swift-testing + URLProtocol stub):** `WorkerCommandSource.pending` decodes
  `{commands:[…]}` and sets the bearer header; `ack` posts `{ids}` with bearer and
  accepts 204; non-2xx → throws; host mismatch → throws. `Config` worker/file
  parsing + validation.
- Both run in existing CI (`worker-ci`, `mac-agent-ci`).

## Deploy

`.github/workflows/deploy-worker.yml`:

- Trigger: push to `main` touching `worker/**` or the workflow file.
- `runs-on: [self-hosted, macOS, lamp-mac]` (per parent spec / user choice).
- Steps: `pnpm install --frozen-lockfile` → `pnpm test` → `wrangler deploy`
  (auth via `CLOUDFLARE_API_TOKEN` + `CLOUDFLARE_ACCOUNT_ID` repo secrets).

**Authored but dormant** until the self-hosted `lamp-mac` runner is registered
(same standing gate as `deploy-mac-agent.yml`). Worker secrets and the KV
namespace are provisioned manually, once.

## Human-in-the-loop setup (documented, not coded)

1. Create the KV namespace: `wrangler kv namespace create COMMANDS` → put the id
   in `wrangler.toml`.
2. `wrangler secret put MAC_SHARED_SECRET` (same value as the Mac config).
3. Provision `CLOUDFLARE_API_TOKEN` + `CLOUDFLARE_ACCOUNT_ID` as GitHub repo
   secrets (for the dormant deploy workflow).
4. First deploy (manual until the runner exists): `cd worker && wrangler deploy`.
5. Register the self-hosted `lamp-mac` runner to activate auto-deploys.

## Demoable exit test

```bash
# Insert a command (cloud queue)
wrangler kv key put --binding=COMMANDS "command:$(uuidgen)" \
  "{\"id\":\"$(uuidgen)\",\"action\":\"on\",\"brightness\":30,\"color_temp_k\":2700,\"created_at\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"source_msg_id\":\"manual\"}"
```

With the Mac agent running (`command_source = "worker"`), within one poll interval
(~12 s) the lamp turns on warm at 30%, and the KV key is deleted (acked). The
integration-verifier confirms with evidence.

## Open items (non-blocking)

- **Worker name / `*.workers.dev` URL** — chosen at deploy time; hardcoded into the
  Mac's `worker_url`.
- **Self-hosted runner registration** — manual, carried from Stage 0/1; gates only
  auto-deploy, not local build/test or a manual `wrangler deploy`.
