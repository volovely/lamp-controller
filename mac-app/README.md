# Lamp Controller (desktop app)

A Mac Catalyst SwiftUI app that runs on the home Mac continuously. It shows a
single window with **Start** and **Stop** buttons. When running, it polls the
Cloudflare Worker for queued commands and applies each one directly via Apple
HomeKit — setting exact brightness (0–100) and colour temperature (Kelvin) with
no preset snapping and no separate helper process.

This is the supported way to run the lamp agent. The `mac-agent` CLI (`lamp-agent`)
is kept only as a `--once` smoke-test harness for the worker/file/shortcuts/homebridge
backends.

## Config

The app reads `~/.config/lamp-agent/config.toml`. Keys it uses:

| Key | Description |
|---|---|
| `command_source` | `"worker"` (default) or `"file"` |
| `worker_url` | `https://lamp-controller.<subdomain>.workers.dev` |
| `shared_secret` | Bearer token matching the Worker's `MAC_SHARED_SECRET` |
| `state_path` | Path to the applied-command ledger; defaults to `~/.local/state/lamp-agent/acked.json` |
| `poll_interval_s` | Seconds between polls; defaults to `12` |
| `homekit_accessory_name` | Exact accessory name as it appears in Apple Home |

## One-time setup

### 1. Enable the HomeKit capability for the App ID

The app's bundle ID is `com.volovely.lamp-controller`. The HomeKit entitlement
must be enabled for this App ID before the app can talk to Apple Home.

1. Sign in at [developer.apple.com](https://developer.apple.com) →
   **Certificates, Identifiers & Profiles → Identifiers**.
2. Find or create `com.volovely.lamp-controller`.
3. Enable the **HomeKit** capability and save.

A paid Apple Developer account is required for the HomeKit entitlement.

### 2. Grant Home access on first launch

The first time the app starts polling, macOS shows an **"Allow 'Lamp Controller'
to access your home?"** prompt. Click **Allow**. Without this, all HomeKit calls
silently fail.

To confirm access was granted later: **System Settings → Privacy & Security →
Home** — "Lamp Controller" should be listed and enabled.

## Build and run

```bash
cd mac-app
brew install xcodegen            # if not already installed
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodegen generate
open LampController.xcodeproj   # then ⌘R to build and run
```

Or build from the command line:

```bash
xcodebuild -project LampController.xcodeproj -scheme LampController \
  -destination 'platform=macOS,variant=Mac Catalyst' \
  -allowProvisioningUpdates build
```

The app is **not built in CI** — signing requires the paid Apple Developer team
and is done locally or on the self-hosted runner.

## Entitlements

The app requires:

- `com.apple.security.network.client` — outbound HTTP to the Cloudflare Worker
- `com.apple.developer.homekit` — Apple HomeKit access

Both are already present in `Sources/Entitlements.entitlements`.
