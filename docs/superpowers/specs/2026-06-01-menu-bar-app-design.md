# Lamp Controller menu-bar app — Design

**Date:** 2026-06-01
**Status:** Approved (design)
**Owner:** @volovely
**Parent spec:** [`2026-05-24-lamp-controller-design.md`](2026-05-24-lamp-controller-design.md)
**Builds on:** [`2026-05-31-desktop-app-design.md`](2026-05-31-desktop-app-design.md) (Stage 1 Mac→lamp, Stage 2 Worker queue, desktop app)

## Purpose

Turn the Lamp Controller desktop app into a **menu-bar app**: it lives in the
macOS menu bar (an `NSStatusItem`), polls the Cloudflare Worker, and drives the
lamp via in-process HomeKit — **without requiring a visible window or a Dock
icon**, and **without a launchd daemon**. The current window app works but must
be kept frontmost for HomeKit writes to succeed; the menu-bar app removes that
friction so it can run quietly in the background and auto-start on launch.

**Demoable:** launch the app → a lamp icon appears in the menu bar with **no
Dock icon**; the app auto-starts polling (menu shows `● Running`);
insert a command with `wrangler kv put` → within one poll interval the lamp
obeys and the Activity window shows it; **Stop**/**Start**
from the menu toggle polling; keep the window open or minimized to keep polling;
**Quit** from the menu exits.

> **Known limitations (discovered at implementation):**
>
> 1. **No-window-on-launch could not be delivered.** SwiftUI's
>    `defaultLaunchBehavior(.suppressed)` is marked `@available(iOS, unavailable)`
>    and the Mac Catalyst triple is `ios-macabi`, so it fails to compile. As
>    shipped, the **Activity window appears on launch**.
> 2. **Close-≠-quit could not be delivered.** Closing the Activity window **quits
>    the app**. Diagnosis (via runtime instrumentation): the Activity window is the
>    app's only `UIWindowScene`; closing it disconnects that scene and macOS
>    terminates the process. This is a UIKit-scene-level teardown that bypasses
>    every AppKit window hook we tried — `applicationShouldTerminateAfterLastWindowClosed:`
>    is never consulted (the status item keeps an AppKit window alive, so AppKit
>    never thinks the "last window" closed), and swizzling `performClose:`/`close`
>    on the concrete `UINSWindow` subclass did not intercept the close either. The
>    `.accessory` activation policy does not prevent scene-zero termination.
>    **Workaround for the user: keep the window open or minimized** (minimizing
>    keeps the scene connected, so polling continues); use the menu's **Quit** to
>    exit intentionally.
>
> Every other goal — no Dock icon, menu-bar control, auto-start, background run
> while the window is open/minimized — is met. A future fix would require
> reaching the scene's underlying `NSWindow` via private Catalyst API to convert
> close→hide, or shipping a small bundled AppKit plugin; both were judged not
> worth the fragility on the current OS.

## Why this design

- **The foreground problem.** HomeKit on macOS is Mac Catalyst-only and writes
  fail (`Code=80`) unless the app is foreground-active. The window app solved the
  *runtime* path but still demands a visible, frontmost window. The
  **`.accessory` activation policy** (`NSApplicationActivationPolicyAccessory`)
  satisfies HomeKit's foreground requirement **without** a window or Dock icon —
  proven via spike (`homed` log showed HAP pair-verify + PUT 204 while Finder was
  frontmost). This is the core enabler.
- **Catalyst can reach AppKit.** Catalyst cannot `import AppKit`, but
  `NSStatusItem` / `NSMenu` are reachable through the ObjC runtime
  (`NSClassFromString` + `dlsym(RTLD_DEFAULT, "objc_msgSend")`). Proven via spike
  (`STATUSITEM_RUNTIME_OK`: status item created, menu clickable, callbacks fire).
- **Everything else is reused.** The entire Stage 1/2 command pipeline
  (`PollLoop`, `AckStore`, `WorkerCommandSource`, `CommandExecutor`, `Config`,
  `HomeKitController`) and the existing `AppModel` / `ContentView` are reused. The
  only new surface is the menu-bar UI and the activation-policy flip.

## Non-goals (this iteration)

- No in-app settings editing — still reads the existing
  `~/.config/lamp-agent/config.toml` read-only.
- No login-item / launch-at-login registration — auto-start means "starts polling
  when the app is launched", not "launches the app at macOS login". (The user
  still opens the app, or adds it to Login Items manually.)
- No new command source — polls the Worker (`command_source = "worker"`), same
  contract as Stage 2.
- No menu-bar-based config or live-edit; the Activity window remains the only
  detailed UI surface.

## Decisions captured (from brainstorming)

- **Menu + optional window** — the status-item menu is the primary surface; the
  existing `ContentView` becomes an optional Activity window opened on demand.
- **Auto-start on launch** — once config + HomeKit are ready, start polling
  automatically (no manual Start click each launch).
- **StatusItem via runtime ObjC** — chosen after the spike proved it works (vs. a
  bundled AppKit plugin bundle). Keeps everything in one Catalyst target.

## Architecture

```
mac-app/                         (existing Catalyst app, xcodegen project)
  depends on ../mac-agent        (LampAgent SPM library — core reused as-is)

  LampControllerApp (SwiftUI @main)
    - init: AppKitBridge.setAccessoryActivationPolicy()  (no Dock, no window req)
    - init: install MenuBarController
    - init: AppModel.autoStart()
    └─ WindowGroup → ContentView   (OPTIONAL Activity window, opened from menu)

  AppKitBridge        (NEW — the ONLY file with objc_msgSend/NSClassFromString)
  MenuBarController    (NEW — owns NSStatusItem, builds menu from AppModel)
  AppModel             (REUSED + autoStart())
  HomeKitController    (REUSED unchanged)
  ContentView          (REUSED as the optional Activity window)
```

**The key boundary:** `AppKitBridge` is the single place with unsafe runtime
casts. `MenuBarController` knows *intent* (status line, Start/Stop, Show
Activity, Quit); `AppKitBridge` knows *runtime mechanics* (how to create the
status item and dispatch clicks). Changing one must not require touching the
other.

### Reuse vs new

| Reused unchanged | New / modified (in `mac-app`) |
|---|---|
| `LampAgent` core (`PollLoop`, `AckStore`, `WorkerCommandSource`, `CommandExecutor`, `Config`, `Command`) | `AppKitBridge.swift` (NEW — activation policy + StatusItem facade) |
| `HomeKitController.swift` | `MenuBarController.swift` (NEW — owns status item, menu model) |
| `ContentView.swift` (now the optional Activity window) | `AppModel.swift` (+ `autoStart()`) |
| `LampClient` / `.homeKit(controller:)` | `LampControllerApp.swift` (init: policy + controller + autoStart; window optional) |
| xcodegen `project.yml`, entitlements | `StatusItemSpike.swift` **deleted** (logic folds into `AppKitBridge`) |

## Components

### `mac-app/Sources/AppKitBridge.swift` (NEW)
The only file containing `NSClassFromString` / `dlsym` / `objc_msgSend`. Two
responsibilities:
- `setAccessoryActivationPolicy()` — flips the app to `.accessory`
  (`NSApplicationActivationPolicyAccessory`): no Dock icon, no window required,
  satisfies HomeKit's foreground requirement.
- A `StatusItem` wrapper around the live `NSStatusItem`: create with a title/icon,
  `setMenu(_:)`, and a menu builder taking `[(title, enabled, action)]`. Click
  callbacks are dispatched through a small retained `NSObject` trampoline (the
  proven spike pattern — `@objc` method reached via runtime selector dispatch).
- Proven `objc_msgSend` `@convention(c)` typealias casts from the spike live here
  and nowhere else.

### `mac-app/Sources/MenuBarController.swift` (NEW)
Owns the `StatusItem`, observes `AppModel`, rebuilds the menu on state change. No
runtime casts (delegates all of that to `AppKitBridge`).
- **Menu model** is a pure function `menuItems(for state) -> [MenuItem]` where
  `MenuItem` carries `title`, `enabled`, and an `action-kind` enum
  (`.toggle` / `.showActivity` / `.quit`) — assertable without AppKit.
- Status line: `● Running` / `○ Stopped` / `⚠ HomeKit denied` / `⚠ Config error`
  / `● Running · accessory not found`.
- Translates clicks into `AppModel.start()` / `.stop()` / open-window / `exit(0)`.

### `mac-app/Sources/AppModel.swift` (REUSED + addition)
Gains `autoStart()` called once at launch:
`await homeKitController.waitUntilLoaded()` → if config loaded and HomeKit
`.ready`, call `start()`; otherwise stay stopped. `start()` is idempotent
(no-op if already running) so a menu click during auto-start cannot spawn a
second `PollLoop`. Everything else (PollLoop wiring, activity log, `runState`,
`@Observable`) unchanged.

### `mac-app/Sources/LampControllerApp.swift` (MODIFIED)
At `init`: `AppKitBridge.setAccessoryActivationPolicy()`, instantiate
`MenuBarController` (which installs the status item), and trigger
`AppModel.autoStart()`. The `WindowGroup`/`ContentView` becomes the *optional*
Activity window — not shown on launch, opened from the menu's **Show Activity…**.

### `HomeKitController.swift`, `ContentView.swift`, LampAgent core
Reused unchanged. `ContentView` already binds to the `@Observable` `AppModel`.
`StatusItemSpike.swift` is deleted; its proven logic folds into `AppKitBridge`.

## Data flow & lifecycle

**Launch sequence:**
```
App launches (.accessory policy set in init — no Dock icon, no window)
  → MenuBarController installs NSStatusItem (lamp icon in menu bar)
  → AppModel.loadConfig()
  → AppModel.autoStart(): await HomeKit load
       ├─ config OK + HomeKit ready  → start() → PollLoop runs (● Running)
       └─ config error / HomeKit denied → stay stopped, menu shows ⚠
```

**Steady state (running):** identical to the window app — `PollLoop` polls the
Worker, dedups via `AckStore`, applies `LampState` through `HomeKitController`,
acks. `MenuBarController` observes `AppModel` via an `onStateChange` closure (the
same pattern `HomeKitController` already uses) and refreshes the menu's status
line + Start/Stop label on each change. `ContentView`, if open, shows the same
activity log via its `@Observable` binding.

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

   AppModel.onStateChange ──▶ MenuBarController.rebuildMenu()  (status line + Start/Stop)
```

**Menu interactions:**

| Click | Effect |
|---|---|
| **Stop** (while running) | `AppModel.stop()` → cancels Task → menu flips to `○ Stopped` |
| **Start** (while stopped) | `AppModel.start()` → menu flips to `● Running` |
| **Show Activity…** | Opens the `ContentView` window (bring-to-front) |
| **Quit** | `stop()` then `exit(0)` |

**Window lifecycle (as designed — see Known limitation #2 for what shipped):**
the intent was that closing the Activity window would *not* quit the app. In
practice Mac Catalyst terminates the process when the only `UIWindowScene`
closes, so **closing the window quits the app**. The working substitute is to
**minimize** the window (keeps the scene connected) and use **Quit** to exit.

## Error handling

| Condition | Behavior |
|---|---|
| `config.toml` missing/invalid | Menu shows `⚠ Config error`; Start disabled; Show Activity… reveals the parse error. No auto-start. |
| HomeKit access denied (TCC) | Menu shows `⚠ HomeKit denied`; Start disabled. Activity window hints System Settings → Privacy → Home. |
| Configured accessory not found | Menu shows `● Running · accessory not found`; polling continues, each apply logs the miss (command not acked → retried). |
| Worker unreachable / non-2xx | Logged in activity; `PollLoop` backoff retries. Menu stays `● Running`. |
| HomeKit write fails mid-command | Logged; command not acked → retried. |
| Stale command (>10 min) | Dropped by the existing stale-guard. |

**Menu-bar-specific edge cases:**
- **`NSStatusItem` fails to create** (runtime call returns nil): log it and **fall
  back to showing the Activity window** so the app is still usable rather than an
  invisible headless process. (Defensive — the spike proved the happy path.)
- **Auto-start race:** HMHomeManager loads asynchronously. `autoStart()` waits on
  the existing `HomeKitController.waitUntilLoaded()` before deciding
  ready-vs-denied, so it doesn't skip auto-start every launch.
- **Double-start guard:** `start()` is idempotent, so a menu click during
  auto-start cannot spawn two PollLoops.

## Testing

**Reused core (unchanged, stays green):** all `mac-agent` `LampAgent` tests —
`Command`, `AckStore`, `WorkerCommandSource`, `PollLoop`, `CommandExecutor`,
`Config`, plus `HomeKitController` apply-mapping. No core source changes this
iteration, so no test churn.

**New, unit-testable glue:**
- `AppModel.autoStart()` — with a stub `CommandSource` + stub HomeKit state:
  assert it starts when ready, does **not** start when denied/config-error, and is
  a no-op if already running (double-start guard).
- `MenuBarController.menuItems(for:)` — pure function returning
  `[MenuItem(title, enabled, action-kind)]`. Assert "running shows Stop",
  "denied disables Start", "stopped shows Start", "config-error disables Start" —
  **without** touching AppKit (the `action-kind` is an enum, not a live closure).

**Not unit-tested (by design):**
- `AppKitBridge` runtime casts — exercised by the spike
  (`STATUSITEM_RUNTIME_OK` / `ACCESSORY_WORKS`) and by live run; mocking
  `objc_msgSend` would test nothing real.
- SwiftUI views.

**Live verification (the demoable — matches `lamp-integration-verifier`):**
1. Build, launch → lamp icon appears in menu bar, **no Dock icon, no window**.
2. App auto-starts (menu shows `● Running`).
3. `wrangler kv put` a command → within one poll the lamp obeys; Activity window
   (opened from menu) shows the entry.
4. Click **Stop** → polling halts. Click **Start** → resumes.
5. Close Activity window → app keeps polling (menu still `● Running`). **Quit**
   from menu → gone.

## One-time setup (human-in-the-loop)

Unchanged from the desktop app — HomeKit capability already enabled for
`com.volovely.lamp-controller`; TCC "Home Access" already granted; config.toml
already populated. No new entitlements (the `.accessory` policy needs none).

## Build & run

Same as the desktop app (`mac-app/README.md`): `xcodegen generate` then build
from Xcode or headless `xcodebuild ... -allowProvisioningUpdates`. Not built in
CI (signing needs the paid team); the reused `LampAgent` core continues to
build/test in CI via `mac-agent`. README updated to note the app now lives in the
menu bar (no Dock icon) and auto-starts.

## Disposition of spike scaffolding

- `StatusItemSpike.swift` — **deleted**; proven logic folds into `AppKitBridge`.
- Any `LAMP_SPIKE_AUTOSTART` / spike-only hooks in `LampControllerApp.swift` —
  **removed**; replaced by the real `MenuBarController` + `autoStart()` wiring.
- The spike commits remain in history as the feasibility record; the handoff doc
  (`docs/superpowers/HANDOFF-2026-05-31.md`) is superseded by this spec.

## Open items (non-blocking)

- **Menu-bar icon art** — a simple SF Symbol / template image for v1; can refine.
- **Launch-at-login** — still manual (Login Items); a `SMAppService` login-item
  registration is a future nicety.
- **Activity window re-open polish** — bring-to-front behaviour when already open.
