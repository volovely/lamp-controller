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
