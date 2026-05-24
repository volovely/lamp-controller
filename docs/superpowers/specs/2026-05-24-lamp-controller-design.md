# Lamp Controller — Design

**Date:** 2026-05-24
**Status:** Approved (architecture & staging)
**Owner:** @volovely

## Purpose

Control an Apple Home lamp via email. Send a Gmail with a recognized subject, an authenticating attachment, and a natural-language body (e.g. "turn on, warm white, 30%"); the lamp obeys within ~90 seconds.

The system has three independent units that communicate through narrow, well-defined interfaces, so each can be built, tested, and changed without touching the others.

## Non-goals (v1)

- Web UI, mobile app, or any user-facing surface beyond email.
- Multi-user routing or per-recipient policies.
- Encryption of the email body beyond TLS-in-transit and Gmail-at-rest.
- HMAC-signed payloads between Worker and Mac (bearer token is sufficient at this scope).
- A persistent command-history UI — the Gmail mailbox is the audit log.

## High-level architecture

```
┌──────────────┐  1. send email      ┌──────────────────┐
│  You (any    │ ──────────────────▶ │ Gmail mailbox    │
│  device)     │  Subject: "lamp"    │ (existing)       │
└──────────────┘  Body: NL command   └──────────────────┘
                  + auth attachment           │
                                              │ 2. IMAP search
                                              ▼
┌─────────────────────────────────────────────────────────┐
│ Cloudflare Worker — cron every 1 min                    │
│  a. IMAP-fetch unread mail (Subject prefix "lamp")      │
│  b. Validate attachment via 3rd-party API (gate)        │
│  c. Claude Haiku 4.5 → JSON {action, brightness?,       │
│     color?, duration_minutes?}                          │
│  d. Push command to Workers KV queue (one key per cmd)  │
│  e. Mark Gmail message as read; optional auto-reply     │
└─────────────────────────────────────────────────────────┘
                                              │
                          HTTPS GET /commands │ short-poll every 12 s
                          Bearer SHARED_SECRET│
                                              ▼
┌──────────────┐  6. HTTP localhost:8581 ┌──────────────────┐
│ Mac agent    │ ──────────────────────▶ │  Homebridge      │
│ (Swift CLI,  │   set on/brightness/    │  local REST API  │
│  launchd)    │   color                 │  → HomeKit lamp  │
└──────────────┘                          └──────────────────┘
       ▲                                          │
       │  7. POST /ack (command UUIDs)             │ ⇣ Apple Home
       └──────────────────────────────────────────▶│
                                                   ▼
                                              💡 (lamp)
```

### Key invariants

- **No inbound exposure of the Mac.** Mac initiates every connection.
- **Commands are idempotent.** Each carries a UUID; Mac tracks acked UUIDs locally and Homebridge `PUT`s are themselves idempotent.
- **Two trust boundaries:** Gmail→Worker (validated by attachment + From-allowlist) and Worker→Mac (bearer token).
- **Latency** ≈ cron interval (up to 60 s) + poll interval (up to 12 s) + LLM call (~1 s) + Homebridge call (~1 s). Worst-case ≈ 75 s; typical ≈ 40 s.

## Components

### worker/ — Cloudflare Worker (TypeScript)

**Purpose:** Ingest emails, validate, extract intent, queue commands. Serve queued commands to the Mac.

**Handlers (single Worker script):**

| Handler | Trigger | Responsibility |
|---|---|---|
| `scheduled` | Cron, every 1 min | IMAP-fetch unread Gmail with Subject prefix → validate attachment → Haiku JSON → write `command:<uuid>` to KV → mark Gmail message read |
| `fetch` | HTTPS from Mac | `GET /commands` returns pending; `POST /ack` deletes acked; `GET /health` |

**Secrets** (via `wrangler secret put`, never in git):

- `IMAP_USER`, `IMAP_APP_PASSWORD`
- `ANTHROPIC_API_KEY`
- `MAC_SHARED_SECRET`
- `VALIDATION_API_KEY`
- `ALLOWED_SENDERS` (comma-separated email allowlist; belt-and-braces)

**KV namespace** — one, two key shapes:

- `command:<uuid>` → `{ action, brightness?, color?, duration_minutes?, created_at, source_msg_id }`
- `seen:<gmail_msg_id>` → `1` (idempotency; never process the same message twice)

**Deploy:** `wrangler deploy`, triggered by `deploy-worker.yml` on push to `main` affecting `worker/**`. Runs on the self-hosted Mac runner.

### mac-agent/ — Swift CLI binary

**Purpose:** Long-running local daemon. Pull commands from the Worker, apply via Homebridge, ack.

**Module layout** (Swift Package; library + executable):

```
mac-agent/
  Package.swift
  Sources/
    LampAgent/                    # library — testable core
      WorkerClient.swift          # GET /commands, POST /ack
      HomebridgeClient.swift      # POST to local Homebridge REST
      CommandExecutor.swift       # maps Command → Homebridge calls
      PollLoop.swift              # the long-running loop
      Dependencies+Live.swift     # Dependencies registrations
      Command.swift               # shared model
    lamp-agent/                   # executable target — wires it up
      main.swift
  Tests/
    LampAgentTests/               # swift-testing + Dependencies overrides
  Resources/
    com.lamp.agent.plist          # launchd template
    config.toml.example
  scripts/
    install.sh
    uninstall.sh
```

**Library choices** (leveraging the `pfw-*` skill set):

- **Dependencies** library for `WorkerClient`, `HomebridgeClient`, `Clock`, `UUIDGenerator` — tests use stubs.
- **IssueReporting** for unexpected states (Homebridge unreachable, schema decode failures).
- **swift-testing** for `@Suite`/`@Test`-based unit tests.

**Runtime:** installed as a `launchd` LaunchAgent at `~/Library/LaunchAgents/com.lamp.agent.plist`, `KeepAlive=true` and `RunAtLoad=true`. Logs to `~/Library/Logs/lamp-agent.log` (rotated via `newsyslog`).

**Config** at `~/.config/lamp-agent/config.toml`, mode `0600`:

```toml
worker_url       = "https://lamp-controller.<username>.workers.dev"
shared_secret    = "..."         # mirrors MAC_SHARED_SECRET in Worker
homebridge_url   = "http://127.0.0.1:8581"
homebridge_token = "..."
accessory_id     = "lamp-living-room"
poll_interval_s  = 12
```

**Deploy:** `deploy-mac-agent.yml` on push to `main` affecting `mac-agent/**`. Runs on the self-hosted Mac runner. Steps: `swift build -c release` → install binary to `/usr/local/bin/lamp-agent` → `launchctl kickstart -k`.

### homebridge/ — Homebridge install (not code we own)

Off-the-shelf install on the Mac. We track an example `config.json.example` for reproducibility and document installation in `homebridge/README.md`. The Mac agent talks to its local REST API on `127.0.0.1:8581` with a bearer token:

- `PUT /api/accessories/{uniqueId}` with `{ characteristicType: "On", value: true|false }`
- Same endpoint with `Brightness`, `Hue`, `Saturation`.

## Interface contracts

### Worker → Mac

`GET /commands` (Mac → Worker)

```http
GET /commands HTTP/1.1
Authorization: Bearer <MAC_SHARED_SECRET>
```

Response 200:

```json
{
  "commands": [
    { "id": "uuid-1", "action": "on",  "brightness": 30 },
    { "id": "uuid-2", "action": "set", "color": { "hex": "#ffaa55" } }
  ]
}
```

The three actions:

- `on` — turn the lamp on; may also carry `brightness` and/or `color` to set in the same call.
- `off` — turn the lamp off; no other fields.
- `set` — adjust `brightness` and/or `color` without changing the on/off state.

`POST /ack` (Mac → Worker)

```http
POST /ack HTTP/1.1
Authorization: Bearer <MAC_SHARED_SECRET>
Content-Type: application/json

{ "ids": ["uuid-1", "uuid-2"] }
```

Response 204.

`GET /health` returns `200 OK` body `{"ok": true}`.

All other paths return 404. Mac validates the response URL host matches its configured `worker_url`.

### Command schema (`shared/command-schema.json`)

```jsonc
{
  "id":               "string (uuid)",          // required
  "action":           "on | off | set",         // required
  "brightness":       "number 0-100",           // optional
  "color":            { "hex": "#rrggbb" },     // optional (mutually compatible with brightness)
  "duration_minutes": "number 1-1440",          // optional (future use)
  "created_at":       "RFC3339 timestamp",      // required
  "source_msg_id":    "string (Gmail msg id)"   // required, for audit
}
```

Worker validates outgoing commands with Zod. Mac validates incoming commands with `Codable` + invariants (`brightness` only meaningful with `action ∈ {on,set}`).

## Security model

### Trust boundaries

1. **Anyone → Gmail.** The world can send mail. Defenses:
   - **Subject prefix filter** (`Subject: lamp …`). Noise filter, not security.
   - **Attachment validation.** Worker downloads attachment, calls 3rd-party API, rejects on invalid. Integration point is a single `validateAttachment(bytes) -> bool` so the 3rd-party API is swappable.
   - **From-address allowlist** (`ALLOWED_SENDERS`). Belt-and-braces; rejected mail is silently marked read.
2. **Worker → Mac.** 256-bit `MAC_SHARED_SECRET` shared between Worker (env) and Mac (config.toml). Sent as `Authorization: Bearer`. Worker only exposes `/commands`, `/ack`, `/health`.
3. **Mac → Homebridge.** Localhost-only (`127.0.0.1`), bearer-authenticated. Homebridge UI bound to loopback in our shipped config.

### Secrets handling

| Secret | Lives in | Provisioned by | In git? |
|---|---|---|---|
| `IMAP_APP_PASSWORD`, `ANTHROPIC_API_KEY`, `MAC_SHARED_SECRET`, `VALIDATION_API_KEY`, `ALLOWED_SENDERS` | Cloudflare (`wrangler secret put`) | One-time manual | No |
| `shared_secret`, `homebridge_token` | `~/.config/lamp-agent/config.toml` mode `0600` | One-time manual via `scripts/install.sh` | No |
| `CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ACCOUNT_ID` | GitHub repo secrets | One-time manual | No |

`.gitignore` covers `config.toml`, `.env*`, `*.local.*`, `secrets/`, `*.key`, `*.pem`. `config.toml.example` is committed.

### Replay / idempotency

- Worker stores `seen:<gmail_msg_id>` in KV the moment a message is accepted → same email cannot produce a second command.
- Each command gets a fresh UUIDv4 at creation.
- Mac persists last-acked UUID set at `~/.local/state/lamp-agent/acked.json` → crash-recovery is safe.
- Commands carry `created_at`; Mac drops commands older than **10 minutes** (stale-command guard — protects against acting on hours-old queued commands after extended outages).

## Failure handling

| Failure | Behavior |
|---|---|
| Gmail unreachable | Worker logs, scheduled tick is a no-op; retries next cron. No state damage. |
| Anthropic unreachable / 5xx | Don't mark message read; retry next cron. After 3 failed attempts for the same message, auto-reply "couldn't parse" + mark read. |
| LLM returns malformed JSON | Zod validates. On failure, retry once with stricter prompt; if still bad, auto-reply "couldn't parse" + mark read. |
| Attachment invalid / missing | Mark read, optionally auto-reply "unauthorized", drop. |
| KV write fails | Don't mark message read; retried next cron. |
| Mac offline | Commands accumulate in KV. Mac fetches whole pending list on next successful poll; stale-command guard drops anything > 10 min old. |
| Homebridge unreachable | Mac logs via `reportIssue`, does not ack, retries with backoff (2s → 5s → 15s → 30s, cap 30s). Stale-command guard eventually drops the command. |
| Mac crashes mid-command | Command not acked → refetched on restart → idempotent (Homebridge `PUT` is idempotent). |
| LLM hallucinates a fake action | Schema only allows `action ∈ {on, off, set}` and bounded brightness/color. Anything else fails validation. |

## Observability

- **Worker:** structured `console.log` lines (JSON), captured by Cloudflare; tail with `wrangler tail`. `LOG_LEVEL` env to control verbosity.
- **Mac:** structured JSON logs to `~/Library/Logs/lamp-agent.log`, rotated by `newsyslog`. Critical issues via `reportIssue`.
- **Liveness:** `/health` (Worker) and a status file (Mac) for future dashboard hooks.

## Repository layout

```
lamp-controller/
├── README.md
├── .gitignore
├── .editorconfig
│
├── worker/                          # Cloudflare Worker (TypeScript)
│   ├── package.json
│   ├── pnpm-lock.yaml
│   ├── tsconfig.json
│   ├── wrangler.toml
│   ├── src/
│   │   ├── index.ts                 # scheduled + fetch
│   │   ├── gmail.ts                 # IMAP fetch + mark-read
│   │   ├── validation.ts            # attachment → 3rd-party API
│   │   ├── llm.ts                   # Anthropic Haiku → schema'd JSON
│   │   ├── kv.ts
│   │   ├── auth.ts
│   │   └── schema.ts                # Zod
│   └── test/
│       └── *.spec.ts                # vitest + miniflare
│
├── mac-agent/                       # Swift Package
│   ├── Package.swift
│   ├── Sources/
│   │   ├── LampAgent/
│   │   └── lamp-agent/
│   ├── Tests/LampAgentTests/
│   ├── Resources/
│   │   ├── com.lamp.agent.plist
│   │   └── config.toml.example
│   └── scripts/{install.sh,uninstall.sh}
│
├── homebridge/
│   ├── config.json.example
│   └── README.md
│
├── shared/
│   └── command-schema.json
│
├── docs/
│   ├── superpowers/
│   │   ├── specs/2026-05-24-lamp-controller-design.md
│   │   └── plans/2026-05-24-lamp-controller-plan.md
│   ├── ops/{runbook.md, first-time-setup.md, secrets.md}
│   └── architecture.md
│
└── .github/
    └── workflows/{ci.yml, deploy-worker.yml, deploy-mac-agent.yml}
```

## Deployment

All deploys run on a **self-hosted Mac runner** labelled `[self-hosted, macOS, lamp-mac]`. CI (PR checks) runs on free GitHub-hosted runners.

| Workflow | Trigger | Runner |
|---|---|---|
| `ci.yml` | PR | github-hosted (Ubuntu + macos-latest as matrix where needed) |
| `deploy-worker.yml` | push to `main` touching `worker/**` | self-hosted Mac runner; `wrangler deploy` |
| `deploy-mac-agent.yml` | push to `main` touching `mac-agent/**` | self-hosted Mac runner; `swift build -c release` + `launchctl kickstart -k` |

Self-hosted runner is registered once manually following `docs/ops/first-time-setup.md`. It only runs workflows that explicitly target the `lamp-mac` label.

Worker secrets are provisioned once manually via `wrangler secret put`; the deploy workflow only ships code.

## Stages (incremental delivery)

Risk-first ordering. Each stage ends in a demoable state.

### Stage 0 — Foundations

- `git init`, push to GitHub.
- Monorepo skeleton: `worker/`, `mac-agent/`, `homebridge/`, `shared/`, `docs/`, `.github/`.
- `ci.yml` runs lint+test for both modules and goes green on empty stubs.
- Self-hosted Mac runner registered (manual, documented).
- Design doc + `docs/ops/first-time-setup.md` committed.
- **Demoable:** green CI; runner online; repo public/private as chosen.

### Stage 1 — Mac → lamp (no cloud, no email)

- Install Homebridge on the Mac, pair with the lamp.
- Swift CLI `lamp-agent` reads a local `commands.json` and applies on/off/brightness/color via Homebridge REST.
- launchd LaunchAgent installed by `scripts/install.sh`.
- swift-testing covers `CommandExecutor` with stubs.
- `deploy-mac-agent.yml` ships the binary.
- **Demoable:** appending a command to `commands.json` turns the lamp on. End-to-end Mac side proven.
- **De-risks:** Homebridge↔lamp, Swift CLI design, launchd, self-hosted runner deploy.

### Stage 2 — Worker queue (no email, no LLM)

- Wrangler project, KV namespace, bearer auth.
- `fetch`: `GET /commands`, `POST /ack`, `GET /health`.
- Mac agent swaps local file for Worker polling (12 s short-poll, stale-command guard).
- Manually insert commands with `wrangler kv put`.
- `deploy-worker.yml` runs on self-hosted Mac runner.
- **Demoable:** `wrangler kv put command:abc '{"action":"on"}'` → lamp turns on within ~15 s.
- **De-risks:** Worker↔Mac contract, KV mechanics, secrets distribution, ack flow.

### Stage 3 — Email + LLM (no attachment validation yet)

- `scheduled`: IMAP-fetch unread `Subject: lamp` mail.
- Anthropic Haiku 4.5 with strict Zod schema; retry once on parse failure.
- From-address allowlist (`ALLOWED_SENDERS`) as interim auth.
- Write Command to KV, mark Gmail read, auto-reply on parse failure.
- **Demoable:** email "lamp on at 30%" from allowlisted address → lamp obeys within ~90 s.
- **De-risks:** IMAP, LLM JSON reliability, multilingual input, retry semantics.

### Stage 4 — Attachment validation

- Plug in the 3rd-party validation API (spec pending from user).
- Replace From-allowlist with attachment check (allowlist remains as second factor).
- Auto-reply "unauthorized" on rejection.
- **Demoable:** mail without attachment is silently rejected; mail with attachment is obeyed.
- **De-risks:** 3rd-party API integration, end-to-end auth.

### Stage 5 — Hardening & ops

- Structured logs + rotation.
- Retry/backoff polish, stale-command tuning.
- `docs/ops/runbook.md`.
- Optional: success auto-reply.
- **Demoable:** pull the Mac's network cable, plug back in → queued commands drain cleanly; nothing wedges.

## Team of agents (build-time)

Specialist sub-agents per concern area. Each agent works in its own context, receives a self-contained brief (design path, stage goal, owned files, contract, exit test), and reports back. The orchestrator (main thread) reviews and dispatches the next batch.

| Agent | Owned scope | Key skills |
|---|---|---|
| **worker-engineer** | `worker/**` | `claude-api`, TypeScript/wrangler tooling |
| **mac-engineer** | `mac-agent/**` | `pfw-dependencies`, `pfw-observable-models`, `pfw-testing`, `pfw-issue-reporting`, `pfw-custom-dump`, `pfw-spm` |
| **homebridge-integrator** | One-off research for lamp's REST shape; outputs `homebridge/README.md` + typed `HomebridgeClient.swift` skeleton | `Explore` |
| **ops-engineer** | `.github/workflows/**`, runner setup docs, `wrangler.toml` deploy config, `docs/ops/**` | `update-config` |
| **integration-verifier** | End-of-stage demoable scenario verification with evidence | `verify`, `run` |
| **plan-author** | One invocation: turn this spec into the per-stage implementation plan | `superpowers:writing-plans` |
| **reviewer** | Periodic diff review at stage boundaries | `code-review`, `superpowers:receiving-code-review` |

**Dispatch rules:** parallel where independent, sequential where shared state. Briefs are self-contained. Every reported "done" is verified by reading the diff or running the integration-verifier.

**Human-in-the-loop tasks (not delegated):** Cloudflare account + API token, Homebridge install + lamp pairing, Gmail app password, 3rd-party validation API spec, `wrangler secret put` invocations, stage approvals.

## Open items (resolved later, not blocking)

- **3rd-party attachment validation API spec.** Needed at Stage 4; Stages 0–3 are fully functional behind the From-allowlist without it.
- **Lamp model & Homebridge plugin.** Resolved at Stage 1 by `homebridge-integrator`; design assumes a HomeKit-compatible bulb supporting on/brightness/hue/saturation.
- **GitHub repository visibility (public/private).** User decision at Stage 0; does not affect architecture.
- **Cloudflare account / Worker name.** User decision at Stage 2; resolves to a `*.workers.dev` URL hardcoded into the Mac config.
