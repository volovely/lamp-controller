import Dependencies
import Foundation

extension LampClient: DependencyKey {
    /// Unimplemented by default — the executable injects a configured live
    /// client via `withDependencies`. Tests inject their own stub.
    public static var liveValue: LampClient { LampClient() }
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
