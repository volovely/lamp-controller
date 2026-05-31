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
        let source: CommandSource
        switch config.commandSource {
        case .worker:
            // parse() guarantees these are present for the worker source.
            source = .worker(
                baseURL: config.workerURL!,
                sharedSecret: config.sharedSecret!
            )
        case .file:
            source = .file(at: URL(fileURLWithPath: config.commandsPath!))
        }
        return PollLoop(
            source: source,
            executor: .live(),
            ackStore: .file(at: URL(fileURLWithPath: config.statePath))
        )
    }
}
