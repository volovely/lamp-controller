# Lamp Controller (desktop app)

A Mac Catalyst SwiftUI app that runs on the home Mac as a **menu-bar app**: a 💡
icon appears in the macOS menu bar and there is **no Dock icon**. It polls the
Cloudflare Worker for queued commands and applies each one directly via Apple
HomeKit — setting exact brightness (0–100) and colour temperature (Kelvin) with
no preset snapping and no separate helper process.

### Behavior at runtime

- **Auto-starts polling on launch** (once config and HomeKit access are ready).
- An **Activity window opens on launch**. **Keep it open (or minimized) to keep
  the app running.** Closing the window (red ⊗) **quits the app** — a Mac
  Catalyst limitation: the Activity window is the app's only UI scene, and macOS
  terminates the process when the last scene closes (this could not be reliably
  prevented from a Catalyst app). Minimizing the window keeps the scene alive, so
  the app keeps polling in the menu bar.
- The 💡 menu offers **Start** / **Stop** (to control polling), **Show
  Activity…** (to bring the Activity window forward), and **Quit** (the explicit
  way to exit).
- To run at macOS login, add the app to **System Settings → General → Login
  Items** (manual step for v1 — there is no automatic installer).

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
# DEVELOPER_DIR must point at a full Xcode, not the Command Line Tools.
# Find the installed Xcode: ls -d /Applications/Xcode*.app
# (on this Mac it is Xcode-beta.app, so the path is below)
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
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
