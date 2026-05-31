# mac-agent

Swift CLI that provides a `--once` smoke-test harness for the lamp-controller
backend integrations. It polls a command source once, applies commands via a
selected lamp backend, and exits.

> **For continuous operation**, use the **Lamp Controller desktop app**
> (`mac-app/`). The app runs on the home Mac, polls the Cloudflare Worker, and
> drives the lamp directly via in-process Apple HomeKit — no launchd daemon, no
> helper app required.

## Build

```bash
cd mac-agent
swift build
```

## Test

```bash
cd mac-agent
swift test
```

## Run (smoke-test, `--once` only)

```bash
swift run lamp-agent --once   # one poll pass: apply pending commands, then exit
```

Config is read from `$LAMP_AGENT_CONFIG` or `~/.config/lamp-agent/config.toml`
(see [`Resources/config.toml.example`](Resources/config.toml.example)).

> **Note:** the CLI's `--once` mode supports the `worker`, `file`, `shortcuts`,
> and `homebridge` backends. The `homekit` backend has been removed from the CLI;
> in-process HomeKit is handled exclusively by the desktop app.

## Toolchain

Requires Swift 6.0+ with `swift-testing`. On macOS, point at Xcode rather
than the bare command-line tools so the macOS `Testing.framework` is found:

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
# or, per-shell:
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
```

## Lamp backends (CLI smoke-test)

Two backends are available for CLI testing, selected by `lamp_backend` in `config.toml`.

### `shortcuts` (default) — Apple Home via preset Shortcuts

For a lamp already paired to Apple Home (e.g. a Xiaomi Mijia desk lamp), the
agent runs **preset Shortcuts** you create once in the Shortcuts app. Apple's
Home action sets an accessory's state at once (brightness and color temperature
together), so presets are combined. Create these 5 shortcuts (prefix `Lamp`):

| | 50% | 100% |
|---|---|---|
| **Warm** | `Lamp Warm 50` | `Lamp Warm 100` |
| **Cool** | `Lamp Cool 50` | `Lamp Cool 100` |

…plus `Lamp Off` (5 shortcuts total). Each grid preset sets On + that brightness +
that color temperature. The agent maps a command to the nearest cell: brightness →
nearest of {50, 100}; `color_temp_k` → Warm (≤4000 K) / Cool (>4000 K), then
runs `Lamp <Bucket> <Level>`. Brightness and colour temperature snap to the
nearest preset — exact values are not supported.

Requires the Mac to stay logged into the same Apple ID as the Home.

### `homebridge` (alternative) — Homebridge REST

For a lamp bridged through Homebridge config-ui-x. Set `lamp_backend =
"homebridge"` and provide `homebridge_url`, `homebridge_token`, `accessory_id`.
See [`../homebridge/README.md`](../homebridge/README.md).

## Command source

The agent supports two command-source backends, selected by `command_source` in `config.toml`.

### `worker` (default) — Cloudflare Worker queue

The agent polls `GET /commands` on the Worker and acknowledges each command by
calling `POST /ack`. Both requests carry `Authorization: Bearer <shared_secret>`.

Required keys:

```toml
command_source = "worker"
worker_url     = "https://lamp-controller.<subdomain>.workers.dev"
shared_secret  = "REPLACE_WITH_MAC_SHARED_SECRET"
```

`shared_secret` must be the **same value** as the Worker's `MAC_SHARED_SECRET`
environment secret. See [Stage 2 setup](../docs/ops/first-time-setup.md) for
the `openssl rand` + `wrangler secret put` steps.

An optional `state_path` key controls where the applied-command ledger
(`acked.json`) lives; it defaults to `~/.local/state/lamp-agent/acked.json`
and supports `~` expansion.

### `file` (Stage 1 / offline testing) — local JSON array

Reads commands from a local file. Useful when the Worker is not deployed or
for offline development.

Required key:

```toml
command_source = "file"
commands_path  = "~/.local/state/lamp-agent/commands.json"
```

`worker_url` and `shared_secret` are ignored for this source.
