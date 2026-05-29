import Foundation

/// Runs a named macOS Shortcut. Injected so the mapping logic is testable.
public struct ShortcutRunner: Sendable {
    public var run: @Sendable (_ name: String) async throws -> Void
    public init(run: @escaping @Sendable (_ name: String) async throws -> Void) {
        self.run = run
    }
}

extension ShortcutRunner {
    /// Live runner: `/usr/bin/shortcuts run "<name>"`.
    /// Non-zero exit → `requestFailed(status:)`; launch failure → `unreachable`.
    public static let live = ShortcutRunner { name in
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
            process.arguments = ["run", name]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { proc in
                if proc.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(
                        throwing: LampClient.ClientError.requestFailed(
                            status: Int(proc.terminationStatus)
                        )
                    )
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: LampClient.ClientError.unreachable)
            }
        }
    }
}

extension LampClient {
    /// Shortcuts backend. Maps a `LampState` to one combined preset shortcut and runs it.
    /// - `power == false` → `"<prefix> Off"`
    /// - `power == true`  → `"<prefix> <Warm|Neutral|Cool> <25|50|100>"`
    public static func shortcuts(
        prefix: String = "Lamp",
        runner: ShortcutRunner = .live
    ) -> LampClient {
        LampClient(
            apply: { state in
                guard state.power else {
                    try await runner.run("\(prefix) Off")
                    return
                }
                let level = nearestBrightnessLevel(state.brightness)
                let bucket = colorBucket(state.colorTempK)
                try await runner.run("\(prefix) \(bucket) \(level)")
            }
        )
    }
}

// MARK: - Mapping helpers (internal so @testable import can reach them)

/// Snaps `brightness` (0–100) to the nearest preset level: 25, 50, or 100.
func nearestBrightnessLevel(_ brightness: Int) -> Int {
    let levels = [25, 50, 100]
    return levels.min(by: { abs($0 - brightness) < abs($1 - brightness) }) ?? 100
}

/// Classifies a color temperature in kelvin into a named bucket.
/// ≤ 3300 K → Warm, 3301–4800 K → Neutral, > 4800 K → Cool.
func colorBucket(_ kelvin: Int) -> String {
    switch kelvin {
    case ...3300:       return "Warm"
    case 3301...4800:   return "Neutral"
    default:            return "Cool"
    }
}
