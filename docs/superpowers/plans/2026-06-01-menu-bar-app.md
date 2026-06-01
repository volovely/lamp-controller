# Menu-bar app Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the Lamp Controller Catalyst app into a menu-bar app — an `NSStatusItem` with a Start/Stop/Show-Activity/Quit menu, no Dock icon, no window on launch, that auto-starts polling and runs in the background.

**Architecture:** Reuse the entire `LampAgent` core + `HomeKitController` + `AppModel` + `ContentView` unchanged in behavior. Add three files: `AppKitBridge` (the *only* file with `objc_msgSend`/`NSClassFromString` — activation policy + `NSStatusItem` facade), `MenuBarController` (owns the status item, builds the menu from a pure `menuModel(...)` function, performs clicks), and `AppDelegate` (launch-time bootstrap). The `.accessory` activation policy satisfies HomeKit's foreground requirement with no window; window open/close uses UIKit scene APIs (Catalyst can import UIKit; only AppKit needs the runtime bridge).

**Tech Stack:** Swift 6, SwiftUI + Mac Catalyst, UIKit scene APIs, ObjC runtime (`dlsym`/`objc_msgSend`) for AppKit-only classes, swift-testing, xcodegen + xcodebuild, Point-Free Dependencies.

---

## File structure

| File | Responsibility | Disposition |
|---|---|---|
| `mac-app/Sources/AppKitBridge.swift` | The ONLY file with `NSClassFromString`/`dlsym`/`objc_msgSend`: `.accessory` policy + an `NSStatusItem` facade (`StatusItem`). | Create |
| `mac-app/Sources/MenuBarController.swift` | Owns the `StatusItem`, observes `AppModel`, rebuilds the menu; pure `menuModel(...)` for the menu contents; performs clicks (start/stop/show-activity/quit). | Create |
| `mac-app/Sources/AppDelegate.swift` | `UIApplicationDelegate` launch bootstrap: set policy, load config, install `MenuBarController`, auto-start. Owns the single `AppModel`. | Create |
| `mac-app/Sources/AppModel.swift` | Add `onChange` notification, `autoStart()`, and pure `shouldAutoStart(...)`. | Modify |
| `mac-app/Sources/LampControllerApp.swift` | `UIApplicationDelegateAdaptor`; `WindowGroup(id:)` with `.defaultLaunchBehavior(.suppressed)`; share the delegate's model. Remove spike hooks. | Modify |
| `mac-app/Sources/StatusItemSpike.swift` | Spike scaffold — folded into `AppKitBridge`. | Delete |
| `mac-app/project.yml` | Bump deployment to iOS 18 / macOS 15 (for `defaultLaunchBehavior`). | Modify |
| `mac-app/Tests/AppLogicTests/MenuBarControllerTests.swift` | Tests for the pure `menuModel(...)`. | Create |
| `mac-app/Tests/AppLogicTests/AppModelTests.swift` | Add `shouldAutoStart(...)` tests. | Modify |
| `mac-app/README.md`, `docs/ops/runbook.md` | Document menu-bar behavior (no Dock icon, auto-start, window optional). | Modify |

**Build command (used throughout):**
```bash
cd mac-app && xcodegen generate && \
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild -project LampController.xcodeproj -scheme LampController \
  -destination 'platform=macOS,variant=Mac Catalyst' \
  -allowProvisioningUpdates build
```

**Test command (used throughout):**
```bash
cd mac-app && xcodegen generate && \
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild -project LampController.xcodeproj -scheme LampController \
  -destination 'platform=macOS,variant=Mac Catalyst' \
  -allowProvisioningUpdates test
```

---

### Task 1: Bump deployment target to iOS 18 / macOS 15

`defaultLaunchBehavior(.suppressed)` (used in Task 8 to get no-window-on-launch) requires iOS 18 / macOS 15. The reused `LampAgent` package (iOS 17 min) is unaffected — a newer consumer is fine.

**Files:**
- Modify: `mac-app/project.yml`

- [ ] **Step 1: Bump the three deployment keys on both targets**

In `mac-app/project.yml`, for BOTH the `LampController` and `AppLogicTests` targets, change:
- `deploymentTarget: "17.0"` → `deploymentTarget: "18.0"`
- `IPHONEOS_DEPLOYMENT_TARGET: "17.0"` → `IPHONEOS_DEPLOYMENT_TARGET: "18.0"`
- `MACOSX_DEPLOYMENT_TARGET: "14.0"` → `MACOSX_DEPLOYMENT_TARGET: "15.0"`

- [ ] **Step 2: Regenerate and build**

Run the build command above.
Expected: BUILD SUCCEEDED (no source changes yet, just a deployment bump).

- [ ] **Step 3: Commit**

```bash
git add mac-app/project.yml
git commit -m "build(mac-app): raise deployment target to iOS 18 / macOS 15"
```

---

### Task 2: `AppKitBridge` — activation policy

Extract the inline `.accessory` policy flip from `LampControllerApp.init` into `AppKitBridge`, the single home for runtime ObjC. No behavior change yet (still called from the same place).

**Files:**
- Create: `mac-app/Sources/AppKitBridge.swift`
- Modify: `mac-app/Sources/LampControllerApp.swift:8-25`

- [ ] **Step 1: Create `AppKitBridge.swift` with the activation-policy function**

```swift
// AppKitBridge.swift
// The ONLY file in this app that reaches AppKit via the ObjC runtime.
// Mac Catalyst cannot `import AppKit`, so NSApplication / NSStatusBar / NSMenu
// are reached through NSClassFromString + dlsym(objc_msgSend). Everything
// objc_msgSend-shaped lives here and nowhere else.

import Foundation
import Darwin

enum AppKitBridge {
    /// objc_msgSend raw symbol (RTLD_DEFAULT == -2).
    fileprivate static let msgSend: UnsafeMutableRawPointer? =
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), "objc_msgSend")

    /// Flip the process to NSApplicationActivationPolicyAccessory (== 1):
    /// no Dock icon, no window required, and — critically — foreground-active
    /// enough for HomeKit writes to succeed.
    static func setAccessoryActivationPolicy() {
        guard
            let appClass = NSClassFromString("NSApplication") as? NSObject.Type,
            let sharedApp = appClass.value(forKey: "sharedApplication") as? NSObject,
            let sym = msgSend
        else { return }
        typealias SetPolicyFn = @convention(c) (AnyObject, Selector, Int) -> Bool
        let fn = unsafeBitCast(sym, to: SetPolicyFn.self)
        _ = fn(sharedApp, NSSelectorFromString("setActivationPolicy:"), 1)
    }
}
```

- [ ] **Step 2: Replace the inline policy code in `LampControllerApp.init`**

In `mac-app/Sources/LampControllerApp.swift`, replace the entire body of `init()` (the `if let appKitAppClass … ` block, lines 8-25) with a single call:

```swift
    init() {
        AppKitBridge.setAccessoryActivationPolicy()
    }
```

Also remove the now-unused `import Darwin` at the top of `LampControllerApp.swift` (the bridge owns it now); keep `import SwiftUI`.

- [ ] **Step 3: Build**

Run the build command.
Expected: BUILD SUCCEEDED. (The app still shows a window and runs the spike on launch — unchanged behavior for now.)

- [ ] **Step 4: Commit**

```bash
git add mac-app/Sources/AppKitBridge.swift mac-app/Sources/LampControllerApp.swift
git commit -m "feat(mac-app): AppKitBridge — isolate .accessory activation policy"
```

---

### Task 3: `AppModel.shouldAutoStart` (pure decision) — TDD

The auto-start decision is a pure function so it can be unit-tested without HomeKit. "Should we auto-start polling?" = config loaded (no error) AND HomeKit finished loading into a `.ready` state. `start()` itself re-guards the worker specifics and is idempotent, so this predicate stays minimal.

**Files:**
- Modify: `mac-app/Sources/AppModel.swift`
- Test: `mac-app/Tests/AppLogicTests/AppModelTests.swift`

- [ ] **Step 1: Write the failing tests**

Add to `mac-app/Tests/AppLogicTests/AppModelTests.swift`, inside the `AppModelTests` struct:

```swift
    @Test("shouldAutoStart: true only when config present and HomeKit ready")
    func autoStartDecision() {
        // ready + has config -> start
        #expect(AppModel.shouldAutoStart(
            hasConfig: true,
            homeKit: .ready(accessoryCount: 1, accessoryFound: true)) == true)
        // ready but accessory missing -> still start (polling logs the miss, retries)
        #expect(AppModel.shouldAutoStart(
            hasConfig: true,
            homeKit: .ready(accessoryCount: 1, accessoryFound: false)) == true)
        // denied -> no
        #expect(AppModel.shouldAutoStart(hasConfig: true, homeKit: .denied) == false)
        // still loading -> no
        #expect(AppModel.shouldAutoStart(hasConfig: true, homeKit: .loading) == false)
        // no config (parse error) -> no
        #expect(AppModel.shouldAutoStart(
            hasConfig: false,
            homeKit: .ready(accessoryCount: 1, accessoryFound: true)) == false)
    }
```

- [ ] **Step 2: Run the test to verify it fails**

Run the test command.
Expected: FAIL — `shouldAutoStart` is not defined.

- [ ] **Step 3: Add the pure function to `AppModel`**

In `mac-app/Sources/AppModel.swift`, add inside the `AppModel` class (e.g. just above `// MARK: Lifecycle`):

```swift
    /// Pure decision used by `autoStart()`. Auto-start only when config loaded
    /// and HomeKit has finished loading into a `.ready` state. `start()` re-guards
    /// worker config and is idempotent, so this stays minimal.
    static func shouldAutoStart(hasConfig: Bool, homeKit: HomeKitController.State) -> Bool {
        guard hasConfig else { return false }
        if case .ready = homeKit { return true }
        return false
    }
```

- [ ] **Step 4: Run the test to verify it passes**

Run the test command.
Expected: PASS — `autoStartDecision` green; all existing tests still green.

- [ ] **Step 5: Commit**

```bash
git add mac-app/Sources/AppModel.swift mac-app/Tests/AppLogicTests/AppModelTests.swift
git commit -m "feat(mac-app): AppModel.shouldAutoStart pure decision + tests"
```

---

### Task 4: `AppModel.autoStart()` + `onChange` notification

`autoStart()` waits for HomeKit to load, then starts if `shouldAutoStart` says so. `onChange` is a closure `MenuBarController` subscribes to so it can rebuild the menu when run/HomeKit/config state changes (the same pattern `HomeKitController.onStateChange` already uses).

**Files:**
- Modify: `mac-app/Sources/AppModel.swift`

- [ ] **Step 1: Add the `onChange` stored property and a `notify()` helper**

In `mac-app/Sources/AppModel.swift`, add after the existing stored properties (after `private var controller: HomeKitController?`):

```swift
    /// Fired whenever runState / homeKitState / configError changes, so a
    /// non-SwiftUI observer (MenuBarController) can rebuild the menu.
    var onChange: (@MainActor () -> Void)?

    private func notify() { onChange?() }
```

- [ ] **Step 2: Fire `notify()` at every state-mutation point**

Make these edits in `AppModel.swift`:

In `loadConfig()`, change the HomeKit state closure and add a trailing notify. Replace:
```swift
                c.onStateChange = { [weak self] state in self?.homeKitState = state }
```
with:
```swift
                c.onStateChange = { [weak self] state in
                    self?.homeKitState = state
                    self?.notify()
                }
```
And add `notify()` as the last line of `loadConfig()` (covers the config-loaded / configError change):
```swift
        } catch {
            config = nil
            configError = "\(error)"
        }
        notify()
    }
```

In `start()`, after `log("polling started (every \(interval)s)")`, add:
```swift
        notify()
```

In `stop()`, after `log("stopped")`, add:
```swift
        notify()
```

In `markStopped()`, change:
```swift
    private func markStopped() { if runState == .running { runState = .stopped } }
```
to:
```swift
    private func markStopped() {
        if runState == .running { runState = .stopped; notify() }
    }
```

- [ ] **Step 3: Add `autoStart()`**

In `mac-app/Sources/AppModel.swift`, add inside the `// MARK: Lifecycle` section (after `start()`):

```swift
    /// Called once at launch. Waits for HomeKit to finish loading, then starts
    /// polling if config + HomeKit are ready. `start()` is idempotent, so a menu
    /// click during this window cannot spawn a second loop.
    func autoStart() {
        Task { [weak self] in
            guard let self else { return }
            await self.homeKitController?.waitUntilLoaded()
            if AppModel.shouldAutoStart(hasConfig: self.config != nil, homeKit: self.homeKitState) {
                self.start()
            }
        }
    }
```

- [ ] **Step 4: Build**

Run the build command.
Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Run tests**

Run the test command.
Expected: PASS — all existing tests still green (no behavior regressions).

- [ ] **Step 6: Commit**

```bash
git add mac-app/Sources/AppModel.swift
git commit -m "feat(mac-app): AppModel.autoStart + onChange notification"
```

---

### Task 5: `MenuBarController.menuModel` (pure menu contents) — TDD

The menu *contents* are a pure function of state, so they're testable without AppKit. `MenuItem.action` is an enum (`.toggle/.showActivity/.quit`), not a live closure, so the result is assertable.

**Files:**
- Create: `mac-app/Sources/MenuBarController.swift`
- Test: `mac-app/Tests/AppLogicTests/MenuBarControllerTests.swift`

- [ ] **Step 1: Create `MenuBarController.swift` with just the model types + pure function**

```swift
// MenuBarController.swift
// Owns the menu-bar NSStatusItem (via AppKitBridge) and drives it from AppModel.
// The menu CONTENTS are a pure function (menuModel) so they're unit-testable
// without AppKit.

import Foundation

enum MenuActionKind: Equatable { case toggle, showActivity, quit }

struct MenuItem: Equatable {
    let title: String
    let enabled: Bool
    let action: MenuActionKind
}

struct MenuModel: Equatable {
    let statusLine: String
    let items: [MenuItem]
}

enum MenuBarMenu {
    /// Pure: maps app state to the menu contents.
    static func menuModel(
        runState: AppModel.RunState,
        homeKit: HomeKitController.State,
        configError: String?
    ) -> MenuModel {
        let statusLine: String
        if configError != nil {
            statusLine = "⚠ Config error"
        } else if homeKit == .denied {
            statusLine = "⚠ HomeKit denied"
        } else if runState == .running {
            if case .ready(_, accessoryFound: false) = homeKit {
                statusLine = "● Running · accessory not found"
            } else {
                statusLine = "● Running"
            }
        } else {
            statusLine = "○ Stopped"
        }

        // Toggle: Stop is always allowed while running; Start requires config OK
        // and HomeKit ready.
        let isReady: Bool = { if case .ready = homeKit { return true }; return false }()
        let toggle: MenuItem
        if runState == .running {
            toggle = MenuItem(title: "Stop", enabled: true, action: .toggle)
        } else {
            let canStart = configError == nil && isReady
            toggle = MenuItem(title: "Start", enabled: canStart, action: .toggle)
        }

        return MenuModel(statusLine: statusLine, items: [
            toggle,
            MenuItem(title: "Show Activity…", enabled: true, action: .showActivity),
            MenuItem(title: "Quit", enabled: true, action: .quit),
        ])
    }
}
```

- [ ] **Step 2: Write the failing tests**

Create `mac-app/Tests/AppLogicTests/MenuBarControllerTests.swift`:

```swift
import Testing
import Foundation
@testable import LampController

@Suite("MenuBarMenu.menuModel")
struct MenuBarMenuTests {
    private let ready = HomeKitController.State.ready(accessoryCount: 1, accessoryFound: true)

    @Test("running -> Stop enabled, status ● Running")
    func running() {
        let m = MenuBarMenu.menuModel(runState: .running, homeKit: ready, configError: nil)
        #expect(m.statusLine == "● Running")
        #expect(m.items[0] == MenuItem(title: "Stop", enabled: true, action: .toggle))
    }

    @Test("stopped + ready -> Start enabled, status ○ Stopped")
    func stoppedReady() {
        let m = MenuBarMenu.menuModel(runState: .stopped, homeKit: ready, configError: nil)
        #expect(m.statusLine == "○ Stopped")
        #expect(m.items[0] == MenuItem(title: "Start", enabled: true, action: .toggle))
    }

    @Test("stopped + denied -> Start disabled, status ⚠ HomeKit denied")
    func deniedDisablesStart() {
        let m = MenuBarMenu.menuModel(runState: .stopped, homeKit: .denied, configError: nil)
        #expect(m.statusLine == "⚠ HomeKit denied")
        #expect(m.items[0] == MenuItem(title: "Start", enabled: false, action: .toggle))
    }

    @Test("config error -> Start disabled, status ⚠ Config error")
    func configErrorDisablesStart() {
        let m = MenuBarMenu.menuModel(runState: .stopped, homeKit: .loading, configError: "bad toml")
        #expect(m.statusLine == "⚠ Config error")
        #expect(m.items[0].enabled == false)
    }

    @Test("running + accessory not found -> running suffix")
    func accessoryNotFound() {
        let m = MenuBarMenu.menuModel(
            runState: .running,
            homeKit: .ready(accessoryCount: 1, accessoryFound: false),
            configError: nil)
        #expect(m.statusLine == "● Running · accessory not found")
    }

    @Test("always offers Show Activity and Quit, both enabled")
    func alwaysHasShowAndQuit() {
        let m = MenuBarMenu.menuModel(runState: .stopped, homeKit: ready, configError: nil)
        #expect(m.items.contains(MenuItem(title: "Show Activity…", enabled: true, action: .showActivity)))
        #expect(m.items.contains(MenuItem(title: "Quit", enabled: true, action: .quit)))
    }
}
```

- [ ] **Step 3: Run tests to verify they pass**

Run the test command.
Expected: PASS — six `MenuBarMenuTests` green (the function from Step 1 satisfies them); existing tests still green.

- [ ] **Step 4: Commit**

```bash
git add mac-app/Sources/MenuBarController.swift mac-app/Tests/AppLogicTests/MenuBarControllerTests.swift
git commit -m "feat(mac-app): pure MenuBarMenu.menuModel + tests"
```

---

### Task 6: `AppKitBridge.StatusItem` facade

Port the proven spike logic into a clean `StatusItem` type: create the status item, set a title, and build a menu from `[Entry]`. Disabled items get no target/action — `NSMenu`'s default `autoenablesItems` greys them automatically, so we never need a `setEnabled:` signature.

**Files:**
- Modify: `mac-app/Sources/AppKitBridge.swift`

- [ ] **Step 1: Add the `StatusItem` facade and action trampoline to `AppKitBridge.swift`**

Append to `mac-app/Sources/AppKitBridge.swift` (inside the file, after the `AppKitBridge` enum):

```swift
extension AppKitBridge {
    /// One menu row. A nil `handler` (or `isSeparator`) yields a disabled/inert
    /// item — NSMenu autoenable greys items with no target/action.
    struct Entry {
        var title: String
        var handler: (() -> Void)?
        var isSeparator: Bool = false
        static func separator() -> Entry { Entry(title: "", handler: nil, isSeparator: true) }
    }

    /// @objc trampoline: NSMenuItem calls `fire`, we invoke the Swift closure.
    @objc final class ActionTarget: NSObject {
        let handler: () -> Void
        init(_ handler: @escaping () -> Void) { self.handler = handler; super.init() }
        @objc func fire() { handler() }
    }

    /// Live wrapper around an NSStatusItem created via the ObjC runtime.
    final class StatusItem {
        private let item: AnyObject
        private var menu: AnyObject?
        private var targets: [ActionTarget] = []   // keep handlers alive

        // objc_msgSend casts — confined to this type.
        private typealias MsgObj = @convention(c) (AnyObject, Selector) -> AnyObject?
        private typealias MsgObjCGFloat = @convention(c) (AnyObject, Selector, CGFloat) -> AnyObject?
        private typealias MsgVoidObj = @convention(c) (AnyObject, Selector, AnyObject?) -> Void
        private typealias MsgItem =
            @convention(c) (AnyObject, Selector, AnyObject?, Selector, AnyObject?) -> AnyObject?

        /// Returns nil if the runtime classes/symbol are unavailable.
        init?(title: String) {
            guard
                let sym = AppKitBridge.msgSend,
                let barClass = NSClassFromString("NSStatusBar")
            else { return nil }
            let msgObj = unsafeBitCast(sym, to: MsgObj.self)
            guard let bar = msgObj(barClass, NSSelectorFromString("systemStatusBar")) else { return nil }
            let msgLen = unsafeBitCast(sym, to: MsgObjCGFloat.self)
            guard let item = msgLen(bar, NSSelectorFromString("statusItemWithLength:"), -1) else { return nil }
            self.item = item
            setButtonTitle(title)
        }

        func setButtonTitle(_ title: String) {
            guard let sym = AppKitBridge.msgSend else { return }
            let msgObj = unsafeBitCast(sym, to: MsgObj.self)
            guard let button = msgObj(item, NSSelectorFromString("button")) else { return }
            let setTitle = unsafeBitCast(sym, to: MsgVoidObj.self)
            setTitle(button, NSSelectorFromString("setTitle:"), title as AnyObject)
        }

        /// Replace the menu with a fresh one built from `entries`.
        func setMenu(_ entries: [Entry]) {
            guard let sym = AppKitBridge.msgSend, let menuClass = NSClassFromString("NSMenu") else { return }
            let msgObj = unsafeBitCast(sym, to: MsgObj.self)
            guard
                let alloc = msgObj(menuClass, NSSelectorFromString("alloc")),
                let nsMenu = msgObj(alloc, NSSelectorFromString("init"))
            else { return }

            var newTargets: [ActionTarget] = []
            let addItem = unsafeBitCast(sym, to: MsgItem.self)
            let setVoidObj = unsafeBitCast(sym, to: MsgVoidObj.self)

            for entry in entries {
                if entry.isSeparator {
                    if let sepClass = NSClassFromString("NSMenuItem"),
                       let sep = msgObj(sepClass, NSSelectorFromString("separatorItem")) {
                        setVoidObj(nsMenu, NSSelectorFromString("addItem:"), sep)
                    }
                    continue
                }
                if let handler = entry.handler {
                    let target = ActionTarget(handler)
                    newTargets.append(target)
                    if let mi = addItem(
                        nsMenu, NSSelectorFromString("addItemWithTitle:action:keyEquivalent:"),
                        entry.title as AnyObject, NSSelectorFromString("fire"), "" as AnyObject) {
                        setVoidObj(mi, NSSelectorFromString("setTarget:"), target)
                    }
                } else {
                    // No handler -> no action -> autoenable greys it (label/disabled row).
                    _ = addItem(
                        nsMenu, NSSelectorFromString("addItemWithTitle:action:keyEquivalent:"),
                        entry.title as AnyObject, Selector(("")), "" as AnyObject)
                }
            }

            let setMenu = unsafeBitCast(sym, to: MsgVoidObj.self)
            setMenu(item, NSSelectorFromString("setMenu:"), nsMenu)
            self.menu = nsMenu
            self.targets = newTargets
        }
    }
}
```

- [ ] **Step 2: Build**

Run the build command.
Expected: BUILD SUCCEEDED. (Nothing constructs `StatusItem` yet — that's Task 7.)

- [ ] **Step 3: Commit**

```bash
git add mac-app/Sources/AppKitBridge.swift
git commit -m "feat(mac-app): AppKitBridge.StatusItem facade (port from spike)"
```

---

### Task 7: `MenuBarController` live wiring

Wire the controller to its `StatusItem`: install it, rebuild the menu from `menuModel` on every `AppModel.onChange`, and perform clicks. The status line is the first (disabled) row; window open uses UIKit's scene activation (no AppKit). If the status item can't be created, fall back to opening the window so the app isn't invisible.

**Files:**
- Modify: `mac-app/Sources/MenuBarController.swift`

- [ ] **Step 1: Add the live controller class to `MenuBarController.swift`**

Append to `mac-app/Sources/MenuBarController.swift` (add `import UIKit` at the top of the file alongside `import Foundation`):

```swift
@MainActor
final class MenuBarController {
    private let model: AppModel
    private var statusItem: AppKitBridge.StatusItem?

    init(model: AppModel) {
        self.model = model
        statusItem = AppKitBridge.StatusItem(title: "💡")
        if statusItem == nil {
            // Defensive: no menu-bar surface -> at least show the window.
            Self.showActivityWindow()
        }
        model.onChange = { [weak self] in self?.rebuild() }
        rebuild()
    }

    private func rebuild() {
        guard let statusItem else { return }
        let m = MenuBarMenu.menuModel(
            runState: model.runState,
            homeKit: model.homeKitState,
            configError: model.configError)

        var entries: [AppKitBridge.Entry] = [
            AppKitBridge.Entry(title: m.statusLine, handler: nil),  // disabled label
            .separator(),
        ]
        for item in m.items {
            let handler: (() -> Void)? = item.enabled
                ? { [weak self] in self?.perform(item.action) }
                : nil
            entries.append(AppKitBridge.Entry(title: item.title, handler: handler))
        }
        statusItem.setMenu(entries)
    }

    private func perform(_ action: MenuActionKind) {
        switch action {
        case .toggle:
            if model.runState == .running { model.stop() } else { model.start() }
        case .showActivity:
            Self.showActivityWindow()
        case .quit:
            model.stop()
            exit(0)
        }
    }

    /// Open (or focus) the Activity window via the UIKit scene API — Catalyst can
    /// import UIKit, so no AppKit runtime needed for windows.
    static func showActivityWindow() {
        let options = UIScene.ActivationRequestOptions()
        UIApplication.shared.requestSceneSessionActivation(
            nil, userActivity: nil, options: options, errorHandler: nil)
    }
}
```

- [ ] **Step 2: Build**

Run the build command.
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Run tests**

Run the test command.
Expected: PASS — all tests green (the pure `menuModel` tests still pass; the live class isn't unit-tested).

- [ ] **Step 4: Commit**

```bash
git add mac-app/Sources/MenuBarController.swift
git commit -m "feat(mac-app): MenuBarController live wiring (status item + menu + actions)"
```

---

### Task 8: `AppDelegate` bootstrap + suppressed launch window

Move launch-time setup into a `UIApplicationDelegate` (runs after launch with the run loop active — the right place to install the status item and set the policy). Suppress the launch window so the app is menu-bar-only; the window opens only from the menu.

**Files:**
- Create: `mac-app/Sources/AppDelegate.swift`
- Modify: `mac-app/Sources/LampControllerApp.swift`

- [ ] **Step 1: Create `AppDelegate.swift`**

```swift
import UIKit

/// Launch bootstrap. Owns the single AppModel and the MenuBarController.
/// didFinishLaunching runs with the run loop active — the correct place to set
/// the activation policy and install the status item.
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    let model = AppModel()
    private var menuBar: MenuBarController?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        AppKitBridge.setAccessoryActivationPolicy()
        model.loadConfig()
        menuBar = MenuBarController(model: model)
        model.autoStart()
        return true
    }
}
```

- [ ] **Step 2: Rewrite `LampControllerApp.swift` to use the delegate + suppressed window**

Replace the entire contents of `mac-app/Sources/LampControllerApp.swift` with:

```swift
import SwiftUI

@main
struct LampControllerApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup(id: "activity") {
            ContentView(model: appDelegate.model)
                .frame(minWidth: 420, minHeight: 360)
        }
        .defaultLaunchBehavior(.suppressed)   // menu-bar-only: no window at launch
    }
}
```

Note: the activation policy now lives in `AppDelegate.didFinishLaunching` (Step 1), so it is no longer called from the `App` initializer. `loadConfig()` and the status-item install also move there. The spike's `onAppear` hooks and `LAMP_SPIKE_AUTOSTART` are gone.

- [ ] **Step 3: Build**

Run the build command.
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
git add mac-app/Sources/AppDelegate.swift mac-app/Sources/LampControllerApp.swift
git commit -m "feat(mac-app): AppDelegate bootstrap + suppressed launch window"
```

---

### Task 9: Delete the spike scaffold

`StatusItemSpike.swift` is fully superseded by `AppKitBridge` + `MenuBarController`. Remove it.

**Files:**
- Delete: `mac-app/Sources/StatusItemSpike.swift`

- [ ] **Step 1: Delete the file**

```bash
git rm mac-app/Sources/StatusItemSpike.swift
```

- [ ] **Step 2: Verify no references remain**

Run: `grep -rn "StatusItemSpike\|LAMP_SPIKE_AUTOSTART" mac-app/Sources mac-app/Tests`
Expected: no output (no remaining references).

- [ ] **Step 3: Build + test**

Run the build command, then the test command.
Expected: BUILD SUCCEEDED; all tests PASS.

- [ ] **Step 4: Commit**

```bash
git add -A mac-app/Sources
git commit -m "chore(mac-app): remove StatusItemSpike scaffold (folded into AppKitBridge)"
```

---

### Task 10: Update docs

Reflect the menu-bar behavior in the README and ops runbook: no Dock icon, auto-starts on launch, controlled from the menu-bar item, window is optional.

**Files:**
- Modify: `mac-app/README.md`
- Modify: `docs/ops/runbook.md`

- [ ] **Step 1: Update `mac-app/README.md`**

In `mac-app/README.md`, update the run/behavior description to state:
- The app runs as a **menu-bar app**: a lamp icon (💡) appears in the macOS menu bar, with **no Dock icon** and **no window on launch**.
- It **auto-starts polling** when launched (if config + HomeKit are ready).
- The menu offers **Start/Stop**, **Show Activity…** (opens the activity window), and **Quit**.
- **Closing the Activity window does not quit** the app — polling continues; use **Quit** from the menu to exit.
- To run at macOS login, add the app to **System Settings → General → Login Items** (manual for v1).

Keep the existing `xcodegen generate` / `xcodebuild` build instructions.

- [ ] **Step 2: Update `docs/ops/runbook.md`**

In the "Architecture note" section (lines ~5-11), replace the sentence:
> There is no launchd daemon for the lamp agent — the app must be open and running (showing the **Stop** button / running indicator).

with:
> There is no launchd daemon for the lamp agent — the app runs as a **menu-bar app** (lamp icon in the menu bar, no Dock icon) and **auto-starts polling** on launch. It must be running; check the menu-bar icon → the menu shows **● Running**. Use **Stop**/**Start** in that menu to control polling and **Quit** to exit.

In the "Common checks" section, replace the "Is the Lamp Controller app running?" bullet with:
> - **Is the Lamp Controller app running?** Look for the 💡 icon in the menu bar on the home Mac; its menu should show **● Running**. If the icon is absent, the app was quit — relaunch it (it auto-starts). If it shows **○ Stopped**, click **Start**.

- [ ] **Step 3: Commit**

```bash
git add mac-app/README.md docs/ops/runbook.md
git commit -m "docs: describe menu-bar app behavior (no dock icon, auto-start, optional window)"
```

---

### Task 11: Live verification (manual — the demoable)

This is the `lamp-integration-verifier` end-of-stage scenario adapted to the menu-bar surface. Run it against the real lamp.

**Files:** none (manual run).

- [ ] **Step 1: Build and launch**

Run the build command, then launch the built app (open it from `~/Library/Developer/Xcode/DerivedData/.../LampController.app`, or ⌘R from Xcode).
Expected: a 💡 icon appears in the menu bar; **no Dock icon**; **no window** opens.

- [ ] **Step 2: Verify auto-start**

Click the 💡 menu.
Expected: status line reads **● Running** within a few seconds of launch.

- [ ] **Step 3: Send a command and watch the lamp**

```bash
COMMAND_JSON='{"id":"verify-menubar","action":"on","brightness":40,"color_temp_k":2700,"created_at":"'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'","source_msg_id":"manual"}'
wrangler kv key put "command:verify-menubar" "$COMMAND_JSON" \
  --namespace-id a0a047d07dd44a07bb0b103b48c75410
```
Expected: within one poll interval (~12s) the lamp turns on warm at 40%. Open **Show Activity…** from the menu → the activity log shows the applied command with a timestamp.

- [ ] **Step 4: Toggle Stop/Start**

From the menu, click **Stop** → status flips to **○ Stopped**, polling halts. Click **Start** → back to **● Running**.

- [ ] **Step 5: Verify window-close ≠ quit**

Close the Activity window. Click the 💡 menu again.
Expected: app still alive, status still **● Running** (polling continued headless). Re-open via **Show Activity…** → window returns.

- [ ] **Step 6: Quit**

Click **Quit** from the menu.
Expected: the 💡 icon disappears and the process exits.

- [ ] **Step 7: Record the result**

If all steps pass, the stage is demoable. If `defaultLaunchBehavior(.suppressed)` or scene activation misbehaves on this macOS version, note it — fallback is to drop `.suppressed` (window shows on launch but is closeable), which still satisfies the core goals (menu-bar control, no Dock icon, auto-start, background run).

---

## Self-review

**Spec coverage:**
- Architecture (AppKitBridge sole runtime-cast home; MenuBarController; reuse) → Tasks 2, 5, 6, 7 ✓
- `.accessory` policy → Task 2 ✓
- NSStatusItem via runtime ObjC → Task 6 ✓
- Auto-start on launch (waits for HomeKit load, idempotent) → Tasks 3, 4 ✓
- Menu contents + status lines + enable rules → Task 5 ✓
- Window optional / open from menu / close ≠ quit / no window on launch → Tasks 7, 8, 11 ✓
- NSStatusItem-creation fallback → Task 7 (`init?` + `showActivityWindow`) ✓
- Delete spike scaffold + remove autostart hook → Tasks 8, 9 ✓
- Testing: pure `menuModel` + `shouldAutoStart`; core unchanged → Tasks 3, 5 ✓
- Docs (README + runbook) → Task 10 ✓
- Live verification (demoable) → Task 11 ✓

**Placeholder scan:** No TBD/TODO; every code step shows full code; the one runtime risk (`.suppressed`/scene activation) has an explicit fallback in Task 11 Step 7.

**Type consistency:** `MenuItem`/`MenuActionKind`/`MenuModel`/`MenuBarMenu.menuModel` used identically in Tasks 5 & 7. `AppKitBridge.Entry`/`StatusItem`/`ActionTarget` defined in Task 6, consumed in Task 7. `AppModel.shouldAutoStart(hasConfig:homeKit:)` signature matches between Tasks 3, 4. `HomeKitController.State.ready(accessoryCount:accessoryFound:)` matches the real enum. `onChange` / `autoStart()` / `notify()` consistent across Tasks 4, 7, 8.
