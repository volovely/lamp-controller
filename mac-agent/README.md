# mac-agent

Swift CLI daemon that runs on the home Mac. It polls a command queue (a local
`commands.json` in Stage 1; the Cloudflare Worker in Stage 2+) and applies each
command to the lamp. The default backend drives **Apple Home** via the macOS
`shortcuts` CLI; a Homebridge REST backend is also available.

## Build

```bash
swift build
```

## Test

```bash
swift test
```

## Run

```bash
swift run lamp-agent --once   # one poll pass (apply pending commands, then exit)
swift run lamp-agent          # daemon: poll forever at poll_interval_s
```

Config is read from `$LAMP_AGENT_CONFIG` or `~/.config/lamp-agent/config.toml`
(see [`Resources/config.toml.example`](Resources/config.toml.example)).

## Toolchain

Requires Swift 6.0+ with `swift-testing`. On macOS, point at Xcode rather
than the bare command-line tools so the macOS `Testing.framework` is found:

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
# or, per-shell:
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
```

## Controlling the lamp

Two backends, selected by `lamp_backend` in `config.toml`:

### `shortcuts` (default) — Apple Home

For a lamp already paired to Apple Home (e.g. a Xiaomi Mijia desk lamp), the
agent runs **preset Shortcuts** you create once in the Shortcuts app. Apple's
Home action sets an accessory's *whole* state at once (brightness and color
temperature together), so presets are combined. Create these 5 shortcuts
(prefix `Lamp`):

| | 50% | 100% |
|---|---|---|
| **Warm** | `Lamp Warm 50` | `Lamp Warm 100` |
| **Cool** | `Lamp Cool 50` | `Lamp Cool 100` |

…plus `Lamp Off` (5 shortcuts total). Each grid preset sets On + that
brightness + that color temperature. The agent maps a command to the nearest
cell: brightness → nearest of {50, 100}; `color_temp_k` → Warm (≤4000 K) /
Cool (>4000 K), then runs `Lamp <Bucket> <Level>`. Requires the Mac to stay
logged into the same Apple ID as the Home.

### `homebridge` — Homebridge REST (alternative)

For a lamp bridged through Homebridge config-ui-x. Set `lamp_backend =
"homebridge"` and provide `homebridge_url`, `homebridge_token`, `accessory_id`.
See [`../homebridge/README.md`](../homebridge/README.md).

## Install (launchd)

Installation as a launchd LaunchAgent is documented in
[`scripts/install.sh`](scripts/install.sh) and the ops runbook.
