# Stage 3 — Email + LLM (Apps Script relay) — Design

**Date:** 2026-06-13
**Status:** Approved (design)
**Owner:** @volovely
**Supersedes:** the IMAP/cron ingestion path in `2026-05-24-lamp-controller-design.md` §"Stage 3".

## Purpose

Turn an email sent to the dedicated mailbox `v.lamp.controller@gmail.com` into a queued lamp `Command`. Send a Gmail with Subject prefix `lamp` and a natural-language English body ("turn on, warm, 30%"); the lamp obeys within ~90 seconds.

This stage is almost entirely ingestion + intent-extraction. Stages 0–2 already provide the KV command queue, the Mac agent, and the lamp backends (`GET /commands` / `POST /ack`, `shared/command-schema.json`). Stage 3 only adds how a `Command` *gets into* KV.

## Decisions (from brainstorming)

- **Ingestion = Apps Script relay → Worker** (not IMAP-from-Worker, not Gmail-API-from-Worker). A Google Apps Script bound to the lamp account polls unread mail and POSTs it to a new Worker route; the Worker does LLM + KV. Rationale: clean HTTPS-only Worker without OAuth-token/verification fragility or hand-rolled IMAP on Workers sockets. An owner-run Apps Script using `GmailApp` needs only a one-time unverified-app consent click — no GCP project, no refresh-token expiry.
- **The original `scheduled`/cron + IMAP path is dropped** for Stage 3. The relay's 1-minute time trigger replaces cron. The Worker gains exactly one route: `POST /ingest`.
- **The relay owns all Gmail mutations** (mark-read, reply). The Worker is pure decision logic and never speaks a mail protocol. Anthropic key + KV stay in Cloudflare; Gmail credentials stay at Google.
- **Mailbox is dedicated to lamp control.** Trigger filter is `is:unread subject:lamp`. Non-matching unread mail (e.g. Google account notices) is left untouched.
- **No sender allowlist in Stage 3** (user choice). Accepted residual risk — see Security.
- **English only** for commands and replies.
- **Replies on every handled message.** On `unparseable`, reply with guidance. On `queued`, reply with a **3-line processing log** (request → model result → executing) — a confirmation of what was understood and queued, sent without waiting for the lamp to physically change. (This supersedes the original "failure-only" decision, at the user's request.)
- **Model:** Claude Haiku 4.5.

## High-level architecture

```
┌──────────┐  email (Subject: lamp …)   ┌─────────────────────────┐
│  You     │ ─────────────────────────▶ │ v.lamp.controller@gmail │
└──────────┘  NL body: "on, warm 30%"   └─────────────────────────┘
                                                   │
                              every 1 min (time trigger)
                                                   ▼
                                    ┌──────────────────────────┐
                                    │ Apps Script relay (Code.gs)│
                                    │  search is:unread subj:lamp│
                                    │  POST /ingest {from,subj,  │
                                    │    body,msgId} + bearer    │
                                    │  ◀── verdict ──            │
                                    │  mark read; reply on fail  │
                                    └──────────────────────────┘
                                                   │ HTTPS POST /ingest
                                                   ▼
                                    ┌──────────────────────────┐
                                    │ Cloudflare Worker          │
                                    │  a. verify RELAY secret    │
                                    │  b. dedupe seen:<msgId> KV │
                                    │  c. Haiku → {action,bright,│
                                    │     color_temp_k} (Zod)    │
                                    │  d. write command:<uuid> KV│
                                    │  e. return verdict JSON    │
                                    └──────────────────────────┘
                                                   │  (existing Stage 2 path)
                              GET /commands / POST /ack ▼
                                          Mac agent → lamp 💡
```

**Latency budget:** ≤60s relay trigger + ≤12s Mac poll + ~1s LLM + ~1s apply ≈ 75s worst case, ~40s typical.

## Components

### gmail-relay/ — Google Apps Script (`Code.gs`, checked into repo)

~30 lines, bound to `v.lamp.controller@gmail.com`:

- **Trigger:** time-driven, every 1 minute.
- **Poll:** `GmailApp.search('is:unread subject:lamp', 0, 10)` — cap the batch at 10 threads per tick.
- **Per message** (latest message of each matching thread): `POST` to `WORKER_URL + '/ingest'` with `Authorization: Bearer <RELAY_SECRET>` and body `{ msgId, from, subject, body }`.
- **On 2xx:** act per `status` in the response (always mark read; if `reply` is non-null, `GmailMessage.reply(reply)`).
- **On 5xx / network error:** leave the message unread, log, continue — it retries next tick.
- **Config/secret:** read from Script Properties (`WORKER_URL`, `RELAY_SECRET`). Nothing sensitive is committed in the `.gs` file.
- **Deploy:** manual, documented in `docs/ops/first-time-setup.md` (new Stage 3 section): create the Apps Script project, paste `Code.gs`, set Script Properties, add the 1-minute trigger, click through the one-time "Google hasn't verified this app" consent (Advanced → proceed; persists for the owner).

### worker/ — new `POST /ingest` route + LLM module

**`POST /ingest` contract**

Request (relay → Worker):

```http
POST /ingest HTTP/1.1
Authorization: Bearer <RELAY_SHARED_SECRET>
Content-Type: application/json

{ "msgId": "<gmail-msg-id>", "from": "you@gmail.com",
  "subject": "lamp", "body": "turn on, warm, 30%" }
```

Response (200 for `queued`/`duplicate`/`unparseable`; 5xx for `error`; relay acts on `status`):

```jsonc
{
  "status": "queued",       // queued | unparseable | duplicate | error
  "command": { "action": "on", "brightness": 30, "color_temp_k": 2700 }, // present when queued
  "reply": null             // string for the relay to email back, or null
}
```

| `status` | When | KV effect | Relay action | HTTP |
|---|---|---|---|---|
| `queued` | Command extracted + validated | write `command:<uuid>` + `seen:<msgId>` | mark read + reply (processing log) | 200 |
| `duplicate` | `seen:<msgId>` already present | none | mark read | 200 |
| `unparseable` | LLM/Zod failed after one retry | write `seen:<msgId>` | mark read + reply | 200 |
| `error` | Anthropic 5xx / KV write failure | none | leave unread (retry next tick) | 5xx |

- **Auth fails closed:** empty/missing `RELAY_SHARED_SECRET`, or mismatched bearer → 401. Same posture as the existing `/commands` check.
- `unparseable` reply: `Got request — "<body>"` then `Couldn't understand that command. Try e.g. 'on, warm, 30%'.`
- `queued` reply (processing log, generated by the Worker from the request body + parsed command; no lamp wait):
  ```
  Got request — "<email body, whitespace-collapsed, ≤200 chars>"
  Got response from the model — <off | action[, brightness n][, color kK (word)]>
  Executing — <off: "turning the lamp off" | on/set: "turning the lamp on"[ at n%][, word (kK)]>
  ```
  Kelvin→word: ≤3000 warm, ≤4500 neutral, ≤5500 cool, else daylight. (`duplicate`/`error` stay `reply: null`.)
- **Write ordering on `queued`:** write `command:<uuid>` *first* — if it throws, return `error`/5xx (nothing committed; relay retries cleanly). Then write `seen:<msgId>` **best-effort**: if *that* throws, still return `queued`/200, because the command is already durably stored and re-running the request would write a second command. The relay's mark-read is the primary dedupe guard; the `seen:` write is the belt-and-braces backstop. On the `unparseable` path the `seen:` write is the only side effect, so if it throws, return `error`/5xx and let the relay retry (nothing is committed, and we avoid replying + marking-read against unrecorded state).

**LLM extraction (`worker/src/llm.ts`)**

- **Model:** Claude Haiku 4.5 (exact model id confirmed against the `claude-api` skill at build time).
- **Output contract:** forced tool-use / JSON validated by a Zod schema producing the command subset `{ action: "on" | "off" | "set", brightness?: int 0–100, color_temp_k?: int 2700–6500 }`. The Worker then adds `id` (UUIDv4), `created_at` (RFC3339), `source_msg_id` (= `msgId`) to form a full `Command` per `shared/command-schema.json`.
- **Color buckets** the prompt maps fuzzy words onto: warm ≈ 2700, neutral ≈ 4000, cool ≈ 5500, daylight ≈ 6500; values clamped to 2700–6500.
- **Action semantics:** `off` → `{action:"off"}` only. `on …` → `{action:"on", …}`. Adjustments to a presumed-on lamp ("dim to 20", "make it cooler") → `{action:"set", …}`. (`set` turns the lamp on and adjusts, per the schema description.)
- **Retry:** on parse/validate failure, retry once with a stricter "respond ONLY via the tool" instruction. Still invalid → `unparseable`.

## Idempotency

- `seen:<msgId>` is written to KV (TTL ~24h) when a message is accepted (`queued`) or rejected (`unparseable`), suppressing reprocessing on double-delivery.
- **Relay mark-read is the primary dedupe guard; KV `seen:` is belt-and-braces.** On the `queued` path the `seen:` write is best-effort (see Write ordering above): a failed `seen:` write does not fail the request, because the command is already committed and retrying would duplicate it. A duplicate command is harmless anyway — the same `LampState` applies idempotently downstream. On the `unparseable` path `seen:` is the only side effect, so a failed write returns 5xx and the relay retries.
- Each queued command gets a fresh UUIDv4. Downstream idempotency (Mac acked set, idempotent lamp apply, 10-min stale guard) is unchanged from Stage 2.

## Failure handling (additions to the base spec)

| Failure | Behavior |
|---|---|
| Anthropic unreachable / 5xx | Worker returns `error` + HTTP 5xx; relay leaves message unread; retried next tick. No KV write. |
| LLM malformed twice | `unparseable` + `seen:` write + reply + mark read. If the `seen:` write fails → `error` + 5xx (relay retries; nothing committed). |
| `command:` write fails (`queued`) | `error` + 5xx; no `seen:` write; relay leaves unread; retried next tick. |
| `seen:` write fails *after* a successful `command:` write (`queued`) | Still return `queued`/200 (command committed; relay mark-read dedupes). The failed `seen:` is logged, non-fatal. |
| Relay → Worker POST fails / network | Relay logs, leaves message unread, continues; retried next tick. |
| Duplicate delivery / double trigger | `seen:<msgId>` → `duplicate`; relay marks read; no second command. |
| Non-`lamp` unread mail | Not matched by the relay query; left untouched/unread. |

## Security model

- **New trust boundary — relay → Worker:** `RELAY_SHARED_SECRET` (256-bit), distinct from `MAC_SHARED_SECRET`, sent as `Authorization: Bearer`. Worker `/ingest` fails closed.
- **Accepted residual risk (Stage 3 only):** no sender allowlist and no attachment validation ⇒ any sender who knows the address *and* the Subject prefix can drive the lamp. Blast radius is a single desk lamp toggling. Mitigated only by address obscurity; optionally hardened at zero cost by setting the trigger Subject prefix to a non-obvious word known only to the user (change the relay query + send with that prefix). Closed properly in **Stage 4** (attachment validation), with the allowlist available as a second factor.
- **Secrets:** `ANTHROPIC_API_KEY` and `RELAY_SHARED_SECRET` via `wrangler secret put`. No `IMAP_*`, no OAuth tokens. Gmail credentials never leave Google (the relay runs as the account owner).

## Files

- **New:** `worker/src/llm.ts`, `worker/src/ingest.ts`, `gmail-relay/Code.gs`, `gmail-relay/README.md`.
- **Changed:** `worker/src/index.ts` (route `POST /ingest`), `worker/src/schema.ts` (LLM-output Zod schema), `worker/wrangler.toml` (remove any cron trigger; document `RELAY_SHARED_SECRET`), `docs/ops/first-time-setup.md` (Stage 3 section), `docs/ops/secrets.md` (new secret).

## Tests

**Worker (vitest):**
- `/ingest` auth fails closed (missing/empty/mismatched secret → 401).
- `queued`: valid email → KV holds a schema-valid `command:<uuid>` and `seen:<msgId>`; response carries the command.
- `duplicate`: pre-seeded `seen:<msgId>` → `duplicate`, no new command.
- `unparseable`: LLM fails twice (stubbed) → `unparseable` + reply text + `seen:` written.
- `error`: Anthropic 5xx / KV failure (stubbed) → `error` + HTTP 5xx, no `seen:` write.
- LLM module over fixtures with a stubbed Anthropic client: "on warm 30%" → `{on,30,2700}`; "off" → `{off}`; "dim to 20" → `{set,20}`; "make it cooler" → `{set, color_temp_k≥5500}`; garbage → `unparseable`.

**Relay:** documented + manually verified (not in CI).

## Demoable

Email "lamp on at 30%, warm" from any address to `v.lamp.controller@gmail.com` → within ~90s the lamp turns on at 30% warm. A nonsense body → an auto-reply "Couldn't understand that command…" and the message marked read.

## Out of scope (later stages)

- Attachment validation + sender allowlist as real auth (Stage 4).
- Applied-state confirmation (replying only *after* the Mac app physically changes the bulb — needs a Mac→Worker report + async send), retry/backoff tuning (Stage 5). (Basic success-confirmation replies landed in this stage — see Decisions.)
- `duration_minutes` scheduling (reserved in schema; ignored in v1).
