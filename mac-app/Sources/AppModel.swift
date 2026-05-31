import Foundation
import Observation
import Dependencies
import LampAgent

private struct ControllerUnavailable: Error {}

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
                    guard let controller else { throw ControllerUnavailable() }
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
