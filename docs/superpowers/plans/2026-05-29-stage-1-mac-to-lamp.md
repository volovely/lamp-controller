# Stage 1 — Mac → lamp Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the `lamp-agent` Swift daemon that reads a local `commands.json` queue and applies on/off, brightness, and color-temperature to a Xiaomi Mijia desk lamp through a local Homebridge REST API.

**Architecture:** A long-running poll loop reads a `CommandSource` (file-backed in this stage, Worker-backed in Stage 2), filters out already-applied (`acked.json`) and stale (>10 min) commands, and hands each to a `CommandExecutor` that maps it to `HomebridgeClient` REST calls. All I/O boundaries are injected via the Dependencies library so the core logic is unit-tested with stubs. The `CommandSource` protocol is the only seam Stage 2 replaces.

**Tech Stack:** Swift 6.0 (SwiftPM, swift-testing), Point-Free Dependencies + DependenciesMacros, IssueReporting, TOMLKit, CustomDump (tests), Homebridge + homebridge-config-ui-x REST API, launchd, GitHub Actions self-hosted runner.

**Reference spec:** [`docs/superpowers/specs/2026-05-29-stage-1-mac-to-lamp-design.md`](../specs/2026-05-29-stage-1-mac-to-lamp-design.md). Always pass this path to sub-agents.

---

## Toolchain note (read first)

`swift-testing`'s macOS module ships with Xcode, not the bare command-line tools. Every `swift build` / `swift test` command in this plan must run with Xcode selected:

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
```

Either export it in the shell once, or prefix each command. The plan prefixes the first use in each task and assumes it stays exported thereafter.

The repo's `mac-agent/Package.swift` already uses `swift-tools-version: 6.0` and currently contains a `Hello`/`HelloTests` skeleton (from Stage 0). Task 4 replaces that skeleton with the first real component.

---

## File structure produced by this stage

```
mac-agent/
├── Package.swift                              # + deps: dependencies, issue-reporting, tomlkit, custom-dump
├── Sources/
│   ├── LampAgent/
│   │   ├── Command.swift                       # model + Codable + validation + JSON coders
│   │   ├── CommandSource.swift                 # protocol (@DependencyClient) + ack contract
│   │   ├── FileCommandSource.swift             # reads commands.json
│   │   ├── AckStore.swift                      # acked.json ledger + stale-guard predicate
│   │   ├── HomebridgeClient.swift              # @DependencyClient + live REST impl + Kelvin→Mired
│   │   ├── CommandExecutor.swift               # Command → HomebridgeClient calls
│   │   ├── Config.swift                         # config.toml loader (TOMLKit)
│   │   ├── PollLoop.swift                       # runOnce() (testable) + run() (daemon)
│   │   └── Dependencies+Live.swift             # DependencyKey conformances
│   └── lamp-agent/
│       └── main.swift                          # arg parse (--once), wire deps, run
├── Tests/LampAgentTests/
│   ├── CommandTests.swift
│   ├── AckStoreTests.swift
│   ├── FileCommandSourceTests.swift
│   ├── ColorTemperatureTests.swift
│   ├── CommandExecutorTests.swift
│   ├── ConfigTests.swift
│   └── PollLoopTests.swift
├── Resources/
│   ├── com.lamp.agent.plist                    # launchd LaunchAgent
│   └── config.toml.example
└── scripts/
    ├── install.sh
    └── uninstall.sh

homebridge/
└── README.md                                   # filled in by Task 1 (was a stub)

shared/
└── command-schema.json                         # color.hex → color_temp_k

.github/workflows/
└── deploy-mac-agent.yml                         # dormant until runner registered
```

---

## Task 1: Homebridge integration research & docs

**Agent:** lamp-homebridge (read-only on the codebase; write-only to `homebridge/`).

**Files:**
- Modify: `homebridge/README.md` (replace the Stage 0 stub)
- Create: `homebridge/HomebridgeClient.skeleton.swift` (reference contract, not compiled)

This task produces the documented REST contract that Task 7 implements. It does **not** write code into `mac-agent/`.

- [ ] **Step 1: Research and document the Homebridge setup**

Write `homebridge/README.md` covering, concretely:
- Installing Homebridge + `homebridge-config-ui-x` on macOS (Homebrew or npm), with the UI bound to `127.0.0.1:8581`.
- Choosing the Xiaomi plugin for a Mijia desk lamp: evaluate `homebridge-miot` (needs MIoT device id + token) vs a Yeelight LAN plugin (needs LAN Control enabled). Recommend one and give the exact install + config steps.
- How to obtain the lamp's token / enable LAN Control (Mi Home app steps).
- How the lamp surfaces as a Lightbulb accessory: the `uniqueId`, and the `On`, `Brightness`, `ColorTemperature` characteristics, including the advertised `minValue`/`maxValue` (mired) for `ColorTemperature`.
- The config-ui-x REST contract the Mac agent uses:
  - `POST /api/auth/login` `{ "username", "password" }` → `{ "access_token", "token_type", "expires_in" }`, **or** how to mint/configure a long-lived bearer token (token expiry setting).
  - `GET /api/accessories` → array including `uniqueId` and `serviceCharacteristics`.
  - `PUT /api/accessories/{uniqueId}` `{ "characteristicType": "On"|"Brightness"|"ColorTemperature", "value": <bool|int> }`, with `Authorization: Bearer <token>`.
  - `GET /api/auth/check` for token validation.

- [ ] **Step 2: Write the reference client contract**

Create `homebridge/HomebridgeClient.skeleton.swift` as a **documentation artifact** (commented, not part of any target) describing the three operations Task 7 must implement, with the exact endpoint, HTTP method, JSON body, characteristic name, and value type for each of `setPower(on:)`, `setBrightness(percent:)`, `setColorTemperature(kelvin:)`, plus the Kelvin→mired formula and the clamp range read in Step 1.

- [ ] **Step 3: Verify the docs are self-contained**

Re-read `homebridge/README.md`. Confirm an engineer who has never seen the lamp could: install Homebridge, bridge the lamp, get a token, and know the exact `PUT` body for each characteristic. No "TBD".

- [ ] **Step 4: Commit**

```bash
git add homebridge/
git commit -m "docs(homebridge): document Mijia lamp bridging and REST contract"
```

---

## Task 2: Add Swift package dependencies

**Agent:** lamp-mac.

**Files:**
- Modify: `mac-agent/Package.swift`

- [ ] **Step 1: Rewrite Package.swift with dependencies**

Replace the contents of `mac-agent/Package.swift` with:

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LampAgent",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LampAgent", targets: ["LampAgent"]),
        .executable(name: "lamp-agent", targets: ["lamp-agent"]),
    ],
    dependencies: [
        .package(url: "https://github.com/pointfreeco/swift-dependencies", from: "1.3.0"),
        .package(url: "https://github.com/pointfreeco/swift-issue-reporting", from: "1.4.0"),
        .package(url: "https://github.com/LebJe/TOMLKit", from: "0.6.0"),
        .package(url: "https://github.com/pointfreeco/swift-custom-dump", from: "1.3.0"),
    ],
    targets: [
        .target(
            name: "LampAgent",
            dependencies: [
                .product(name: "Dependencies", package: "swift-dependencies"),
                .product(name: "DependenciesMacros", package: "swift-dependencies"),
                .product(name: "IssueReporting", package: "swift-issue-reporting"),
                .product(name: "TOMLKit", package: "TOMLKit"),
            ]
        ),
        .executableTarget(name: "lamp-agent", dependencies: ["LampAgent"]),
        .testTarget(
            name: "LampAgentTests",
            dependencies: [
                "LampAgent",
                .product(name: "Dependencies", package: "swift-dependencies"),
                .product(name: "CustomDump", package: "swift-custom-dump"),
            ]
        ),
    ]
)
```

- [ ] **Step 2: Resolve dependencies and confirm the skeleton still builds**

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd mac-agent && swift package resolve 2>&1 | tail -20
swift test 2>&1 | tail -10
```

Expected: packages resolve; the existing `Hello` test still passes (`Test run with 1 test in 1 suite passed`).

- [ ] **Step 3: Commit**

```bash
git add mac-agent/Package.swift mac-agent/Package.resolved
git commit -m "build(mac-agent): add Dependencies, IssueReporting, TOMLKit, CustomDump"
```

---

## Task 3: Update the shared command schema

**Agent:** orchestrator (neither domain agent owns `shared/`; make this change directly).

**Files:**
- Modify: `shared/command-schema.json`

- [ ] **Step 1: Replace the color object with color_temp_k**

In `shared/command-schema.json`, delete the entire `"color"` property block and add, in its place:

```json
    "color_temp_k": {
      "type": "integer",
      "minimum": 2700,
      "maximum": 6500,
      "description": "Lamp color temperature in Kelvin (warm 2700 ↔ cool 6500). The Mac agent clamps to the accessory's advertised range. Meaningful for 'on' and 'set'."
    },
```

Leave `id`, `action`, `brightness`, `duration_minutes`, `created_at`, and `source_msg_id` unchanged. Confirm `color_temp_k` is **not** added to the top-level `required` array (it is optional).

- [ ] **Step 2: Validate the JSON**

```bash
cd /Users/volovely/GitHub/lamp-controller
python3 -c "import json; d=json.load(open('shared/command-schema.json')); assert 'color' not in d['properties']; assert d['properties']['color_temp_k']['minimum']==2700; print('schema OK')"
```

Expected: `schema OK`.

- [ ] **Step 3: Commit**

```bash
git add shared/command-schema.json
git commit -m "feat(shared): model color as color_temp_k (tunable white), drop RGB hex"
```

---

## Task 4: Command model, validation, and JSON coders

**Agent:** lamp-mac. **REQUIRED SKILL:** pfw-testing.

**Files:**
- Create: `mac-agent/Tests/LampAgentTests/CommandTests.swift`
- Create: `mac-agent/Sources/LampAgent/Command.swift`
- Delete: `mac-agent/Sources/LampAgent/Hello.swift`, `mac-agent/Tests/LampAgentTests/HelloTests.swift`

- [ ] **Step 1: Write the failing test**

Create `mac-agent/Tests/LampAgentTests/CommandTests.swift`:

```swift
import Foundation
import Testing
@testable import LampAgent

@Suite("Command")
struct CommandTests {
    @Test("decodes a full on-command from contract JSON")
    func decodeFull() throws {
        let json = """
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "action": "on",
          "brightness": 30,
          "color_temp_k": 2700,
          "created_at": "2026-05-29T10:00:00Z",
          "source_msg_id": "msg-1"
        }
        """.data(using: .utf8)!

        let command = try Command.jsonDecoder.decode(Command.self, from: json)

        #expect(command.id == "11111111-1111-1111-1111-111111111111")
        #expect(command.action == .on)
        #expect(command.brightness == 30)
        #expect(command.colorTempK == 2700)
        #expect(command.sourceMsgId == "msg-1")
        #expect(command.createdAt == Date(timeIntervalSince1970: 1_780_048_800))
    }

    @Test("decodes a minimal off-command")
    func decodeMinimal() throws {
        let json = """
        {"id":"a","action":"off","created_at":"2026-05-29T10:00:00Z","source_msg_id":"m"}
        """.data(using: .utf8)!

        let command = try Command.jsonDecoder.decode(Command.self, from: json)

        #expect(command.action == .off)
        #expect(command.brightness == nil)
        #expect(command.colorTempK == nil)
    }

    @Test("validate rejects brightness out of range")
    func rejectBrightness() throws {
        let command = Command(
            id: "a", action: .on, brightness: 150, colorTempK: nil,
            durationMinutes: nil, createdAt: .init(timeIntervalSince1970: 0), sourceMsgId: "m"
        )
        #expect(throws: Command.ValidationError.self) { try command.validate() }
    }

    @Test("validate rejects color_temp_k out of range")
    func rejectColorTemp() throws {
        let command = Command(
            id: "a", action: .set, brightness: nil, colorTempK: 1000,
            durationMinutes: nil, createdAt: .init(timeIntervalSince1970: 0), sourceMsgId: "m"
        )
        #expect(throws: Command.ValidationError.self) { try command.validate() }
    }

    @Test("validate accepts a well-formed command")
    func acceptValid() throws {
        let command = Command(
            id: "a", action: .on, brightness: 50, colorTempK: 4000,
            durationMinutes: nil, createdAt: .init(timeIntervalSince1970: 0), sourceMsgId: "m"
        )
        try command.validate()
    }

    @Test("isStale is true past the 10-minute window")
    func staleness() {
        let created = Date(timeIntervalSince1970: 0)
        let command = Command(
            id: "a", action: .on, brightness: nil, colorTempK: nil,
            durationMinutes: nil, createdAt: created, sourceMsgId: "m"
        )
        #expect(command.isStale(now: created.addingTimeInterval(601)))
        #expect(!command.isStale(now: created.addingTimeInterval(599)))
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd mac-agent && swift test --filter CommandTests 2>&1 | tail -15
```

Expected: compile failure — `cannot find 'Command' in scope`.

- [ ] **Step 3: Delete the Stage 0 skeleton**

```bash
rm mac-agent/Sources/LampAgent/Hello.swift mac-agent/Tests/LampAgentTests/HelloTests.swift
```

- [ ] **Step 4: Write the implementation**

Create `mac-agent/Sources/LampAgent/Command.swift`:

```swift
import Foundation

/// A single lamp command. Mirrors `shared/command-schema.json`.
public struct Command: Codable, Equatable, Identifiable, Sendable {
    public enum Action: String, Codable, Sendable {
        case on, off, set
    }

    public let id: String
    public let action: Action
    public let brightness: Int?
    public let colorTempK: Int?
    public let durationMinutes: Int?
    public let createdAt: Date
    public let sourceMsgId: String

    public init(
        id: String,
        action: Action,
        brightness: Int?,
        colorTempK: Int?,
        durationMinutes: Int?,
        createdAt: Date,
        sourceMsgId: String
    ) {
        self.id = id
        self.action = action
        self.brightness = brightness
        self.colorTempK = colorTempK
        self.durationMinutes = durationMinutes
        self.createdAt = createdAt
        self.sourceMsgId = sourceMsgId
    }

    enum CodingKeys: String, CodingKey {
        case id, action, brightness
        case colorTempK = "color_temp_k"
        case durationMinutes = "duration_minutes"
        case createdAt = "created_at"
        case sourceMsgId = "source_msg_id"
    }

    /// Stale-guard: commands older than 10 minutes are dropped without applying.
    public static let staleAfter: TimeInterval = 600

    public func isStale(now: Date) -> Bool {
        now.timeIntervalSince(createdAt) > Self.staleAfter
    }

    public enum ValidationError: Error, Equatable {
        case brightnessOutOfRange(Int)
        case colorTempOutOfRange(Int)
    }

    /// Enforces field-range invariants. Mapping order/ignoring of fields per
    /// action is the executor's job; this only guards ranges.
    public func validate() throws {
        if let brightness, !(0...100).contains(brightness) {
            throw ValidationError.brightnessOutOfRange(brightness)
        }
        if let colorTempK, !(2700...6500).contains(colorTempK) {
            throw ValidationError.colorTempOutOfRange(colorTempK)
        }
    }

    /// Decoder configured for the contract's RFC3339 / ISO-8601 timestamps.
    public static let jsonDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            guard let date = iso8601.date(from: string) ?? iso8601NoFraction.date(from: string) else {
                throw DecodingError.dataCorruptedError(
                    in: container, debugDescription: "Invalid RFC3339 date: \(string)"
                )
            }
            return date
        }
        return decoder
    }()

    public static let jsonEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(iso8601NoFraction.string(from: date))
        }
        return encoder
    }()

    private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let iso8601NoFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
```

- [ ] **Step 5: Run the test to verify it passes**

```bash
swift test --filter CommandTests 2>&1 | tail -10
```

Expected: all 6 `CommandTests` pass.

- [ ] **Step 6: Commit**

```bash
git add mac-agent/Sources/LampAgent/Command.swift mac-agent/Tests/LampAgentTests/CommandTests.swift
git rm --cached --ignore-unmatch mac-agent/Sources/LampAgent/Hello.swift mac-agent/Tests/LampAgentTests/HelloTests.swift
git add -A mac-agent/
git commit -m "feat(mac-agent): add Command model with validation and JSON coders"
```

---

## Task 5: AckStore — the applied-UUID ledger

**Agent:** lamp-mac. **REQUIRED SKILL:** pfw-testing.

`AckStore` is the crash-safe local record of which command UUIDs have been applied. The poll loop reads it to dedup and writes to it after applying. Backed by `acked.json` (a JSON array of strings).

**Files:**
- Create: `mac-agent/Tests/LampAgentTests/AckStoreTests.swift`
- Create: `mac-agent/Sources/LampAgent/AckStore.swift`

- [ ] **Step 1: Write the failing test**

Create `mac-agent/Tests/LampAgentTests/AckStoreTests.swift`:

```swift
import Foundation
import Testing
@testable import LampAgent

@Suite("AckStore")
struct AckStoreTests {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ack-\(UUID().uuidString).json")
    }

    @Test("missing file loads as empty set")
    func missingFileEmpty() throws {
        let store = AckStore.file(at: tempURL())
        #expect(try store.load().isEmpty)
    }

    @Test("recorded ids round-trip through the file")
    func roundTrip() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = AckStore.file(at: url)

        try store.record(["a", "b"])
        try store.record(["c"])

        #expect(try store.load() == ["a", "b", "c"])
    }

    @Test("corrupt file loads as empty rather than throwing")
    func corruptFileEmpty() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try "not json".data(using: .utf8)!.write(to: url)

        let store = AckStore.file(at: url)
        #expect(try store.load().isEmpty)
    }

    @Test("recording is idempotent for duplicate ids")
    func dedupes() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = AckStore.file(at: url)

        try store.record(["a"])
        try store.record(["a"])

        #expect(try store.load() == ["a"])
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
swift test --filter AckStoreTests 2>&1 | tail -15
```

Expected: `cannot find 'AckStore' in scope`.

- [ ] **Step 3: Write the implementation**

Create `mac-agent/Sources/LampAgent/AckStore.swift`:

```swift
import Foundation

/// Crash-safe ledger of applied command UUIDs, backed by a JSON array file.
public struct AckStore: Sendable {
    public var load: @Sendable () throws -> Set<String>
    public var record: @Sendable (_ ids: [String]) throws -> Void

    public init(
        load: @escaping @Sendable () throws -> Set<String>,
        record: @escaping @Sendable (_ ids: [String]) throws -> Void
    ) {
        self.load = load
        self.record = record
    }
}

extension AckStore {
    /// File-backed store. A missing or corrupt file reads as an empty set.
    public static func file(at url: URL) -> AckStore {
        let queue = DispatchQueue(label: "lamp-agent.ackstore")

        func read() -> Set<String> {
            guard let data = try? Data(contentsOf: url),
                  let array = try? JSONDecoder().decode([String].self, from: data)
            else { return [] }
            return Set(array)
        }

        return AckStore(
            load: { queue.sync { read() } },
            record: { ids in
                try queue.sync {
                    var current = read()
                    current.formUnion(ids)
                    try FileManager.default.createDirectory(
                        at: url.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    let data = try JSONEncoder().encode(current.sorted())
                    try data.write(to: url, options: .atomic)
                }
            }
        )
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
swift test --filter AckStoreTests 2>&1 | tail -10
```

Expected: all 4 `AckStoreTests` pass.

- [ ] **Step 5: Commit**

```bash
git add mac-agent/Sources/LampAgent/AckStore.swift mac-agent/Tests/LampAgentTests/AckStoreTests.swift
git commit -m "feat(mac-agent): add AckStore applied-UUID ledger"
```

---

## Task 6: CommandSource protocol + FileCommandSource

**Agent:** lamp-mac. **REQUIRED SKILLS:** pfw-dependencies, pfw-testing.

`CommandSource` is the seam Stage 2 swaps. `pending()` returns the current queue; `ack(_:)` notifies the source that ids are done (for the file source this is a no-op — `acked.json` is the dedup ledger; the Worker source will `POST /ack`).

**Files:**
- Create: `mac-agent/Tests/LampAgentTests/FileCommandSourceTests.swift`
- Create: `mac-agent/Sources/LampAgent/CommandSource.swift`
- Create: `mac-agent/Sources/LampAgent/FileCommandSource.swift`

- [ ] **Step 1: Write the failing test**

Create `mac-agent/Tests/LampAgentTests/FileCommandSourceTests.swift`:

```swift
import Foundation
import Testing
@testable import LampAgent

@Suite("FileCommandSource")
struct FileCommandSourceTests {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("cmds-\(UUID().uuidString).json")
    }

    @Test("missing file yields no pending commands")
    func missingFileEmpty() async throws {
        let source = CommandSource.file(at: tempURL())
        let pending = try await source.pending()
        #expect(pending.isEmpty)
    }

    @Test("reads and decodes the command array")
    func readsArray() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let json = """
        [{"id":"a","action":"on","brightness":30,"created_at":"2026-05-29T10:00:00Z","source_msg_id":"m"}]
        """
        try json.data(using: .utf8)!.write(to: url)

        let source = CommandSource.file(at: url)
        let pending = try await source.pending()

        #expect(pending.count == 1)
        #expect(pending.first?.id == "a")
        #expect(pending.first?.brightness == 30)
    }

    @Test("skips a malformed element but keeps the valid ones")
    func skipsMalformed() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let json = """
        [{"id":"a","action":"on","created_at":"2026-05-29T10:00:00Z","source_msg_id":"m"},
         {"id":"bad","action":"explode","created_at":"2026-05-29T10:00:00Z","source_msg_id":"m"}]
        """
        try json.data(using: .utf8)!.write(to: url)

        let source = CommandSource.file(at: url)
        let pending = try await source.pending()

        #expect(pending.map(\.id) == ["a"])
    }

    @Test("ack is a no-op that does not throw")
    func ackNoOp() async throws {
        let source = CommandSource.file(at: tempURL())
        try await source.ack(["a", "b"])
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
swift test --filter FileCommandSourceTests 2>&1 | tail -15
```

Expected: `cannot find 'CommandSource' in scope`.

- [ ] **Step 3: Write the protocol client**

Create `mac-agent/Sources/LampAgent/CommandSource.swift`:

```swift
import Dependencies
import DependenciesMacros

/// The queue the poll loop drains. File-backed in Stage 1; Worker-backed in Stage 2.
@DependencyClient
public struct CommandSource: Sendable {
    public var pending: @Sendable () async throws -> [Command] = { [] }
    public var ack: @Sendable (_ ids: [String]) async throws -> Void
}

extension CommandSource: TestDependencyKey {
    public static let testValue = CommandSource()
}

extension DependencyValues {
    public var commandSource: CommandSource {
        get { self[CommandSource.self] }
        set { self[CommandSource.self] = newValue }
    }
}
```

- [ ] **Step 4: Write the file-backed source**

Create `mac-agent/Sources/LampAgent/FileCommandSource.swift`:

```swift
import Foundation

extension CommandSource {
    /// Reads a JSON array of commands from `url`. A missing or unreadable file
    /// yields an empty list; individually malformed elements are skipped so one
    /// bad command does not block the rest. `ack` is a no-op — the file is an
    /// append-only log and `AckStore` provides dedup.
    public static func file(at url: URL) -> CommandSource {
        CommandSource(
            pending: {
                guard let data = try? Data(contentsOf: url),
                      let items = try? Command.jsonDecoder.decode([Failable<Command>].self, from: data)
                else { return [] }
                return items.compactMap(\.value)
            },
            ack: { _ in }
        )
    }
}

/// Decodes to `nil` instead of throwing when an element is malformed.
private struct Failable<Wrapped: Decodable>: Decodable {
    let value: Wrapped?
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.value = try? container.decode(Wrapped.self)
    }
}
```

- [ ] **Step 5: Run the test to verify it passes**

```bash
swift test --filter FileCommandSourceTests 2>&1 | tail -10
```

Expected: all 3 tests pass.

- [ ] **Step 6: Commit**

```bash
git add mac-agent/Sources/LampAgent/CommandSource.swift mac-agent/Sources/LampAgent/FileCommandSource.swift mac-agent/Tests/LampAgentTests/FileCommandSourceTests.swift
git commit -m "feat(mac-agent): add CommandSource seam and file-backed source"
```

---

## Task 7: HomebridgeClient — protocol, Kelvin→Mired, live REST impl

**Agent:** lamp-mac. **REQUIRED SKILLS:** pfw-dependencies, pfw-testing. **Depends on:** Task 1 (`homebridge/README.md` REST contract).

The pure Kelvin→mired conversion is unit-tested. The live REST impl follows the endpoints documented in Task 1.

**Files:**
- Create: `mac-agent/Tests/LampAgentTests/ColorTemperatureTests.swift`
- Create: `mac-agent/Sources/LampAgent/HomebridgeClient.swift`

- [ ] **Step 1: Write the failing test**

Create `mac-agent/Tests/LampAgentTests/ColorTemperatureTests.swift`:

```swift
import Testing
@testable import LampAgent

@Suite("Color temperature")
struct ColorTemperatureTests {
    @Test("converts Kelvin to mired (reciprocal megakelvin)")
    func basic() {
        #expect(miredFromKelvin(2700) == 370)   // 1_000_000 / 2700 = 370.37 → 370
        #expect(miredFromKelvin(5000) == 200)
    }

    @Test("clamps to the HomeKit mired range 140...500")
    func clamps() {
        #expect(miredFromKelvin(1000) == 500)    // would be 1000 mired, clamps down
        #expect(miredFromKelvin(10000) == 140)   // would be 100 mired, clamps up
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
swift test --filter ColorTemperatureTests 2>&1 | tail -15
```

Expected: `cannot find 'miredFromKelvin' in scope`.

- [ ] **Step 3: Write the client + conversion**

Create `mac-agent/Sources/LampAgent/HomebridgeClient.swift`:

```swift
import Dependencies
import DependenciesMacros
import Foundation
import IssueReporting

/// HomeKit `ColorTemperature` is expressed in mired (reciprocal megakelvin),
/// default range 140...500. Convert and clamp.
public func miredFromKelvin(_ kelvin: Int) -> Int {
    guard kelvin > 0 else { return 500 }
    let mired = Int((1_000_000.0 / Double(kelvin)).rounded())
    return min(500, max(140, mired))
}

/// Drives a single lamp accessory through the homebridge-config-ui-x REST API.
@DependencyClient
public struct HomebridgeClient: Sendable {
    public var setPower: @Sendable (_ on: Bool) async throws -> Void
    public var setBrightness: @Sendable (_ percent: Int) async throws -> Void
    public var setColorTemperature: @Sendable (_ kelvin: Int) async throws -> Void
}

extension HomebridgeClient: TestDependencyKey {
    public static let testValue = HomebridgeClient()
}

extension DependencyValues {
    public var homebridgeClient: HomebridgeClient {
        get { self[HomebridgeClient.self] }
        set { self[HomebridgeClient.self] = newValue }
    }
}

extension HomebridgeClient {
    public enum ClientError: Error, Equatable {
        case requestFailed(status: Int)
        case unreachable
    }

    /// Live implementation. Endpoints/auth per `homebridge/README.md` (Task 1):
    /// `PUT {baseURL}/api/accessories/{accessoryId}` with a bearer token and
    /// body `{ "characteristicType": <name>, "value": <bool|int> }`.
    public static func live(
        baseURL: URL,
        token: String,
        accessoryId: String,
        session: URLSession = .shared
    ) -> HomebridgeClient {
        func put(_ characteristic: String, _ value: some Encodable & Sendable) async throws {
            let url = baseURL
                .appendingPathComponent("api/accessories")
                .appendingPathComponent(accessoryId)
            var request = URLRequest(url: url)
            request.httpMethod = "PUT"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.httpBody = try JSONEncoder().encode(
                CharacteristicWrite(characteristicType: characteristic, value: AnyCodable(value))
            )

            let data: Data, response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
            } catch {
                throw ClientError.unreachable
            }
            _ = data
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                throw ClientError.requestFailed(status: status)
            }
        }

        return HomebridgeClient(
            setPower: { on in try await put("On", on) },
            setBrightness: { percent in try await put("Brightness", min(100, max(0, percent))) },
            setColorTemperature: { kelvin in try await put("ColorTemperature", miredFromKelvin(kelvin)) }
        )
    }
}

private struct CharacteristicWrite: Encodable {
    let characteristicType: String
    let value: AnyCodable
}

/// Minimal type-erased encodable so one body type covers Bool and Int values.
private struct AnyCodable: Encodable {
    private let encodeTo: @Sendable (inout SingleValueEncodingContainer) throws -> Void
    init(_ value: some Encodable & Sendable) {
        self.encodeTo = { container in try container.encode(value) }
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try encodeTo(&container)
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
swift test --filter ColorTemperatureTests 2>&1 | tail -10
```

Expected: both tests pass.

- [ ] **Step 5: Build the whole package to confirm the live impl compiles**

```bash
swift build 2>&1 | tail -10
```

Expected: `Build complete!`.

- [ ] **Step 6: Commit**

```bash
git add mac-agent/Sources/LampAgent/HomebridgeClient.swift mac-agent/Tests/LampAgentTests/ColorTemperatureTests.swift
git commit -m "feat(mac-agent): add HomebridgeClient with Kelvin→mired and live REST impl"
```

---

## Task 8: CommandExecutor — map Command to client calls

**Agent:** lamp-mac. **REQUIRED SKILLS:** pfw-dependencies, pfw-testing, pfw-custom-dump.

The most heavily tested unit. Uses a stub `HomebridgeClient` that records calls.

**Files:**
- Create: `mac-agent/Tests/LampAgentTests/CommandExecutorTests.swift`
- Create: `mac-agent/Sources/LampAgent/CommandExecutor.swift`

- [ ] **Step 1: Write the failing test**

Create `mac-agent/Tests/LampAgentTests/CommandExecutorTests.swift`:

```swift
import Dependencies
import Foundation
import Testing
@testable import LampAgent

@Suite("CommandExecutor")
struct CommandExecutorTests {
    /// Records the ordered calls made to HomebridgeClient.
    actor Recorder {
        enum Call: Equatable { case power(Bool), brightness(Int), colorTemp(Int) }
        private(set) var calls: [Call] = []
        func append(_ call: Call) { calls.append(call) }
    }

    private func makeClient(_ recorder: Recorder) -> HomebridgeClient {
        HomebridgeClient(
            setPower: { await recorder.append(.power($0)) },
            setBrightness: { await recorder.append(.brightness($0)) },
            setColorTemperature: { await recorder.append(.colorTemp($0)) }
        )
    }

    private func command(_ action: Command.Action, brightness: Int? = nil, colorTempK: Int? = nil) -> Command {
        Command(id: "a", action: action, brightness: brightness, colorTempK: colorTempK,
                durationMinutes: nil, createdAt: .init(timeIntervalSince1970: 0), sourceMsgId: "m")
    }

    @Test("on with brightness and temp sets power first, then brightness, then temp")
    func onFull() async throws {
        let recorder = Recorder()
        try await withDependencies {
            $0.homebridgeClient = makeClient(recorder)
        } operation: {
            try await CommandExecutor.live().execute(command(.on, brightness: 30, colorTempK: 2700))
        }
        #expect(await recorder.calls == [.power(true), .brightness(30), .colorTemp(2700)])
    }

    @Test("off only powers off, ignoring other fields")
    func off() async throws {
        let recorder = Recorder()
        try await withDependencies {
            $0.homebridgeClient = makeClient(recorder)
        } operation: {
            try await CommandExecutor.live().execute(command(.off, brightness: 80, colorTempK: 4000))
        }
        #expect(await recorder.calls == [.power(false)])
    }

    @Test("set adjusts brightness and temp without touching power")
    func set() async throws {
        let recorder = Recorder()
        try await withDependencies {
            $0.homebridgeClient = makeClient(recorder)
        } operation: {
            try await CommandExecutor.live().execute(command(.set, brightness: 55, colorTempK: 5000))
        }
        #expect(await recorder.calls == [.brightness(55), .colorTemp(5000)])
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
swift test --filter CommandExecutorTests 2>&1 | tail -15
```

Expected: `cannot find 'CommandExecutor' in scope`.

- [ ] **Step 3: Write the implementation**

Create `mac-agent/Sources/LampAgent/CommandExecutor.swift`:

```swift
import Dependencies

/// Maps a validated `Command` to ordered `HomebridgeClient` calls.
public struct CommandExecutor: Sendable {
    public var execute: @Sendable (_ command: Command) async throws -> Void

    public init(execute: @escaping @Sendable (_ command: Command) async throws -> Void) {
        self.execute = execute
    }
}

extension CommandExecutor {
    public static func live() -> CommandExecutor {
        CommandExecutor { command in
            @Dependency(\.homebridgeClient) var homebridge

            switch command.action {
            case .on:
                try await homebridge.setPower(true)
                if let brightness = command.brightness {
                    try await homebridge.setBrightness(brightness)
                }
                if let kelvin = command.colorTempK {
                    try await homebridge.setColorTemperature(kelvin)
                }
            case .off:
                try await homebridge.setPower(false)
            case .set:
                if let brightness = command.brightness {
                    try await homebridge.setBrightness(brightness)
                }
                if let kelvin = command.colorTempK {
                    try await homebridge.setColorTemperature(kelvin)
                }
            }
        }
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
swift test --filter CommandExecutorTests 2>&1 | tail -10
```

Expected: all 3 tests pass.

- [ ] **Step 5: Commit**

```bash
git add mac-agent/Sources/LampAgent/CommandExecutor.swift mac-agent/Tests/LampAgentTests/CommandExecutorTests.swift
git commit -m "feat(mac-agent): add CommandExecutor mapping commands to client calls"
```

---

## Task 9: Config — load config.toml

**Agent:** lamp-mac. **REQUIRED SKILL:** pfw-testing.

**Files:**
- Create: `mac-agent/Tests/LampAgentTests/ConfigTests.swift`
- Create: `mac-agent/Sources/LampAgent/Config.swift`

- [ ] **Step 1: Write the failing test**

Create `mac-agent/Tests/LampAgentTests/ConfigTests.swift`:

```swift
import Foundation
import Testing
@testable import LampAgent

@Suite("Config")
struct ConfigTests {
    @Test("parses a complete config.toml")
    func parsesAll() throws {
        let toml = """
        homebridge_url   = "http://127.0.0.1:8581"
        homebridge_token = "tok-123"
        accessory_id     = "lamp-desk"
        commands_path    = "/tmp/commands.json"
        poll_interval_s  = 12
        """
        let config = try Config.parse(toml)

        #expect(config.homebridgeURL == URL(string: "http://127.0.0.1:8581")!)
        #expect(config.homebridgeToken == "tok-123")
        #expect(config.accessoryId == "lamp-desk")
        #expect(config.commandsPath == "/tmp/commands.json")
        #expect(config.pollIntervalSeconds == 12)
    }

    @Test("expands a leading ~ in commands_path")
    func expandsTilde() throws {
        let toml = """
        homebridge_url   = "http://127.0.0.1:8581"
        homebridge_token = "t"
        accessory_id     = "a"
        commands_path    = "~/x/commands.json"
        poll_interval_s  = 5
        """
        let config = try Config.parse(toml)
        #expect(!config.commandsPath.hasPrefix("~"))
        #expect(config.commandsPath.hasSuffix("/x/commands.json"))
    }

    @Test("missing required key throws")
    func missingKeyThrows() throws {
        let toml = #"homebridge_token = "t""#
        #expect(throws: Config.ConfigError.self) { try Config.parse(toml) }
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
swift test --filter ConfigTests 2>&1 | tail -15
```

Expected: `cannot find 'Config' in scope`.

- [ ] **Step 3: Write the implementation**

Create `mac-agent/Sources/LampAgent/Config.swift`:

```swift
import Foundation
import TOMLKit

public struct Config: Equatable, Sendable {
    public var homebridgeURL: URL
    public var homebridgeToken: String
    public var accessoryId: String
    public var commandsPath: String
    public var pollIntervalSeconds: Int

    public enum ConfigError: Error, Equatable {
        case missingKey(String)
        case invalidURL(String)
    }

    public static func parse(_ text: String) throws -> Config {
        let table = try TOMLTable(string: text)

        func string(_ key: String) throws -> String {
            guard let value = table[key]?.string else { throw ConfigError.missingKey(key) }
            return value
        }
        func int(_ key: String) throws -> Int {
            guard let value = table[key]?.int else { throw ConfigError.missingKey(key) }
            return Int(value)
        }

        let urlString = try string("homebridge_url")
        guard let url = URL(string: urlString) else { throw ConfigError.invalidURL(urlString) }

        let rawPath = try string("commands_path")
        let path = (rawPath as NSString).expandingTildeInPath

        return Config(
            homebridgeURL: url,
            homebridgeToken: try string("homebridge_token"),
            accessoryId: try string("accessory_id"),
            commandsPath: path,
            pollIntervalSeconds: try int("poll_interval_s")
        )
    }

    /// Loads and parses the config file at `url`.
    public static func load(from url: URL) throws -> Config {
        try parse(String(contentsOf: url, encoding: .utf8))
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
swift test --filter ConfigTests 2>&1 | tail -10
```

Expected: all 3 tests pass.

- [ ] **Step 5: Commit**

```bash
git add mac-agent/Sources/LampAgent/Config.swift mac-agent/Tests/LampAgentTests/ConfigTests.swift
git commit -m "feat(mac-agent): add config.toml loader"
```

---

## Task 10: PollLoop — runOnce (testable) + run (daemon)

**Agent:** lamp-mac. **REQUIRED SKILLS:** pfw-dependencies, pfw-testing, pfw-issue-reporting.

`runOnce()` is the tested unit: load acked set → fetch pending → drop acked → drop+ack stale → execute the rest → record/ack successes; a failed execution is left un-acked for retry. `run()` is the thin daemon driver (fetch interval, sleep, repeat) and is intentionally minimal.

**Files:**
- Create: `mac-agent/Tests/LampAgentTests/PollLoopTests.swift`
- Create: `mac-agent/Sources/LampAgent/PollLoop.swift`

- [ ] **Step 1: Write the failing test**

Create `mac-agent/Tests/LampAgentTests/PollLoopTests.swift`:

```swift
import Dependencies
import Foundation
import Testing
@testable import LampAgent

@Suite("PollLoop")
struct PollLoopTests {
    actor Box { var ids: [String] = []; func add(_ s: String) { ids.append(s) } }

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("poll-\(UUID().uuidString).json")
    }

    private func command(_ id: String, action: Command.Action = .on, ageSeconds: TimeInterval = 0) -> Command {
        Command(id: id, action: action, brightness: nil, colorTempK: nil, durationMinutes: nil,
                createdAt: Date(timeIntervalSince1970: 1000 - ageSeconds), sourceMsgId: "m")
    }

    @Test("applies fresh, un-acked commands and records them")
    func appliesFresh() async throws {
        let ackURL = tempURL(); defer { try? FileManager.default.removeItem(at: ackURL) }
        let executed = Box()
        let ackedFromSource = Box()
        let a = command("a"); let b = command("b")
        let ackStore = AckStore.file(at: ackURL)

        let outcome = try await withDependencies {
            $0.date = .constant(Date(timeIntervalSince1970: 1000))
        } operation: {
            let source = CommandSource(
                pending: { [a, b] },
                ack: { ids in for id in ids { await ackedFromSource.add(id) } }
            )
            let executor = CommandExecutor { await executed.add($0.id) }
            return try await PollLoop(source: source, executor: executor, ackStore: ackStore).runOnce()
        }

        #expect(await executed.ids == ["a", "b"])
        #expect(try ackStore.load() == ["a", "b"])
        #expect(Set(await ackedFromSource.ids) == ["a", "b"])
        #expect(outcome.applied == ["a", "b"])
        #expect(outcome.failed == false)
    }

    @Test("skips commands already in the ledger")
    func skipsAcked() async throws {
        let ackURL = tempURL(); defer { try? FileManager.default.removeItem(at: ackURL) }
        let executed = Box()
        let a = command("a"); let b = command("b")
        let ackStore = AckStore.file(at: ackURL)
        try ackStore.record(["a"])

        let outcome = try await withDependencies {
            $0.date = .constant(Date(timeIntervalSince1970: 1000))
        } operation: {
            let source = CommandSource(pending: { [a, b] }, ack: { _ in })
            let executor = CommandExecutor { await executed.add($0.id) }
            return try await PollLoop(source: source, executor: executor, ackStore: ackStore).runOnce()
        }

        #expect(await executed.ids == ["b"])
        #expect(outcome.applied == ["b"])
    }

    @Test("drops stale commands without executing, but acks them")
    func dropsStale() async throws {
        let ackURL = tempURL(); defer { try? FileManager.default.removeItem(at: ackURL) }
        let executed = Box()
        let old = command("old", ageSeconds: 601)
        let ackStore = AckStore.file(at: ackURL)

        let outcome = try await withDependencies {
            $0.date = .constant(Date(timeIntervalSince1970: 1000))
        } operation: {
            let source = CommandSource(pending: { [old] }, ack: { _ in })
            let executor = CommandExecutor { await executed.add($0.id) }
            return try await PollLoop(source: source, executor: executor, ackStore: ackStore).runOnce()
        }

        #expect(await executed.ids == [])
        #expect(try ackStore.load() == ["old"])
        #expect(outcome.skippedStale == ["old"])
    }

    @Test("a failed execution is not acked and marks the outcome failed")
    func failureNotAcked() async throws {
        struct Boom: Error {}
        let ackURL = tempURL(); defer { try? FileManager.default.removeItem(at: ackURL) }
        let a = command("a")
        let ackStore = AckStore.file(at: ackURL)
        var outcome: PollOutcome?

        // runOnce reports an issue on the failed command; withKnownIssue absorbs it.
        await withKnownIssue {
            try await withDependencies {
                $0.date = .constant(Date(timeIntervalSince1970: 1000))
            } operation: {
                let source = CommandSource(pending: { [a] }, ack: { _ in })
                let executor = CommandExecutor { _ in throw Boom() }
                outcome = try await PollLoop(source: source, executor: executor, ackStore: ackStore).runOnce()
            }
        }

        #expect(try ackStore.load().isEmpty)
        #expect(outcome?.applied == [])
        #expect(outcome?.failed == true)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
swift test --filter PollLoopTests 2>&1 | tail -15
```

Expected: `cannot find 'PollLoop' in scope`.

- [ ] **Step 3: Write the implementation**

Create `mac-agent/Sources/LampAgent/PollLoop.swift`:

```swift
import Dependencies
import Foundation
import IssueReporting

public struct PollOutcome: Equatable, Sendable {
    public var applied: [String]
    public var skippedStale: [String]
    public var failed: Bool
}

/// Drains a `CommandSource` once per `runOnce()`; `run()` loops with backoff.
public struct PollLoop: Sendable {
    let source: CommandSource
    let executor: CommandExecutor
    let ackStore: AckStore

    public init(source: CommandSource, executor: CommandExecutor, ackStore: AckStore) {
        self.source = source
        self.executor = executor
        self.ackStore = ackStore
    }

    /// One poll pass. Returns what happened so `run()` can adjust backoff.
    @discardableResult
    public func runOnce() async throws -> PollOutcome {
        @Dependency(\.date) var date
        let now = date.now

        let acked = try ackStore.load()
        let pending = try await source.pending()

        var applied: [String] = []
        var skippedStale: [String] = []
        var failed = false

        for command in pending where !acked.contains(command.id) {
            if command.isStale(now: now) {
                skippedStale.append(command.id)
                continue
            }
            do {
                try command.validate()
                try await executor.execute(command)
                applied.append(command.id)
            } catch {
                reportIssue("Failed to apply command \(command.id): \(error)")
                failed = true
            }
        }

        let toAck = applied + skippedStale
        if !toAck.isEmpty {
            try ackStore.record(toAck)
            try await source.ack(toAck)
        }

        return PollOutcome(applied: applied, skippedStale: skippedStale, failed: failed)
    }

    /// Long-running daemon loop. Fixed interval on success; backs off after a
    /// failed cycle (2 → 5 → 15 → 30 s, capped) so an unreachable Homebridge
    /// doesn't hammer. `isCancelled` lets callers/tests stop the loop.
    public func run(
        intervalSeconds: Int,
        isCancelled: @Sendable () -> Bool = { Task.isCancelled }
    ) async throws {
        @Dependency(\.continuousClock) var clock
        let backoffs: [Int] = [2, 5, 15, 30]
        var backoffIndex = 0

        while !isCancelled() {
            let outcome = try await runOnce()
            let delay: Int
            if outcome.failed {
                delay = backoffs[min(backoffIndex, backoffs.count - 1)]
                backoffIndex += 1
            } else {
                backoffIndex = 0
                delay = intervalSeconds
            }
            try await clock.sleep(for: .seconds(delay))
        }
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
swift test --filter PollLoopTests 2>&1 | tail -10
```

Expected: all 4 tests pass.

- [ ] **Step 5: Run the full suite**

```bash
swift test 2>&1 | tail -10
```

Expected: all suites pass, zero failures.

- [ ] **Step 6: Commit**

```bash
git add mac-agent/Sources/LampAgent/PollLoop.swift mac-agent/Tests/LampAgentTests/PollLoopTests.swift
git commit -m "feat(mac-agent): add PollLoop with stale-guard, ack, and backoff"
```

---

## Task 11: Dependencies live values + executable entrypoint

**Agent:** lamp-mac. **REQUIRED SKILL:** pfw-dependencies.

Wire the live `HomebridgeClient` from config and provide the executable. `--once` runs a single pass (demo/testing); default runs the daemon loop.

**Files:**
- Create: `mac-agent/Sources/LampAgent/Dependencies+Live.swift`
- Modify: `mac-agent/Sources/lamp-agent/main.swift`

- [ ] **Step 1: Add the live HomebridgeClient DependencyKey**

Create `mac-agent/Sources/LampAgent/Dependencies+Live.swift`:

```swift
import Dependencies
import Foundation

extension HomebridgeClient: DependencyKey {
    /// Unimplemented by default — the executable injects a configured live
    /// client via `withDependencies`. Tests inject their own stub.
    public static var liveValue: HomebridgeClient { HomebridgeClient() }
}

/// Builds the fully-wired runtime objects from a parsed `Config`.
public enum Runtime {
    public static func makePollLoop(config: Config) -> PollLoop {
        PollLoop(
            source: .file(at: URL(fileURLWithPath: config.commandsPath)),
            executor: .live(),
            ackStore: .file(at: ackedURL(forCommandsAt: config.commandsPath))
        )
    }

    static func ackedURL(forCommandsAt commandsPath: String) -> URL {
        URL(fileURLWithPath: commandsPath)
            .deletingLastPathComponent()
            .appendingPathComponent("acked.json")
    }
}
```

- [ ] **Step 2: Write the executable entrypoint**

Replace `mac-agent/Sources/lamp-agent/main.swift`:

```swift
import Dependencies
import Foundation
import LampAgent

// Resolve config path: $LAMP_AGENT_CONFIG or ~/.config/lamp-agent/config.toml
let configPath = ProcessInfo.processInfo.environment["LAMP_AGENT_CONFIG"]
    ?? (NSString(string: "~/.config/lamp-agent/config.toml").expandingTildeInPath)

let config: Config
do {
    config = try Config.load(from: URL(fileURLWithPath: configPath))
} catch {
    FileHandle.standardError.write(Data("lamp-agent: failed to load config at \(configPath): \(error)\n".utf8))
    exit(1)
}

let runOnce = CommandLine.arguments.contains("--once")

await withDependencies {
    $0.homebridgeClient = .live(
        baseURL: config.homebridgeURL,
        token: config.homebridgeToken,
        accessoryId: config.accessoryId
    )
} operation: {
    let loop = Runtime.makePollLoop(config: config)
    do {
        if runOnce {
            let outcome = try await loop.runOnce()
            print("lamp-agent: applied=\(outcome.applied) stale=\(outcome.skippedStale) failed=\(outcome.failed)")
        } else {
            print("lamp-agent: starting poll loop (interval \(config.pollIntervalSeconds)s)")
            try await loop.run(intervalSeconds: config.pollIntervalSeconds)
        }
    } catch {
        FileHandle.standardError.write(Data("lamp-agent: fatal: \(error)\n".utf8))
        exit(1)
    }
}
```

- [ ] **Step 3: Build the executable**

```bash
swift build 2>&1 | tail -10
```

Expected: `Build complete!`.

- [ ] **Step 4: Smoke-test `--once` against a temp config and command file**

```bash
TMP=$(mktemp -d)
cat > "$TMP/config.toml" <<EOF
homebridge_url   = "http://127.0.0.1:8581"
homebridge_token = "unused-in-this-smoke-test"
accessory_id     = "lamp-desk"
commands_path    = "$TMP/commands.json"
poll_interval_s  = 12
EOF
echo "[]" > "$TMP/commands.json"
LAMP_AGENT_CONFIG="$TMP/config.toml" swift run lamp-agent --once 2>&1 | tail -5
```

Expected: prints `lamp-agent: applied=[] stale=[] failed=false` (empty queue → nothing to do, no Homebridge call attempted). Exit 0.

- [ ] **Step 5: Commit**

```bash
git add mac-agent/Sources/LampAgent/Dependencies+Live.swift mac-agent/Sources/lamp-agent/main.swift
git commit -m "feat(mac-agent): wire live dependencies and executable entrypoint"
```

---

## Task 12: launchd LaunchAgent, config template, install scripts

**Agent:** lamp-mac.

**Files:**
- Create: `mac-agent/Resources/config.toml.example`
- Create: `mac-agent/Resources/com.lamp.agent.plist`
- Create: `mac-agent/scripts/install.sh`
- Create: `mac-agent/scripts/uninstall.sh`

- [ ] **Step 1: Write the config template**

Create `mac-agent/Resources/config.toml.example`:

```toml
# Copy to ~/.config/lamp-agent/config.toml and chmod 600.
homebridge_url   = "http://127.0.0.1:8581"
homebridge_token = "REPLACE_WITH_HOMEBRIDGE_REST_TOKEN"
accessory_id     = "REPLACE_WITH_ACCESSORY_UNIQUE_ID"
commands_path    = "~/.local/state/lamp-agent/commands.json"
poll_interval_s  = 12
```

- [ ] **Step 2: Write the LaunchAgent plist**

Create `mac-agent/Resources/com.lamp.agent.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.lamp.agent</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/local/bin/lamp-agent</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>__HOME__/Library/Logs/lamp-agent.log</string>
    <key>StandardErrorPath</key>
    <string>__HOME__/Library/Logs/lamp-agent.log</string>
</dict>
</plist>
```

(`__HOME__` is substituted by `install.sh`, since launchd does not expand `~`.)

- [ ] **Step 3: Write install.sh**

Create `mac-agent/scripts/install.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

# Build a release binary and install lamp-agent as a launchd LaunchAgent.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAC_AGENT_DIR="$(dirname "$SCRIPT_DIR")"

BIN_DEST="/usr/local/bin/lamp-agent"
PLIST_LABEL="com.lamp.agent"
PLIST_DEST="$HOME/Library/LaunchAgents/${PLIST_LABEL}.plist"
CONFIG_DIR="$HOME/.config/lamp-agent"
STATE_DIR="$HOME/.local/state/lamp-agent"

echo "==> Building release binary"
( cd "$MAC_AGENT_DIR" && swift build -c release )
BIN_SRC="$MAC_AGENT_DIR/.build/release/lamp-agent"

echo "==> Installing binary to $BIN_DEST (may prompt for sudo)"
sudo install -m 0755 "$BIN_SRC" "$BIN_DEST"

echo "==> Creating config and state directories"
mkdir -p "$CONFIG_DIR" "$STATE_DIR" "$HOME/Library/Logs"
chmod 700 "$CONFIG_DIR" "$STATE_DIR"
if [ ! -f "$CONFIG_DIR/config.toml" ]; then
    install -m 0600 "$MAC_AGENT_DIR/Resources/config.toml.example" "$CONFIG_DIR/config.toml"
    echo "    Wrote starter config to $CONFIG_DIR/config.toml — edit it before the agent will work."
fi

echo "==> Installing LaunchAgent to $PLIST_DEST"
mkdir -p "$HOME/Library/LaunchAgents"
sed "s|__HOME__|$HOME|g" "$MAC_AGENT_DIR/Resources/com.lamp.agent.plist" > "$PLIST_DEST"

echo "==> Loading the agent"
launchctl bootout "gui/$(id -u)/${PLIST_LABEL}" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST_DEST"
launchctl enable "gui/$(id -u)/${PLIST_LABEL}"

echo "==> Done. Check logs at $HOME/Library/Logs/lamp-agent.log"
```

- [ ] **Step 4: Write uninstall.sh**

Create `mac-agent/scripts/uninstall.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

PLIST_LABEL="com.lamp.agent"
PLIST_DEST="$HOME/Library/LaunchAgents/${PLIST_LABEL}.plist"
BIN_DEST="/usr/local/bin/lamp-agent"

echo "==> Unloading the agent"
launchctl bootout "gui/$(id -u)/${PLIST_LABEL}" 2>/dev/null || true

echo "==> Removing LaunchAgent plist"
rm -f "$PLIST_DEST"

echo "==> Removing binary (may prompt for sudo)"
sudo rm -f "$BIN_DEST"

echo "==> Done. Config and state under ~/.config/lamp-agent and ~/.local/state/lamp-agent were left in place."
```

- [ ] **Step 5: Make scripts executable and syntax-check them**

```bash
chmod +x mac-agent/scripts/install.sh mac-agent/scripts/uninstall.sh
bash -n mac-agent/scripts/install.sh && bash -n mac-agent/scripts/uninstall.sh && echo "scripts OK"
```

Expected: `scripts OK`.

- [ ] **Step 6: Validate the plist parses**

```bash
sed "s|__HOME__|$HOME|g" mac-agent/Resources/com.lamp.agent.plist | plutil -lint - && echo "plist OK"
```

Expected: `... OK` from plutil, then `plist OK`.

- [ ] **Step 7: Commit**

```bash
git add mac-agent/Resources/ mac-agent/scripts/
git commit -m "feat(mac-agent): add launchd LaunchAgent, config template, install scripts"
```

---

## Task 13: deploy-mac-agent.yml (dormant until runner registered)

**Agent:** lamp-ops.

**Files:**
- Create: `.github/workflows/deploy-mac-agent.yml`

- [ ] **Step 1: Write the deploy workflow**

Create `.github/workflows/deploy-mac-agent.yml`:

```yaml
name: deploy-mac-agent

on:
  push:
    branches: [main]
    paths:
      - 'mac-agent/**'
      - '.github/workflows/deploy-mac-agent.yml'

concurrency:
  group: deploy-mac-agent
  cancel-in-progress: false

jobs:
  deploy:
    runs-on: [self-hosted, macOS, lamp-mac]
    defaults:
      run:
        working-directory: mac-agent
    steps:
      - uses: actions/checkout@v4
      - name: Show toolchain
        run: swift --version
      - name: Build, test, install
        run: |
          swift build -c release
          swift test
          ./scripts/install.sh
      - name: Kick the agent
        run: launchctl kickstart -k "gui/$(id -u)/com.lamp.agent"
```

Note: this runs only on the self-hosted `lamp-mac` runner. Until that runner is registered (carryover manual step from Stage 0, documented in `docs/ops/first-time-setup.md`), pushes that touch `mac-agent/**` will queue a `deploy` job that waits for the runner — that is expected and harmless. Do not point this job at a github-hosted runner.

- [ ] **Step 2: Lint the YAML structure**

```bash
cd /Users/volovely/GitHub/lamp-controller
python3 -c "import sys; t=open('.github/workflows/deploy-mac-agent.yml').read(); assert '\t' not in t, 'tabs!'; assert 'self-hosted' in t and 'lamp-mac' in t; print('workflow OK')"
```

Expected: `workflow OK`.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/deploy-mac-agent.yml
git commit -m "ci: add dormant mac-agent deploy workflow for self-hosted runner"
```

---

## Task 14: Stage review (diff)

**Agent:** lamp-reviewer.

**Files:** none (review only).

- [ ] **Step 1: Run the full test suite once more**

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd mac-agent && swift build && swift test 2>&1 | tail -15
```

Expected: build succeeds; every suite passes; zero failures.

- [ ] **Step 2: Review the branch diff against the spec**

```bash
cd /Users/volovely/GitHub/lamp-controller
git diff main...stage-1-mac-to-lamp --stat
```

Have lamp-reviewer read the full diff and check: contract consistency (`color_temp_k` schema ↔ `Command` ↔ executor), `CommandSource` is a clean drop-in seam for Stage 2, error paths don't ack on failure, no secrets committed, commit messages follow `CLAUDE.md` (no AI attribution). Record findings; fix any blocking issues with a follow-up commit before Task 15.

---

## Task 15: Integration verification — the demoable scenario

**Agent:** lamp-integration-verifier. **Requires human-in-the-loop Homebridge setup** (`homebridge/README.md`).

**Files:** none (verification only).

This task can only fully pass once Homebridge is installed and the lamp is bridged (the human-in-the-loop steps from the spec). If that setup is not yet done, run Step 1 (which needs no hardware) and mark Steps 2–3 blocked-on-setup.

- [ ] **Step 1: Dry-run the queue logic with `--once` (no hardware)**

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
TMP=$(mktemp -d)
cat > "$TMP/config.toml" <<EOF
homebridge_url   = "http://127.0.0.1:8581"
homebridge_token = "placeholder"
accessory_id     = "lamp-desk"
commands_path    = "$TMP/commands.json"
poll_interval_s  = 12
EOF
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
echo "[]" > "$TMP/commands.json"
cd mac-agent
LAMP_AGENT_CONFIG="$TMP/config.toml" swift run lamp-agent --once
```

Expected: `applied=[] stale=[] failed=false`. Confirms config load + empty-queue path with no Homebridge dependency.

- [ ] **Step 2: Live demo (requires Homebridge + bridged lamp)**

With Homebridge running, the lamp bridged, and a valid `config.toml` (real token + `accessory_id`):

```bash
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
UUID=$(uuidgen)
cat > ~/.local/state/lamp-agent/commands.json <<EOF
[{"id":"$UUID","action":"on","brightness":30,"color_temp_k":2700,"created_at":"$NOW","source_msg_id":"manual-demo"}]
EOF
LAMP_AGENT_CONFIG=~/.config/lamp-agent/config.toml lamp-agent --once
```

Expected: the lamp turns on at 30% brightness, warm white; output shows `applied=["$UUID"]`; `~/.local/state/lamp-agent/acked.json` now contains the UUID.

- [ ] **Step 3: Idempotency check**

Re-run the same `--once` command without changing `commands.json`.

Expected: `applied=[] stale=[] failed=false` (the command is already acked; the lamp is not re-driven). Capture this as evidence the ack ledger works end-to-end.

- [ ] **Step 4: Record the verification report**

Write a short pass/blocked report: which steps passed, any that are blocked on Homebridge setup, with command output as evidence.

---

## Task 16: Finish the development branch

**Agent:** orchestrator. **REQUIRED SUB-SKILL:** superpowers:finishing-a-development-branch.

- [ ] **Step 1: Confirm tests pass and the branch is clean**

```bash
cd /Users/volovely/GitHub/lamp-controller && git status --short
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
(cd mac-agent && swift build && swift test 2>&1 | tail -5)
```

- [ ] **Step 2: Run finishing-a-development-branch**

Present the merge/PR/keep/discard options. Given the established flow on this repo (direct pushes to `main` are blocked), the expected path is **push branch + open PR**, let CI run (`worker-ci`/`mac-agent-ci` path-filtered; `mac-agent-ci` will run), then squash-merge.

- [ ] **Step 3: After merge, note the open deploy gate**

Remind the user that `deploy-mac-agent.yml` and the live demo (Task 15 Steps 2–3) remain gated on registering the self-hosted `lamp-mac` runner per `docs/ops/first-time-setup.md`.

---

## Definition of done

Stage 1 is complete when **all** of the following are true:

- [ ] `shared/command-schema.json` models `color_temp_k` and no longer has `color`.
- [ ] `mac-agent` builds and `swift test` passes with suites for Command, AckStore, FileCommandSource, ColorTemperature, CommandExecutor, Config, and PollLoop.
- [ ] `lamp-agent --once` against an empty queue prints `applied=[] stale=[] failed=false` and exits 0 with no Homebridge dependency.
- [ ] `CommandExecutor` correctly maps `on`/`off`/`set` to ordered `HomebridgeClient` calls (proven by tests).
- [ ] Stale (>10 min) and already-acked commands are never re-applied (proven by `PollLoop` tests).
- [ ] `homebridge/README.md` documents installing Homebridge, bridging the Mijia lamp, obtaining a token, and the exact REST `PUT` contract.
- [ ] `Resources/com.lamp.agent.plist`, `config.toml.example`, and `scripts/install.sh`/`uninstall.sh` exist and lint clean.
- [ ] `.github/workflows/deploy-mac-agent.yml` targets `[self-hosted, macOS, lamp-mac]`.
- [ ] The branch is merged to `main` via PR with `mac-agent-ci` green.

**Remaining gated on human setup (tracked, not blocking the merge):** Homebridge install + lamp bridging, self-hosted runner registration, and the live demo (Task 15 Steps 2–3) / first real deploy.
