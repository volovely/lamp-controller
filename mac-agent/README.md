# mac-agent

Swift CLI daemon that runs on the home Mac. It polls a command queue (a local
`commands.json` in Stage 1; the Cloudflare Worker in Stage 2+) and applies each
command to the lamp. The default backend is **HomeKit** — a signed Mac Catalyst
helper that sends exact brightness and colour temperature via Apple HomeKit.
Shortcuts and Homebridge backends are also available.

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

Three backends, selected by `lamp_backend` in `config.toml`:

### `homekit` (default) — native Apple Home

The agent launches a signed **Mac Catalyst helper app** (`mac-agent/homekit-helper/`)
per command via `open -W`. The helper talks directly to Apple HomeKit and sets
exact brightness (0–100) and colour temperature (Kelvin) with no preset snapping.
This is the highest-fidelity backend.

#### One-time setup

1. **Paid Apple Developer account required.** In Xcode → Settings → Accounts,
   sign in with your Apple ID; Xcode will use that team to sign the helper.

2. **Enable the HomeKit capability** for App ID `com.volovely.lamp-homekit-helper`
   at [developer.apple.com](https://developer.apple.com) → Certificates, Identifiers
   & Profiles → Identifiers, if it is not already enabled.

3. **Build the helper:**

   ```bash
   brew install xcodegen   # if not already installed
   cd mac-agent/homekit-helper
   export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
   xcodegen generate
   xcodebuild -project LampHomeKitHelper.xcodeproj -scheme LampHomeKitHelper \
     -destination 'platform=macOS,variant=Mac Catalyst' \
     -derivedDataPath build -allowProvisioningUpdates -allowProvisioningDeviceRegistration build
   ```

   The built app lands at:
   `mac-agent/homekit-helper/build/Build/Products/Debug-maccatalyst/LampHomeKitHelper.app`

   The `build/` directory is gitignored — rebuild locally or on the self-hosted
   runner whenever the helper changes. CI does not build it (signing requires
   the paid team).

4. **Grant Home Access.** The first time you run the helper, macOS shows a
   "Home Access" prompt — click **Allow**. To find the lamp's exact accessory
   name as it appears in Apple Home, run:

   ```bash
   LAMP_HK_RESULT=/tmp/r open -W "/path/to/LampHomeKitHelper.app" --args --discover
   cat /tmp/r
   ```

   This prints all homes and accessories. Pass `--verbose` for extra detail.

5. **Update `config.toml`** with the two HomeKit keys:

   ```toml
   lamp_backend           = "homekit"
   homekit_helper_path    = "/path/to/LampHomeKitHelper.app"
   homekit_accessory_name = "Mijia desk lamp 1S"   # exact name from --discover
   ```

#### Notes

- The Mac must stay logged into the **same Apple ID** as the Home; a different
  ID or a signed-out session will cause Home access to fail.
- Each command briefly launches the helper app in the background — this is
  expected; it exits immediately after applying the command.
- The helper is not built in CI. Build it locally or on the self-hosted runner
  before deploying.

---

### `shortcuts` (alternative) — Apple Home via preset Shortcuts

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
Cool (>4000 K), then runs `Lamp <Bucket> <Level>`. Brightness and colour
temperature snap to the nearest preset — exact values are not supported.
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

Design details: [`docs/superpowers/specs/2026-05-31-stage-2-worker-queue-design.md`](../docs/superpowers/specs/2026-05-31-stage-2-worker-queue-design.md).

### `file` (Stage 1 / offline testing) — local JSON array

Reads commands from a local file. Useful when the Worker is not deployed or
for offline development.

Required key:

```toml
command_source = "file"
commands_path  = "~/.local/state/lamp-agent/commands.json"
```

`worker_url` and `shared_secret` are ignored for this source.

---

## Install (launchd)

Installation as a launchd LaunchAgent is documented in
[`scripts/install.sh`](scripts/install.sh) and the ops runbook.
