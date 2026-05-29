# Stage 1 — Mac → lamp Design

**Date:** 2026-05-29
**Status:** Approved (design)
**Owner:** @volovely
**Parent spec:** [`2026-05-24-lamp-controller-design.md`](2026-05-24-lamp-controller-design.md)

## Purpose

Stand up the `lamp-agent` daemon on the home Mac. It pulls commands from a local
`commands.json` queue and applies on/off, brightness, and color-temperature to a
Xiaomi Mijia desk lamp through a local Homebridge install. No cloud, no email.

This stage de-risks the four hardest unknowns before any networking exists:
Homebridge ↔ lamp control, the Swift CLI design, the launchd lifecycle, and the
self-hosted-runner deploy.

**Demoable:** with Homebridge running and the lamp bridged, appending a command
to `commands.json` turns the lamp on — warm, 30% — within one poll interval.

## Hardware reality (resolves a parent-spec open item)

The target lamp is a **Xiaomi Mijia desk lamp** (1S / Pro family). Two facts
established during design discovery shape this stage:

1. **It is a tunable-white lamp, not RGB.** It adjusts brightness and color
   temperature (~2500–4800 K warm↔cool); it has no hue/saturation. The parent
   spec's `color: { hex }` field does not map to this hardware and is replaced
   (see [Command schema change](#command-schema-change)).
2. **Homebridge stays in the architecture.** Mijia lamps expose a Xiaomi
   MIoT / Yeelight LAN interface, so a Homebridge plugin can bridge the lamp and
   the Mac talks to Homebridge's local REST API — exactly the parent-spec
   architecture. Even for the Desk Lamp Pro (which is also natively HomeKit), we
   bridge through a plugin so the headless launchd daemon has a local REST
   surface, avoiding the macOS HomeKit-entitlement / TCC / GUI-session problems
   that direct HomeKit control would impose on a daemon.

## Non-goals (this stage)

- No Worker, no network command source (Stage 2).
- No email or LLM (Stage 3).
- No attachment validation (Stage 4).
- No RGB color — the hardware does not support it.
- No multi-lamp / multi-accessory routing. One configured `accessory_id`.

## Architecture & data flow

```
commands.json (queue)
        │  read
        ▼
FileCommandSource ──► PollLoop ──► CommandExecutor ──► HomebridgeClient ──► Homebridge REST (:8581) ──► lamp
        ▲                │                                                              
        │ ack            ▼
   acked.json   (applied UUIDs, stale-guard)
```

Each poll cycle (`poll_interval_s`, default 12 s):

1. `CommandSource.pending()` returns the current command list.
2. Drop commands whose `id` is already in `acked.json`.
3. Drop **stale** commands (`created_at` older than 10 minutes) — mark them acked
   so they do not linger, but do not apply them.
4. Execute each remaining command via `CommandExecutor`.
5. On success, append the `id` to `acked.json` (ack).
6. Sleep `poll_interval_s`.

This is deliberately the same queue / ack / stale-guard shape that Stage 2's
Workers-KV queue and `POST /ack` will use. Building it against a local file now
means the idempotency logic is proven before a network source is introduced;
Stage 2 swaps the source implementation and changes nothing else.

## Components

All library code lives in `mac-agent/Sources/LampAgent/` (the testable core); the
executable target `lamp-agent` only wires things together.

| File | Responsibility |
|---|---|
| `Command.swift` | The command model, `Codable`, and invariant validation (e.g. `brightness`/`color_temp_k` only meaningful for `on`/`set`; ranges enforced). |
| `CommandSource.swift` | Protocol: `func pending() async throws -> [Command]` and `func ack(_ ids: [Command.ID]) async throws`. The seam Stage 2 swaps. |
| `FileCommandSource.swift` | `CommandSource` over `commands.json` (read) and `acked.json` (ack). |
| `HomebridgeClient.swift` | Protocol + live impl. `setPower(on:)`, `setBrightness(_:)`, `setColorTemperature(kelvin:)`. Live impl handles REST auth, `PUT /api/accessories/{uniqueId}`, and Kelvin→Mired conversion. |
| `CommandExecutor.swift` | Pure mapping from a `Command` to ordered `HomebridgeClient` calls. The most heavily unit-tested unit. |
| `AckStore.swift` | Persists applied UUIDs to `~/.local/state/lamp-agent/acked.json`; provides the stale-guard predicate. |
| `PollLoop.swift` | The long-running loop, driven by an injected `Clock` for testability. |
| `Config.swift` | Loads `~/.config/lamp-agent/config.toml`. |
| `Dependencies+Live.swift` | Registers `HomebridgeClient`, `Clock`, `UUIDGenerator` (Dependencies library). |

**Executable** (`Sources/lamp-agent/main.swift`): load config → build live
dependencies → run `PollLoop`. A `--once` flag performs a single poll pass (used
by the demo and manual testing); the default runs the daemon loop.

### Command → Homebridge mapping

| `action` | Behavior |
|---|---|
| `on` | Power on. If `brightness` present, set it. If `color_temp_k` present, set it. |
| `off` | Power off. Other fields ignored. |
| `set` | Set `brightness` and/or `color_temp_k` **without** changing power state. |

`CommandExecutor` issues the power change before brightness/temperature so that a
single `on` command that also carries brightness/temp lands in the expected
order.

## Command schema change

`shared/command-schema.json` is updated as a deliberate change to the
shared Worker↔Mac contract (locked now so Stage 3's Worker emits the right
shape):

- **Remove** the `color` object (RGB `hex`) — unsupported by the hardware.
- **Add** `color_temp_k`: integer, range **2700–6500** (a generous superset of
  the lamp's advertised range). The `HomebridgeClient` clamps the value to the
  accessory's actual advertised `ColorTemperature` min/max (read from Homebridge)
  before sending, so the contract stays hardware-independent.
- **Keep** `id`, `action` (`on`/`off`/`set`), `brightness` (0–100),
  `created_at`, `source_msg_id`.
- **Keep** `duration_minutes` as a reserved, ignored field (future scheduling).

Units: `color_temp_k` is Kelvin (human- and LLM-friendly); the Mired conversion
HomeKit requires happens inside `HomebridgeClient`, not in the contract.

## Homebridge integration

Resolved by the Homebridge-research task at the start of the implementation plan,
which produces `homebridge/README.md` (setup walkthrough) and a typed
`HomebridgeClient.swift` skeleton handed to the Mac implementation:

- Install **Homebridge** + **homebridge-config-ui-x** on the Mac. The UI ships the
  REST API on `127.0.0.1:8581`.
- Bridge the Mijia lamp via a Xiaomi plugin — most likely **`homebridge-miot`**
  (needs the lamp's MIoT device id + token) or a **Yeelight** plugin if LAN
  Control is available — so it appears as a Lightbulb accessory exposing **On**,
  **Brightness**, and **ColorTemperature** characteristics.
- **Auth:** obtain a Homebridge REST token and send it as a bearer header on each
  `PUT /api/accessories/{uniqueId}` with `{ characteristicType, value }`.
- The exact endpoints, auth handshake, the accessory `uniqueId`, and the
  token / LAN-Control extraction steps are the research deliverable.

## Error handling

| Failure | Behavior |
|---|---|
| Homebridge unreachable | `HomebridgeClient` throws → surfaced via `reportIssue`. Command is **not** acked → retried next cycle with backoff (2 → 5 → 15 → 30 s, capped). Stale-guard eventually drops it. |
| Malformed command JSON | `reportIssue`, skip the offending command, continue with the rest. |
| `acked.json` missing/corrupt | Treat as empty and recreate. |
| Stale command (> 10 min) | Drop without applying; mark acked so it does not relinger. |
| Single characteristic write fails mid-command | Surface via `reportIssue`, do not ack the command (idempotent retry; Homebridge `PUT` is idempotent). |

## Testing

swift-testing suites with Dependencies stubs (pfw-testing, pfw-dependencies,
pfw-issue-reporting, pfw-custom-dump):

- **`CommandExecutor`** against a stub `HomebridgeClient`: e.g. `on @ 30% @ 2700 K`
  → `setPower(true)`, `setBrightness(30)`, `setColorTemperature(2700)` in order;
  `off` ignores other fields; `set` does not touch power.
- **Kelvin→Mired** conversion and clamping to the advertised range.
- **`PollLoop`** with a stub `CommandSource` + stub `Clock` + stub executor:
  acked commands are not re-applied; stale commands dropped; an unreachable
  Homebridge leaves the command un-acked and retried.
- **`AckStore`** round-trip in a temp directory.
- **`Command`** decode + validation (out-of-range brightness, missing required
  fields, `color_temp_k` bounds).

## launchd & install

- `mac-agent/Resources/com.lamp.agent.plist` — `RunAtLoad`, `KeepAlive`, logs to
  `~/Library/Logs/lamp-agent.log`.
- `mac-agent/Resources/config.toml.example` — documented config template.
- `mac-agent/scripts/install.sh` — `swift build -c release` → install binary to
  `/usr/local/bin/lamp-agent`, copy the plist to `~/Library/LaunchAgents`, create
  the config dir (mode `0700`), `launchctl bootstrap`/load.
- `mac-agent/scripts/uninstall.sh` — `launchctl bootout`, remove plist + binary.

`config.toml` (mode `0600`) for this stage:

```toml
homebridge_url   = "http://127.0.0.1:8581"
homebridge_token = "..."
accessory_id     = "lamp-desk"
commands_path    = "~/.local/state/lamp-agent/commands.json"
poll_interval_s  = 12
```

`worker_url` / `shared_secret` are not needed until Stage 2.

## Deploy

`.github/workflows/deploy-mac-agent.yml`:

- Trigger: push to `main` touching `mac-agent/**`.
- `runs-on: [self-hosted, macOS, lamp-mac]`.
- Steps: `swift build -c release` → install binary → `launchctl kickstart -k`.

**Authored but dormant** until the self-hosted `lamp-mac` runner is registered —
the open manual item carried over from Stage 0. The workflow ships in this stage;
it first runs once the runner is online.

## Package.swift dependencies (added this stage)

- `swift-dependencies` (Point-Free Dependencies) — DI for `HomebridgeClient`,
  `Clock`, `UUIDGenerator`.
- `swift-issue-reporting` — `reportIssue` for unexpected states.
- A small TOML parser (**TOMLKit**) for `config.toml`.
- `swift-custom-dump` (test-only) — readable assertions/diffs.

## Human-in-the-loop setup (documented, not coded)

1. Install Homebridge + homebridge-config-ui-x on the Mac.
2. Add the Mijia lamp via the Xiaomi plugin (MIoT token / LAN-Control extraction,
   documented in `homebridge/README.md`).
3. Generate the Homebridge REST token and write it into `config.toml`.
4. Register the self-hosted `lamp-mac` runner (carryover from Stage 0) before
   testing a real deploy.

## Demoable exit test

With Homebridge running, the lamp bridged, and `lamp-agent` running:

```bash
echo '[{"id":"<uuid>","action":"on","brightness":30,"color_temp_k":2700,"created_at":"<now>","source_msg_id":"manual"}]' \
  > ~/.local/state/lamp-agent/commands.json
```

Within one poll interval the lamp turns on at 30% brightness, warm white. The
integration-verifier confirms with evidence.

## Open items (non-blocking)

- **Exact Mijia model / plugin / token path** — resolved by the Homebridge-research
  task at the start of the plan. Design is identical across the 1S / Pro variants.
- **Self-hosted runner registration** — manual, carried from Stage 0; gates only
  the live deploy, not local build/test/demo.
