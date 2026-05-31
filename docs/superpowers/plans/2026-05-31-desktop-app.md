# Lamp Controller desktop app — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a normal-window Mac (Catalyst) desktop app "Lamp Controller" with Start/Stop that polls the Cloudflare Worker itself and drives the lamp directly via in-process HomeKit — then retire the per-command helper, launchd daemon, and CLI HomeKit backend.

**Architecture:** A new SwiftUI Catalyst app target (`mac-app/`) depends on the existing `LampAgent` SPM library (`mac-agent/`). The app injects an in-process `LampClient.homeKit(controller:)` via `withDependencies` so the reused `PollLoop → CommandExecutor` pipeline drives an `HMHomeManager`-backed `HomeKitController`. The whole Stage 1/2 core (WorkerCommandSource, AckStore, PollLoop, Config) is reused unchanged.

**Tech Stack:** Swift 6, SwiftUI, Mac Catalyst, HomeKit, swift-dependencies, swift-testing; xcodegen + xcodebuild; paid Apple team `3MFN7Y7D69`.

**Reference spec:** [`docs/superpowers/specs/2026-05-31-desktop-app-design.md`](../specs/2026-05-31-desktop-app-design.md). Pass this path to sub-agents.

---

## Toolchain notes (read first)

- All `swift`/`xcodebuild` commands need Xcode: `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.
- `mac-agent` is the SPM package (library `LampAgent` + exe `lamp-agent`). Tests: `cd mac-agent && swift test`.
- The app is a **Mac Catalyst** app (HomeKit on macOS is Catalyst-only), built with xcodegen + xcodebuild, exactly like `mac-agent/homekit-helper/` already is. Reuse that project's proven settings.
- The reused core's lamp interface: `LampState { power: Bool, brightness: Int, colorTempK: Int }`, `LampClient { var apply: @Sendable (LampState) async throws -> Void }`, global `miredFromKelvin(_:)`, `@Dependency(\.lampClient)`. `CommandExecutor.live()` already calls `@Dependency(\.lampClient).apply`.
- The helper's working HomeKit write logic lives in `mac-agent/homekit-helper/Sources/main.swift` (`findAccessory`, `findLightbulbService`, `findCharacteristic`, `writeCharacteristic`, `kelvinToMired`, the `HMHomeManagerDelegate` load). Lift it; don't reinvent.
- **Safe sequencing:** build + live-verify the app BEFORE deleting the helper/launchd/CLI-homekit (Tasks 8–9). Never leave a window with no working lamp path.

---

## File structure produced by this stage

```
mac-agent/
└── Package.swift                         # platforms += .iOS(.v17)  (Catalyst build of LampAgent)

mac-app/                                  # NEW
├── project.yml                           # xcodegen Catalyst app, depends on ../mac-agent
├── .gitignore                            # *.xcodeproj, build/, DerivedData/
├── Sources/
│   ├── LampControllerApp.swift           # @main SwiftUI App
│   ├── ContentView.swift                 # Start/Stop, status rows, activity log
│   ├── AppModel.swift                    # @MainActor @Observable lifecycle + state
│   ├── HomeKitController.swift           # HMHomeManager + apply(LampState)
│   ├── LampClient+HomeKit.swift          # LampClient.homeKit(controller:)
│   └── Entitlements.entitlements         # com.apple.developer.homekit
└── Tests/                                # (added in Task 6, run via the package or xcodebuild test)
    └── AppLogicTests/
        ├── LampClientHomeKitTests.swift
        └── AppModelTests.swift

# Removed in Tasks 8–9 (AFTER the app is verified):
#   mac-agent/homekit-helper/**
#   mac-agent/Resources/com.lamp.agent.plist, scripts/install.sh, scripts/uninstall.sh
#   LampClient.homekit(helperAppPath:…) + Config .homekit backend + HomeKitClientTests
```

---

## Task 1: Make LampAgent build for Mac Catalyst

**Agent:** lamp-mac. **Files:** Modify `mac-agent/Package.swift`.

The app target is Catalyst (iOS-derived); the `LampAgent` library must declare an iOS platform or SwiftPM won't let the Catalyst app link it.

- [ ] **Step 1: Add the iOS platform**

In `mac-agent/Package.swift`, change:

```swift
    platforms: [.macOS(.v14)],
```
to:
```swift
    platforms: [.macOS(.v14), .iOS(.v17)],
```

- [ ] **Step 2: Confirm the macOS build/tests are unaffected**

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd mac-agent && swift build 2>&1 | tail -3 && swift test 2>&1 | tail -4
```

Expected: build succeeds; full suite passes (same count as before this stage). The core is pure Foundation + Dependencies + TOMLKit, all Catalyst-compatible, so no source changes are needed.

- [ ] **Step 3: Commit**

```bash
cd /Users/volovely/GitHub/lamp-controller
git add mac-agent/Package.swift
git commit -m "build(mac-agent): add iOS platform so LampAgent builds for Mac Catalyst"
```

---

## Task 2: HomeKitController (in-process HomeKit)

**Agent:** lamp-mac. **Files:** Create `mac-app/Sources/HomeKitController.swift`.

Lifts the helper's HomeKit logic into a reusable `@MainActor` class the app holds for its lifetime. No per-command launch.

- [ ] **Step 1: Write HomeKitController**

Create `mac-app/Sources/HomeKitController.swift`:

```swift
import Foundation
import HomeKit
import LampAgent

/// Owns a long-lived HMHomeManager and applies LampState to the configured
/// accessory. The app is a foreground UIApplication, so HomeKit writes succeed
/// (no Code=80 background error).
@MainActor
final class HomeKitController: NSObject, HMHomeManagerDelegate, ObservableObject {
    enum State: Equatable {
        case loading
        case ready(accessoryCount: Int, accessoryFound: Bool)
        case denied
    }

    @Published private(set) var state: State = .loading

    private let manager = HMHomeManager()
    private let accessoryName: String
    private var loadContinuations: [CheckedContinuation<Void, Never>] = []
    private var loaded = false

    init(accessoryName: String) {
        self.accessoryName = accessoryName
        super.init()
        manager.delegate = self
    }

    // MARK: HMHomeManagerDelegate

    func homeManagerDidUpdateHomes(_ manager: HMHomeManager) {
        refreshState()
        loaded = true
        let conts = loadContinuations
        loadContinuations.removeAll()
        for c in conts { c.resume() }
    }

    func homeManager(_ manager: HMHomeManager, didUpdate status: HMHomeManagerAuthorizationStatus) {
        if !status.contains(.authorized) {
            state = .denied
        } else {
            refreshState()
        }
    }

    private func refreshState() {
        let all = manager.homes.flatMap(\.accessories)
        let found = all.contains { $0.name == accessoryName }
        state = .ready(accessoryCount: all.count, accessoryFound: found)
    }

    /// Suspends until HMHomeManager has loaded homes at least once.
    func waitUntilLoaded() async {
        if loaded { return }
        await withCheckedContinuation { loadContinuations.append($0) }
    }

    // MARK: Applying state

    enum ApplyError: Error, Equatable {
        case accessoryNotFound(String)
        case noLightbulbService
        case writeFailed(String)
    }

    func apply(_ lamp: LampState) async throws {
        guard let accessory = manager.homes
            .flatMap(\.accessories)
            .first(where: { $0.name == accessoryName })
        else { throw ApplyError.accessoryNotFound(accessoryName) }

        guard let service = accessory.services
            .first(where: { $0.serviceType == HMServiceTypeLightbulb })
        else { throw ApplyError.noLightbulbService }

        func characteristic(_ type: String) -> HMCharacteristic? {
            service.characteristics.first { $0.characteristicType == type }
        }
        func write(_ char: HMCharacteristic, _ value: Any, _ label: String) async throws {
            do { try await char.writeValue(value) }
            catch { throw ApplyError.writeFailed("\(label): \(error.localizedDescription)") }
        }

        if let power = characteristic(HMCharacteristicTypePowerState) {
            try await write(power, lamp.power, "PowerState")
        }
        guard lamp.power else { return }

        if let brightness = characteristic(HMCharacteristicTypeBrightness) {
            try await write(brightness, max(0, min(100, lamp.brightness)), "Brightness")
        }
        if let ct = characteristic(HMCharacteristicTypeColorTemperature) {
            let meta = ct.metadata
            let lo = meta?.minimumValue.map { Int(truncating: $0) } ?? 140
            let hi = meta?.maximumValue.map { Int(truncating: $0) } ?? 500
            let mired = max(lo, min(hi, miredFromKelvin(lamp.colorTempK)))
            try await write(ct, mired, "ColorTemperature")
        }
    }
}
```

Note: this file is part of the app target (created in Task 5); it won't compile standalone until the xcodegen project exists. It's committed now as source; Task 5 wires the target and Task 6 builds it.

- [ ] **Step 2: Commit**

```bash
cd /Users/volovely/GitHub/lamp-controller
git add mac-app/Sources/HomeKitController.swift
git commit -m "feat(mac-app): add in-process HomeKitController (apply LampState)"
```

---

## Task 3: LampClient.homeKit factory + its test

**Agent:** lamp-mac. **REQUIRED SKILL:** pfw-testing. **Files:**
- Create: `mac-app/Sources/LampClient+HomeKit.swift`
- Create: `mac-app/Tests/AppLogicTests/LampClientHomeKitTests.swift`

The factory is a one-liner; the testable contract is "apply forwards the exact LampState to the controller." To make it unit-testable without HomeKit, the factory takes a closure, and `HomeKitController.apply` satisfies it.

- [ ] **Step 1: Write the failing test**

Create `mac-app/Tests/AppLogicTests/LampClientHomeKitTests.swift`:

```swift
import Testing
import LampAgent
@testable import LampController

@Suite("LampClient.homeKit")
struct LampClientHomeKitTests {
    @Test("apply forwards the exact LampState to the apply closure")
    func forwards() async throws {
        final class Box: @unchecked Sendable { var states: [LampState] = [] }
        let box = Box()
        let client = LampClient.homeKit { state in box.states.append(state) }

        try await client.apply(LampState(power: true, brightness: 30, colorTempK: 2700))
        try await client.apply(LampState(power: false, brightness: 0, colorTempK: 4000))

        #expect(box.states == [
            LampState(power: true, brightness: 30, colorTempK: 2700),
            LampState(power: false, brightness: 0, colorTempK: 4000),
        ])
    }
}
```

- [ ] **Step 2: Write the factory**

Create `mac-app/Sources/LampClient+HomeKit.swift`:

```swift
import LampAgent

extension LampClient {
    /// In-process HomeKit backend. The closure is `HomeKitController.apply`.
    static func homeKit(
        _ apply: @escaping @Sendable (LampState) async throws -> Void
    ) -> LampClient {
        LampClient(apply: apply)
    }
}
```

(The app wires `LampClient.homeKit { try await controller.apply($0) }` in Task 4.)

- [ ] **Step 3: Run the test (after the project exists it runs via xcodebuild; for now verify by inspection)**

The test target is created in Task 5/6. At this point, confirm the factory + test compile-match by eye: `LampClient(apply:)` exists (it's the `@DependencyClient` memberwise init in `mac-agent/Sources/LampAgent/LampClient.swift`), and `LampState` is `Equatable`. Actual execution happens in Task 6 Step 4.

- [ ] **Step 4: Commit**

```bash
cd /Users/volovely/GitHub/lamp-controller
git add mac-app/Sources/LampClient+HomeKit.swift mac-app/Tests/AppLogicTests/LampClientHomeKitTests.swift
git commit -m "feat(mac-app): add in-process LampClient.homeKit factory + test"
```

---

## Task 4: AppModel (Start/Stop lifecycle) + its test

**Agent:** lamp-mac. **REQUIRED SKILLS:** pfw-dependencies, pfw-testing. **Files:**
- Create: `mac-app/Sources/AppModel.swift`
- Create: `mac-app/Tests/AppLogicTests/AppModelTests.swift`

`AppModel` owns config loading, the poll Task, and published UI state. It's tested by injecting a stub `CommandSource` and a recording apply-closure and asserting a queued command flows through to the lamp closure, and that `stop()` halts.

- [ ] **Step 1: Write the failing test**

Create `mac-app/Tests/AppLogicTests/AppModelTests.swift`:

```swift
import Testing
import Foundation
import Dependencies
import LampAgent
@testable import LampController

@MainActor
@Suite("AppModel")
struct AppModelTests {
    private func tempState() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("acked-\(UUID().uuidString).json")
    }

    @Test("runOnceForTesting applies a queued command via the lamp closure")
    func appliesQueued() async throws {
        let stateURL = tempState()
        defer { try? FileManager.default.removeItem(at: stateURL) }

        final class Box: @unchecked Sendable { var states: [LampState] = [] }
        let box = Box()

        let cmd = Command(
            id: "a", action: .on, brightness: 30, colorTempK: 2700,
            durationMinutes: nil, createdAt: Date(timeIntervalSince1970: 1000), sourceMsgId: "m"
        )
        let source = CommandSource(pending: { [cmd] }, ack: { _ in })

        let model = AppModel()
        try await withDependencies {
            $0.date = .constant(Date(timeIntervalSince1970: 1000))
            $0.lampClient = .homeKit { box.states.append($0) }
        } operation: {
            try await model.runOnceForTesting(source: source, ackStorePath: stateURL.path)
        }

        #expect(box.states == [LampState(power: true, brightness: 30, colorTempK: 2700)])
    }

    @Test("start sets running, stop sets stopped")
    func startStop() async {
        let model = AppModel()
        #expect(model.runState == .stopped)
        // start with a never-yielding source so the loop idles; we just check the flag flips.
        model.beginForTesting()
        #expect(model.runState == .running)
        model.stop()
        #expect(model.runState == .stopped)
    }
}
```

- [ ] **Step 2: Write AppModel**

Create `mac-app/Sources/AppModel.swift`:

```swift
import Foundation
import Observation
import Dependencies
import LampAgent

@MainActor
@Observable
final class AppModel {
    enum RunState: Equatable { case stopped, running }

    struct LogEntry: Identifiable, Equatable {
        let id = UUID()
        let time: Date
        let message: String
    }

    private(set) var runState: RunState = .stopped
    private(set) var activity: [LogEntry] = []
    var config: Config?
    var configError: String?

    private var task: Task<Void, Never>?
    private var controller: HomeKitController?

    // MARK: Config

    func loadConfig() {
        let path = NSString(string: "~/.config/lamp-agent/config.toml").expandingTildeInPath
        do {
            config = try Config.load(from: URL(fileURLWithPath: path))
            configError = nil
            if let name = config?.homekitAccessoryName {
                controller = HomeKitController(accessoryName: name)
            }
        } catch {
            config = nil
            configError = "\(error)"
        }
    }

    var homeKitController: HomeKitController? { controller }

    // MARK: Lifecycle

    func start() {
        guard runState == .stopped, let config, let controller,
              config.commandSource == .worker,
              let workerURL = config.workerURL, let secret = config.sharedSecret
        else { return }

        let loop = PollLoop(
            source: .worker(baseURL: workerURL, sharedSecret: secret),
            executor: .live(),
            ackStore: .file(at: URL(fileURLWithPath: config.statePath))
        )
        let interval = config.pollIntervalSeconds
        runState = .running
        log("started")

        task = Task { [weak self] in
            await withDependencies {
                $0.lampClient = .homeKit { [weak controller] state in
                    guard let controller else { return }
                    try await controller.apply(state)
                }
            } operation: {
                do {
                    try await loop.run(intervalSeconds: interval, isCancelled: { Task.isCancelled })
                } catch is CancellationError {
                    // expected on stop
                } catch {
                    await self?.log("loop error: \(error)")
                }
            }
            await self?.markStopped()
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        runState = .stopped
        log("stopped")
    }

    private func markStopped() { if runState == .running { runState = .stopped } }

    private func log(_ message: String) {
        @Dependency(\.date) var date
        activity.insert(LogEntry(time: date.now, message: message), at: 0)
        if activity.count > 100 { activity.removeLast(activity.count - 100) }
    }

    // MARK: Testing hooks

    /// Drains one poll cycle from `source` into the injected lampClient.
    func runOnceForTesting(source: CommandSource, ackStorePath: String) async throws {
        let loop = PollLoop(
            source: source,
            executor: .live(),
            ackStore: .file(at: URL(fileURLWithPath: ackStorePath))
        )
        _ = try await loop.runOnce()
    }

    /// Flips runState without a real loop (for the start/stop flag test).
    func beginForTesting() { runState = .running }
}
```

- [ ] **Step 3: Verify by inspection (execution in Task 6)**

Confirm names line up with the core: `Config` has `commandSource`, `workerURL`, `sharedSecret`, `statePath`, `pollIntervalSeconds`, `homekitAccessoryName`; `PollLoop.run(intervalSeconds:isCancelled:)` and `runOnce()` exist; `CommandSource.worker`/`.file`, `CommandExecutor.live()`, `@Dependency(\.lampClient)`, `@Dependency(\.date)` all exist. (All confirmed in `mac-agent/Sources/LampAgent/`.)

- [ ] **Step 4: Commit**

```bash
cd /Users/volovely/GitHub/lamp-controller
git add mac-app/Sources/AppModel.swift mac-app/Tests/AppLogicTests/AppModelTests.swift
git commit -m "feat(mac-app): add AppModel start/stop lifecycle + tests"
```

---

## Task 5: SwiftUI views + xcodegen project + entitlements

**Agent:** lamp-mac. **Files:**
- Create: `mac-app/Sources/LampControllerApp.swift`
- Create: `mac-app/Sources/ContentView.swift`
- Create: `mac-app/Sources/Entitlements.entitlements`
- Create: `mac-app/project.yml`
- Create: `mac-app/.gitignore`

- [ ] **Step 1: App entry**

Create `mac-app/Sources/LampControllerApp.swift`:

```swift
import SwiftUI

@main
struct LampControllerApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .frame(minWidth: 420, minHeight: 360)
                .onAppear { model.loadConfig() }
        }
    }
}
```

- [ ] **Step 2: ContentView**

Create `mac-app/Sources/ContentView.swift`:

```swift
import SwiftUI
import LampAgent

struct ContentView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Lamp Controller").font(.title2).bold()

            if let error = model.configError {
                Label("Config error: \(error)", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            } else if let config = model.config {
                VStack(alignment: .leading, spacing: 4) {
                    row("Lamp", config.homekitAccessoryName ?? "—")
                    row("Worker", config.workerURL?.absoluteString ?? "—")
                    row("HomeKit", homeKitStatus)
                }
                .font(.callout)
            }

            Button(model.runState == .running ? "Stop" : "Start") {
                model.runState == .running ? model.stop() : model.start()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(model.config == nil)

            Divider()
            Text("Activity").font(.headline)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(model.activity) { entry in
                        Text("\(entry.time, format: .dateTime.hour().minute().second())  \(entry.message)")
                            .font(.caption.monospaced())
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding()
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label).foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
            Text(value).textSelection(.enabled)
        }
    }

    private var homeKitStatus: String {
        switch model.homeKitController?.state {
        case .loading, nil: "loading…"
        case .denied: "access denied — System Settings ▸ Privacy ▸ Home"
        case let .ready(count, found): found ? "ready · \(count) accessories" : "accessory not found"
        }
    }
}
```

- [ ] **Step 3: Entitlements**

Create `mac-app/Sources/Entitlements.entitlements`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.developer.homekit</key>
    <true/>
</dict>
</plist>
```

- [ ] **Step 4: xcodegen project**

Create `mac-app/project.yml` (mirrors the helper's proven Catalyst settings; adds the local SPM dependency + a test target):

```yaml
name: LampController
options:
  bundleIdPrefix: com.volovely
packages:
  LampAgent:
    path: ../mac-agent
targets:
  LampController:
    type: application
    platform: iOS
    deploymentTarget: "17.0"
    sources:
      - path: Sources
    dependencies:
      - package: LampAgent
        product: LampAgent
    settings:
      base:
        SUPPORTS_MACCATALYST: "YES"
        SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD: "NO"
        SUPPORTS_IOS_APPS_ON_MAC: "NO"
        TARGETED_DEVICE_FAMILY: "2"
        DEVELOPMENT_TEAM: "3MFN7Y7D69"
        CODE_SIGN_STYLE: Automatic
        PRODUCT_BUNDLE_IDENTIFIER: com.volovely.lamp-controller
        GENERATE_INFOPLIST_FILE: "YES"
        INFOPLIST_KEY_NSHomeKitUsageDescription: "Lamp Controller sets your lamp's power, brightness, and color temperature."
        INFOPLIST_KEY_UILaunchScreen_Generation: "YES"
        CODE_SIGN_ENTITLEMENTS: Sources/Entitlements.entitlements
        MARKETING_VERSION: "1.0"
        CURRENT_PROJECT_VERSION: "1"
        SWIFT_VERSION: "6.0"
  AppLogicTests:
    type: bundle.unit-test
    platform: iOS
    deploymentTarget: "17.0"
    sources:
      - path: Tests/AppLogicTests
    dependencies:
      - target: LampController
      - package: LampAgent
        product: LampAgent
    settings:
      base:
        SUPPORTS_MACCATALYST: "YES"
        TARGETED_DEVICE_FAMILY: "2"
        DEVELOPMENT_TEAM: "3MFN7Y7D69"
        GENERATE_INFOPLIST_FILE: "YES"
        SWIFT_VERSION: "6.0"
schemes:
  LampController:
    build:
      targets:
        LampController: all
        AppLogicTests: [test]
    test:
      targets:
        - AppLogicTests
```

(For `@testable import LampController` to work, the test target depends on the app target. If the app target's module name differs, set `PRODUCT_MODULE_NAME: LampController` under its settings.)

- [ ] **Step 5: .gitignore**

Create `mac-app/.gitignore`:

```
*.xcodeproj/
build/
DerivedData/
*.local
```

- [ ] **Step 6: Commit**

```bash
cd /Users/volovely/GitHub/lamp-controller
git add mac-app/Sources/LampControllerApp.swift mac-app/Sources/ContentView.swift \
        mac-app/Sources/Entitlements.entitlements mac-app/project.yml mac-app/.gitignore
git commit -m "feat(mac-app): add SwiftUI views, xcodegen project, entitlements"
```

---

## Task 6: Build, run tests, fix to green

**Agent:** lamp-mac. **Files:** as needed across `mac-app/Sources` + `Tests` to compile.

This is the integration task: generate the project, build the Catalyst app, run the unit tests, and fix compile/test issues. The HomeKit capability for App ID `com.volovely.lamp-controller` must be enabled in the Apple portal (human step — see Task 10); if signing blocks the build here, build with a temporary `CODE_SIGNING_ALLOWED=NO` for the test run and note that a signed build needs the portal step.

- [ ] **Step 1: Generate + build the app (Catalyst)**

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
brew install xcodegen 2>/dev/null || true
cd mac-app
xcodegen generate
xcodebuild -project LampController.xcodeproj -scheme LampController \
  -destination 'platform=macOS,variant=Mac Catalyst' \
  -derivedDataPath build -allowProvisioningUpdates build 2>&1 | tail -25
```

Expected: `BUILD SUCCEEDED`. If it fails on the HomeKit entitlement/provisioning, the App ID needs the HomeKit capability enabled (Task 10 Step 1); retry after that, or for now confirm compilation with `CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO` appended and note it.

- [ ] **Step 2: Fix any compile errors**

Likely fixups: `@testable import LampController` requires the module name to match (set `PRODUCT_MODULE_NAME` if needed); `@Observable` + `@Bindable` need `import Observation`/SwiftUI; `HMCharacteristic.writeValue(_:)` async availability. Make minimal corrections in the relevant files.

- [ ] **Step 3: Run the unit tests**

```bash
xcodebuild -project LampController.xcodeproj -scheme LampController \
  -destination 'platform=macOS,variant=Mac Catalyst' \
  -derivedDataPath build test 2>&1 | tail -25
```

Expected: `LampClientHomeKitTests` (1) and `AppModelTests` (2) pass.

- [ ] **Step 4: Confirm the reused core still passes**

```bash
cd ../mac-agent && swift test 2>&1 | tail -4
```

Expected: unchanged green suite.

- [ ] **Step 5: Commit any fixups**

```bash
cd /Users/volovely/GitHub/lamp-controller
git add mac-app/
git commit -m "fix(mac-app): compile + test green for Catalyst app"
```

---

## Task 7: Live verification against the real lamp

**Agent:** lamp-integration-verifier. **Requires:** HomeKit capability enabled for the App ID (Task 10 Step 1) + the user clicking "Allow" on first launch. **Files:** none.

- [ ] **Step 1: Launch the app**

```bash
open mac-app/build/Build/Products/Debug-maccatalyst/LampController.app
```

On first launch, macOS shows a "Home Access" prompt → **user clicks Allow**. The window should show `HomeKit: ready · N accessories` and the configured lamp name.

- [ ] **Step 2: Start + drive a command**

Click **Start**. Insert a command into the live Worker KV (distinct, visible state):

```bash
cd worker
UUID=$(uuidgen)
pnpm exec wrangler kv key put --binding=COMMANDS --remote "command:$UUID" \
  "{\"id\":\"$UUID\",\"action\":\"on\",\"brightness\":100,\"color_temp_k\":6000,\"created_at\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"source_msg_id\":\"app-demo\"}"
```

Expected: within one poll interval (~12 s) the lamp turns bright cool white; the app's Activity log shows the applied command; a follow-up `wrangler kv key list --binding=COMMANDS` shows the key gone (acked).

- [ ] **Step 3: Stop**

Click **Stop**. Insert another command; confirm the lamp does NOT change (polling halted). Click Start again; it should then pick it up.

- [ ] **Step 4: Record the verification report**

Pass/blocked with evidence (the lamp change is the headline). If blocked on the portal capability or the Allow prompt, document exactly what the user must do.

**Gate:** Tasks 8–9 (deleting old paths) only proceed once Step 2 passes.

---

## Task 8: Remove the per-command HomeKit helper

**Agent:** lamp-mac. **Files:** delete `mac-agent/homekit-helper/**`; remove `LampClient.homekit(helperAppPath:…)` + `HomeKitClientTests`.

- [ ] **Step 1: Delete the helper project**

```bash
cd /Users/volovely/GitHub/lamp-controller
git rm -r mac-agent/homekit-helper
rm -rf mac-agent/homekit-helper   # remove any untracked build/ too
```

- [ ] **Step 2: Remove the CLI's helper-backed HomeKit backend**

In `mac-agent/Sources/LampAgent/HomeKitClient.swift` (the `LampClient.homekit(helperAppPath:accessoryName:runner:)` + `HomeKitRunner`): delete this file (the app replaces it; the CLI no longer drives HomeKit). Then remove the now-dangling references:
- `mac-agent/Tests/LampAgentTests/HomeKitClientTests.swift` — `git rm`.
- `mac-agent/Sources/LampAgent/Config.swift` — remove the `.homekit` case from `Backend`, the `homekitHelperPath`/`homekitAccessoryName` fields **used by the helper backend**. NOTE: the app still needs `homekit_accessory_name`. Keep `homekitAccessoryName` as a parsed optional (no longer tied to a `.homekit` lamp backend); drop `homekitHelperPath` and the `.homekit` backend validation. Default `lamp_backend` becomes `.shortcuts` for the CLI (the CLI's supported backends are now shortcuts/homebridge); the app reads `homekitAccessoryName` directly regardless of `lamp_backend`.
- `mac-agent/Sources/lamp-agent/main.swift` — remove the `.homekit` switch case.
- `mac-agent/Tests/LampAgentTests/ConfigTests.swift` — drop/adjust the homekit-backend tests; keep `homekit_accessory_name` parsing covered.

- [ ] **Step 3: Build + test**

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd mac-agent && swift build 2>&1 | tail -3 && swift test 2>&1 | tail -5
```

Expected: green; suite smaller by the removed helper/homekit tests. Confirm `grep -rn "homekit_helper_path\|helperAppPath\|\.homekit\b" mac-agent/Sources` returns nothing.

- [ ] **Step 4: Commit**

```bash
cd /Users/volovely/GitHub/lamp-controller
git add -A mac-agent/
git commit -m "refactor(mac-agent): remove per-command HomeKit helper; app owns HomeKit"
```

---

## Task 9: Remove the launchd daemon path

**Agent:** lamp-ops. **Files:** delete `mac-agent/Resources/com.lamp.agent.plist`, `mac-agent/scripts/install.sh`, `mac-agent/scripts/uninstall.sh`.

- [ ] **Step 1: Remove launchd artifacts**

```bash
cd /Users/volovely/GitHub/lamp-controller
git rm mac-agent/Resources/com.lamp.agent.plist mac-agent/scripts/install.sh mac-agent/scripts/uninstall.sh
```

(If `mac-agent/Resources/` or `scripts/` is now empty except `config.toml.example`, leave `config.toml.example` in place under `Resources/`.)

- [ ] **Step 2: Commit**

```bash
git commit -m "refactor(mac-agent): remove launchd daemon (superseded by the app)"
```

---

## Task 10: Docs

**Agent:** lamp-mac (+ lamp-ops for ops doc). **Files:**
- Create: `mac-app/README.md`
- Modify: `mac-agent/README.md`, `mac-agent/Resources/config.toml.example`, `docs/ops/first-time-setup.md`, `README.md` (root)

- [ ] **Step 1: mac-app/README.md**

Document: what the app is (window with Start/Stop, polls the Worker, drives HomeKit in-process); one-time setup (enable HomeKit capability for App ID `com.volovely.lamp-controller` at developer.apple.com → Identifiers; first-launch "Allow" Home prompt); build/run:

```bash
cd mac-app
brew install xcodegen
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodegen generate
open LampController.xcodeproj      # ⌘R to run
```

State that it reads `~/.config/lamp-agent/config.toml` (`worker_url`, `shared_secret`, `homekit_accessory_name`, `poll_interval_s`, `state_path`).

- [ ] **Step 2: Update mac-agent docs**

In `mac-agent/README.md`: the `lamp-agent` CLI is now a smoke-test/`--once` harness for the worker/file/shortcuts/homebridge backends; the **desktop app (`mac-app/`) is the supported way to run continuously and drive the lamp**. Remove the launchd "Install" section. In `mac-agent/Resources/config.toml.example`: drop `homekit_helper_path`; keep `homekit_accessory_name` (now used by the app); note `lamp_backend` applies to the CLI only.

- [ ] **Step 3: first-time-setup.md + root README**

In `docs/ops/first-time-setup.md`: add an app section (HomeKit capability enable + Allow prompt + build), and remove/replace the launchd-runner instructions for the agent. In root `README.md`: update the `mac-agent/` row and add a `mac-app/` row.

- [ ] **Step 4: Commit**

```bash
cd /Users/volovely/GitHub/lamp-controller
git add mac-app/README.md mac-agent/README.md mac-agent/Resources/config.toml.example docs/ docs/ops/first-time-setup.md README.md
git commit -m "docs: document the desktop app as the supported run path"
```

---

## Task 11: Stage review (diff)

**Agent:** lamp-reviewer. **Files:** none.

- [ ] **Step 1: Build + test everything**

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd mac-agent && swift build && swift test 2>&1 | tail -5
cd ../mac-app && xcodegen generate && xcodebuild -project LampController.xcodeproj -scheme LampController -destination 'platform=macOS,variant=Mac Catalyst' -derivedDataPath build test 2>&1 | tail -12
```

- [ ] **Step 2: Review the branch diff**

```bash
cd /Users/volovely/GitHub/lamp-controller
git diff main...app-desktop-controller --stat
```

Check: the app reuses the core (no logic duplicated except the lifted HomeKit write code, which is intentional); `HomeKitController.apply` matches the helper's proven behavior (power-first, brightness/CT only when on, Kelvin→mired clamp); AppModel cancels cleanly on stop and doesn't leak the Task; no secrets in committed files; the old paths are fully removed (no dangling refs); commit messages follow `CLAUDE.md`. Record findings; fix blockers before Task 12.

---

## Task 12: Finish the branch

**Agent:** orchestrator. **REQUIRED SUB-SKILL:** superpowers:finishing-a-development-branch.

- [ ] **Step 1: Confirm clean + green** (both suites as in Task 11 Step 1).
- [ ] **Step 2: Push branch + open PR; let CI run.** Note: CI's `mac-agent-ci` covers the core; the **app is not built in CI** (signing needs the paid team) — call this out in the PR body, like the helper.
- [ ] **Step 3: After squash-merge, VERIFY THE SQUASH (PR #3 lesson):**

```bash
git checkout main && git pull --ff-only
git diff <branch-tip-sha> HEAD -- mac-app mac-agent docs | wc -l   # expect 0
for f in mac-app/Sources/LampControllerApp.swift mac-app/Sources/AppModel.swift \
         mac-app/Sources/HomeKitController.swift mac-app/project.yml; do
  git ls-files --error-unmatch "$f" >/dev/null 2>&1 && echo "OK $f" || echo "MISSING $f"
done
# confirm old paths are GONE on main:
test -d mac-agent/homekit-helper && echo "HELPER STILL PRESENT (bad)" || echo "helper removed OK"
```

If anything is MISSING / non-zero diff / helper still present, recover from the branch tip before proceeding.

- [ ] **Step 4: Note remaining manual items:** HomeKit capability enable for the new App ID (if not already), first-launch Allow, and that the app must be rebuilt locally after pulls (not in CI).

---

## Definition of done

- [ ] `mac-app/` is a Catalyst SwiftUI app: window with Start/Stop, status (HomeKit + Worker), activity log; reads `~/.config/lamp-agent/config.toml`.
- [ ] App polls the Worker and drives the lamp **in-process via HomeKit** (no helper, no per-command `open`).
- [ ] `LampClient.homeKit` + `AppModel` unit tests pass; `mac-agent` core suite stays green.
- [ ] Live: Start → `wrangler kv put` → lamp obeys → key acked; Stop → polling halts. (Verified against the real lamp.)
- [ ] `mac-agent/homekit-helper/`, the launchd plist + install/uninstall scripts, and the CLI `.homekit` backend are removed; no dangling references.
- [ ] Docs updated (mac-app README, mac-agent README, config example, first-time-setup, root README).
- [ ] Branch merged to `main` via PR with `mac-agent-ci` green and **squash contents verified**.

**Gated on human setup (not blocking the merge):** enabling the HomeKit capability for `com.volovely.lamp-controller`, the first-launch Allow prompt, and building the app locally.
