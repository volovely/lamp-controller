import Foundation

// Process-based helpers are unavailable on Mac Catalyst (no subprocess API there).
// The Catalyst app uses HomeKitController directly instead of launching a helper process.
#if !targetEnvironment(macCatalyst)

/// Runs the signed HomeKit helper app to control a lamp accessory.
/// Injected so the mapping logic is testable without launching a real process.
public struct HomeKitRunner: Sendable {
    public var run: @Sendable (_ helperAppPath: String, _ args: [String]) async throws -> Void
    public init(run: @escaping @Sendable (_ helperAppPath: String, _ args: [String]) async throws -> Void) {
        self.run = run
    }
}

extension HomeKitRunner {
    /// Live runner: `open -W <helperAppPath> --args <args...>`.
    ///
    /// The helper writes `<exitcode> <message>` to the file at `$LAMP_HK_RESULT`.
    /// Exit 0 / result starting with "0" → success.
    /// Non-zero result → `requestFailed(status:)`.
    /// Launch failure → `unreachable`.
    public static let live = HomeKitRunner { helperAppPath, args in
        let resultFile = NSTemporaryDirectory().appending("lamp-hk-result-\(UInt64.random(in: .min ... .max)).txt")
        defer { try? FileManager.default.removeItem(atPath: resultFile) }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-W", helperAppPath, "--args"] + args
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice

            var env = ProcessInfo.processInfo.environment
            env["LAMP_HK_RESULT"] = resultFile
            process.environment = env

            process.terminationHandler = { proc in
                guard proc.terminationStatus == 0 else {
                    continuation.resume(
                        throwing: LampClient.ClientError.requestFailed(
                            status: Int(proc.terminationStatus)
                        )
                    )
                    return
                }

                // Read helper result file
                let resultText = (try? String(contentsOfFile: resultFile, encoding: .utf8))
                    .flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }

                if let result = resultText {
                    if result.hasPrefix("0") {
                        continuation.resume()
                    } else {
                        let code = result.split(separator: " ").first.flatMap { Int($0) } ?? -1
                        continuation.resume(
                            throwing: LampClient.ClientError.requestFailed(status: code)
                        )
                    }
                } else {
                    // No result file written — treat process exit 0 as success
                    continuation.resume()
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
    /// HomeKit helper-app backend.
    ///
    /// For `power == false`, sends `--off`.
    /// For `power == true`, sends `--on --brightness <0...100> --color-temp-k <kelvin>`.
    /// Brightness is clamped to 0...100; colorTempK is passed through (the helper clamps to device mired range).
    public static func homekit(
        helperAppPath: String,
        accessoryName: String,
        runner: HomeKitRunner = .live
    ) -> LampClient {
        LampClient(
            apply: { state in
                let args: [String]
                if state.power {
                    let clampedBrightness = min(100, max(0, state.brightness))
                    args = [
                        "--accessory", accessoryName,
                        "--on",
                        "--brightness", String(clampedBrightness),
                        "--color-temp-k", String(state.colorTempK),
                    ]
                } else {
                    args = ["--accessory", accessoryName, "--off"]
                }
                try await runner.run(helperAppPath, args)
            }
        )
    }
}

#endif // !targetEnvironment(macCatalyst)
