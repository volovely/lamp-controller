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
    private(set) var homeKitState: HomeKitController.State = .loading
    var config: Config?
    var configError: String?

    private var task: Task<Void, Never>?
    private var controller: HomeKitController?

    /// Fired whenever runState / homeKitState / configError changes, so a
    /// non-SwiftUI observer (MenuBarController) can rebuild the menu.
    var onChange: (@MainActor () -> Void)?

    private func notify() { onChange?() }

    // MARK: Config

    func loadConfig() {
        let path = NSString(string: "~/.config/lamp-agent/config.toml").expandingTildeInPath
        do {
            config = try Config.load(from: URL(fileURLWithPath: path))
            configError = nil
            if let name = config?.homekitAccessoryName {
                let c = HomeKitController(accessoryName: name)
                c.onStateChange = { [weak self] state in
                    self?.homeKitState = state
                    self?.notify()
                }
                homeKitState = c.state
                controller = c
            }
        } catch {
            config = nil
            configError = "\(error)"
        }
        // Note: at first launch this fires before any observer wires `onChange`
        // (AppDelegate calls loadConfig() before constructing MenuBarController),
        // so the initial paint relies on MenuBarController.init calling rebuild()
        // itself. Observers registered later (or in tests) do receive this.
        notify()
    }

    var homeKitController: HomeKitController? { controller }

    /// Pure decision used by `autoStart()`. Auto-start only when config loaded
    /// and HomeKit has finished loading into a `.ready` state. `start()` re-guards
    /// worker config and is idempotent, so this stays minimal.
    static func shouldAutoStart(hasConfig: Bool, homeKit: HomeKitController.State) -> Bool {
        guard hasConfig else { return false }
        if case .ready = homeKit { return true }
        return false
    }

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
        log("polling started (every \(interval)s)")
        notify()

        task = Task { [weak self] in
            await withDependencies {
                $0.lampClient = .homeKit { [weak self, weak controller] state in
                    guard let controller else { throw ControllerUnavailable() }
                    try await controller.apply(state)
                    let msg = state.power
                        ? "lamp on — \(state.brightness)% \(state.colorTempK)K"
                        : "lamp off"
                    await self?.log(msg)
                }
            } operation: {
                // Drive the poll loop from AppModel so we can log each cycle's outcome.
                // idleLogged prevents log spam: we only emit "waiting for commands…" once
                // after a burst of activity (or on first idle after start).
                var idleLogged = false
                while !Task.isCancelled {
                    do {
                        let outcome = try await loop.runOnce()
                        let hasActivity = !outcome.applied.isEmpty
                            || !outcome.skippedStale.isEmpty
                            || !outcome.invalid.isEmpty

                        if hasActivity {
                            // Log the command-level summary (lamp-state detail is logged
                            // inside the lampClient closure above).
                            if !outcome.applied.isEmpty {
                                await self?.log("applied \(outcome.applied.count) command(s)")
                            }
                            if !outcome.skippedStale.isEmpty {
                                await self?.log("dropped \(outcome.skippedStale.count) stale command(s)")
                            }
                            if !outcome.invalid.isEmpty {
                                await self?.log("dropped \(outcome.invalid.count) invalid command(s)")
                            }
                            idleLogged = false
                        } else if !idleLogged {
                            await self?.log("waiting for commands…")
                            idleLogged = true
                        }

                        if outcome.failed {
                            await self?.log("poll error: executor failed (will retry)")
                        }
                    } catch is CancellationError {
                        break
                    } catch {
                        await self?.log("poll error: \(error)")
                    }
                    do {
                        try await Task.sleep(for: .seconds(interval))
                    } catch {
                        break
                    }
                }
            }
            await self?.markStopped()
        }
    }

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

    func stop() {
        task?.cancel()
        task = nil
        runState = .stopped
        log("stopped")
        notify()
    }

    private func markStopped() {
        if runState == .running { runState = .stopped; notify() }
    }

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
