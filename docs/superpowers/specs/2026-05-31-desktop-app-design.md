# Lamp Controller desktop app — Design

**Date:** 2026-05-31
**Status:** Approved (design)
**Owner:** @volovely
**Parent spec:** [`2026-05-24-lamp-controller-design.md`](2026-05-24-lamp-controller-design.md)
**Builds on:** Stage 1 (Mac→lamp), Stage 2 (Worker queue)

## Purpose

Replace the launchd daemon / CLI-loop way of running the agent with a **Mac
desktop app** that the user starts and stops with a button. The app polls the
Cloudflare Worker itself and drives the lamp **directly via HomeKit** — no
separate helper process, no per-command `open`, no dock-bounce.

**Demoable:** launch "Lamp Controller.app", click **Start**; insert a command
with `wrangler kv put` (or send it however); within one poll interval the lamp
obeys and the activity log shows it. Click **Stop**; polling halts.

## Why this design

- HomeKit on macOS is **Mac Catalyst-only** and requires a **foreground app**.
  A CLI can't do foreground HomeKit, which is why Stage 1 needed a separate
  helper launched per command. A desktop app *is* a foreground app, so it can
  hold `HMHomeManager` and apply characteristics in-process. **This makes the
  helper obsolete at runtime.**
- The entire Stage 1/2 command pipeline (`PollLoop`, `AckStore`,
  `WorkerCommandSource`, `CommandExecutor`, `Config`) is reused unchanged. Only
  the lamp-control leaf swaps from "launch the helper" to "in-app HomeKit".

## Non-goals (this iteration)

- No in-app settings editing — the app reads the existing
  `~/.config/lamp-agent/config.toml` (already populated) and shows the key
  fields read-only. Editing remains file-based for now.
- No menu-bar UI — a normal window app.
- No new command source — the app polls the Worker (`command_source = "worker"`),
  same contract as Stage 2.

## Disposition of the old run-paths (app replaces them)

The desktop app is the **sole** runtime way to run the agent. As part of this
work:
- **`mac-agent/homekit-helper/`** is removed — the app controls HomeKit
  in-process, so the per-command helper is obsolete. (Its working HomeKit logic
  is lifted into `HomeKitController` first, then the helper directory is deleted.)
- The CLI **`lamp-agent` executable target stays** (it's the smoke-test/`--once`
  harness and exercises the same `LampAgent` core), but its `homekit` lamp
  backend — which shells out to the now-deleted helper — is removed. The CLI is
  no longer a supported *continuous-run* path; the app owns that. `shortcuts`
  and `homebridge` backends remain for the CLI.
- The launchd LaunchAgent (`Resources/com.lamp.agent.plist`, `scripts/install.sh`
  / `uninstall.sh`) is removed — superseded by the app.
- `config.toml`'s `homekit_helper_path` becomes unused and is dropped from the
  example/docs; `homekit_accessory_name` is still used (now by the app).

Sequencing: lift helper logic → build the app → verify the app drives the lamp →
THEN delete the helper / launchd / CLI-homekit-backend, so we never have a
window with no working path.

## Architecture

```
mac-app/                         (NEW — SwiftUI Mac Catalyst app, xcodegen project)
  depends on ../mac-agent        (the LampAgent SPM library — core reused as-is)

  LampControllerApp (SwiftUI @main)
    └─ ContentView: Start/Stop button, status line, activity log
         └─ AppModel (@MainActor @Observable)
              - load Config from ~/.config/lamp-agent/config.toml
              - start(): build in-app LampClient → run PollLoop in a cancellable Task
              - stop(): cancel the Task
              - publishes: runState, homeKitState, lastPoll, activity log entries
         └─ HomeKitController (NSObject, HMHomeManagerDelegate)
              - loads HMHomeManager, finds the configured accessory's Lightbulb
              - apply(LampState): writes On / Brightness / ColorTemperature(mired)
              - exposes a `LampClient` value whose `apply` calls into it
```

The app injects its in-app `LampClient` via `withDependencies` so the reused
`CommandExecutor.live()` (`@Dependency(\.lampClient)`) drives HomeKit directly.

### Reuse vs new

| Reused unchanged (from `mac-agent` LampAgent) | New (in `mac-app`) |
|---|---|
| `Command`, `Command.jsonDecoder` | `LampControllerApp` (SwiftUI entry) |
| `CommandSource.worker(...)` | `ContentView` (Start/Stop, status, log) |
| `PollLoop` (dedup, stale-guard, backoff) | `AppModel` (lifecycle + published state) |
| `AckStore` | `HomeKitController` (in-app HomeKit; lifts helper logic) |
| `CommandExecutor.live()` | `LampClient.homeKit(controller:)` factory (in-app) |
| `Config` (reads the toml) | xcodegen `project.yml`, entitlements, Info.plist |

## Components

### `mac-app/Sources/HomeKitController.swift`
Lifts the working HomeKit logic from `mac-agent/homekit-helper/Sources/main.swift`
into a reusable class:
- `HMHomeManager` + `HMHomeManagerDelegate`; tracks an authorization/loaded state
  (`unknown` → `loading` → `ready(accessoryFound: Bool)` / `denied`).
- `apply(_ state: LampState) async throws`: find the configured accessory's
  `HMServiceTypeLightbulb`; write `PowerState`, then (if on) `Brightness` and
  `ColorTemperature` (Kelvin→mired via the existing `miredFromKelvin`, clamped to
  the characteristic's advertised range). Throws on accessory-not-found / write
  failure.
- The app is foreground, so writes succeed (no Code=80 background error).

### `mac-app/Sources/LampClient+HomeKit.swift`
`extension LampClient { static func homeKit(_ controller: HomeKitController) -> LampClient }`
— `apply = { state in try await controller.apply(state) }`. This is the in-app
replacement for `LampClient.homekit(helperAppPath:…)`.

### `mac-app/Sources/AppModel.swift`
`@MainActor @Observable final class AppModel`:
- `enum RunState { case stopped, running }`, plus `homeKitState`, `lastError?`,
  `activity: [LogEntry]` (timestamp + message, capped to ~100).
- `loadConfig()` → `Config.load(from: ~/.config/lamp-agent/config.toml)`; surfaces
  parse/missing errors in the UI rather than crashing.
- `start()`: guard config + HomeKit ready; build
  `PollLoop(source: .worker(baseURL:sharedSecret:), executor: .live(), ackStore: .file(at: statePath))`;
  launch `Task { withDependencies { $0.lampClient = .homeKit(controller) } operation: { try await loop.run(intervalSeconds:) } }`;
  set `runState = .running`. Each applied/failed cycle appends to `activity`.
- `stop()`: cancel the Task; `runState = .stopped`.

### `mac-app/Sources/ContentView.swift`
A single window:
- Header: app name + lamp accessory name (from config).
- Status rows: HomeKit (`loading` / `ready · N accessories` / `denied` / `accessory not found`); Worker URL (read-only); last poll result.
- **Start / Stop** button (toggles on `runState`), disabled until config loaded + HomeKit ready.
- Activity log (scrolling list, newest first): e.g. `10:42:03  applied on 30% 2700K`, `10:42:15  worker unreachable — will retry`.

### Project files
- `mac-app/project.yml` (xcodegen): a Catalyst app target, `DEVELOPMENT_TEAM = 3MFN7Y7D69`, `PRODUCT_BUNDLE_IDENTIFIER = com.volovely.lamp-controller`, depends on the local SPM package at `../mac-agent` (product `LampAgent`).
- `mac-app/Sources/Entitlements.entitlements`: `com.apple.developer.homekit = true`.
- Info.plist (generated): `NSHomeKitUsageDescription`.
- `mac-app/.gitignore`: ignore `*.xcodeproj`, `build/`, `DerivedData/`.

### `mac-agent/Package.swift` change
Add an iOS platform so the `LampAgent` library builds for Mac Catalyst (currently
macOS-only): `platforms: [.macOS(.v14), .iOS(.v17)]`. No source changes; the core
is pure Foundation + Dependencies + TOMLKit (all Catalyst-compatible). The
existing `mac-agent` macOS build/tests are unaffected.

## Data flow (running)

```
Worker KV ──GET /commands (bearer)──▶ WorkerCommandSource ──▶ PollLoop
                                                                  │ dedup(AckStore), stale-guard
                                                                  ▼
                                                          CommandExecutor.live()
                                                                  │ @Dependency(\.lampClient)
                                                                  ▼
                                                   LampClient.homeKit(controller)
                                                                  ▼
                                                   HomeKitController.apply(LampState)
                                                                  ▼  HMCharacteristic.writeValue
                                                                💡 lamp
   PollLoop ──POST /ack (bearer)──▶ Worker deletes the command key
```

## Error handling

| Condition | Behavior |
|---|---|
| `config.toml` missing/invalid | App shows the error in the window; Start disabled. |
| HomeKit access denied (TCC) | Status shows `denied`; link/hint to System Settings → Privacy → Home. Start disabled. |
| Configured accessory not found | Status shows `accessory not found`; Start disabled (or allowed but each apply errors visibly). |
| Worker unreachable / non-2xx | Logged in activity; commands not acked → retried by `PollLoop` backoff. |
| HomeKit write fails mid-command | Logged; command not acked → retried. |
| Stale command (>10 min) | Dropped by the existing stale-guard. |

## Testing

- **Reused core:** `mac-agent`'s core tests stay green. Removing the CLI's
  `homekit` backend deletes `HomeKitClientTests` (the 5 helper-arg tests) and the
  `homekit` case from `Config`/`ConfigTests`; everything else (Command, AckStore,
  WorkerCommandSource, PollLoop, CommandExecutor, Config worker/file/shortcuts/
  homebridge) stays. Net: the suite shrinks by the helper tests, stays green.
- **New, unit-testable glue:** `LampClient.homeKit` maps a `LampState` to a
  single `controller.apply` call (test with a stub controller recording the
  state). `AppModel.start/stop` toggles `runState` and injects the right
  `lampClient` (test with a stub `CommandSource` + stub controller, asserting a
  queued command flows to the controller and `stop()` cancels). UI views are not
  unit-tested.
- **HomeKit write path:** verified live against the real lamp (as in Stage 1).

## One-time setup (human-in-the-loop)

1. **Enable the HomeKit capability** for App ID `com.volovely.lamp-controller`
   at developer.apple.com (same one-click step done for the helper's App ID).
2. Build the app (xcodegen + xcodebuild, documented in `mac-app/README.md`).
3. First launch → **Allow** the macOS "Home Access" prompt (TCC, per-app).
4. Ensure `~/.config/lamp-agent/config.toml` has `worker_url`, `shared_secret`,
   `homekit_accessory_name` (already set up from Stage 2).

## Build & run

`mac-app/README.md` documents:
```bash
cd mac-app
brew install xcodegen      # if needed
xcodegen generate
open LampController.xcodeproj   # build + run from Xcode (⌘R)
# or headless:
xcodebuild -project LampController.xcodeproj -scheme LampController \
  -destination 'platform=macOS,variant=Mac Catalyst' \
  -allowProvisioningUpdates build
```

The HomeKit helper isn't built in CI (signing needs the paid team); the app is
the same — built locally, not in CI. The reused `LampAgent` core continues to
build/test in CI via `mac-agent`.

## Open items (non-blocking)

- **App icon / window polish** — minimal for v1; can refine later.
- **Auto-start on launch / login item** — deferred; v1 requires a manual Start
  click each launch.
- **CLI `--once` harness** — the `lamp-agent` executable is kept for
  smoke-testing the core (worker/file/shortcuts/homebridge), but no longer drives
  HomeKit; the app is the supported lamp path.
