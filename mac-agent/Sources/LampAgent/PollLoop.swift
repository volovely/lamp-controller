import Dependencies
import Foundation
import IssueReporting

public struct PollOutcome: Equatable, Sendable {
    public var applied: [String]
    public var skippedStale: [String]
    public var invalid: [String]
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
    ///
    /// Error handling separates two distinct failure modes:
    /// - **Invalid command** (`validate()` throws): programmer/schema error; the command is
    ///   reported and permanently dropped (acked) so it is never retried.
    /// - **Transient execute failure** (`execute()` throws): e.g. Homebridge unreachable;
    ///   the command is left un-acked so the next poll cycle retries it.
    @discardableResult
    public func runOnce() async throws -> PollOutcome {
        @Dependency(\.date) var date
        let now = date.now

        let acked = try ackStore.load()
        let pending = try await source.pending()

        var applied: [String] = []
        var skippedStale: [String] = []
        var invalid: [String] = []
        var failed = false

        for command in pending where !acked.contains(command.id) {
            if command.isStale(now: now) {
                skippedStale.append(command.id)
                continue
            }

            // Validate first — schema/range errors are permanent; drop and ack without executing.
            do {
                try command.validate()
            } catch {
                reportIssue("Invalid command \(command.id): \(error)")
                invalid.append(command.id)
                continue
            }

            // Execute — a failure here is transient; leave un-acked so the next cycle retries.
            do {
                try await executor.execute(command)
                applied.append(command.id)
            } catch {
                reportIssue("Failed to apply command \(command.id): \(error)")
                failed = true
            }
        }

        // Stale and invalid commands are both permanently dropped; transient-failed are excluded
        // so they retry on the next poll cycle.
        let toAck = applied + skippedStale + invalid
        if !toAck.isEmpty {
            // NOTE: these two writes are not atomic. Stage 2's Worker source.ack (POST /ack)
            // must be idempotent to survive a partial failure between them.
            try ackStore.record(toAck)
            try await source.ack(toAck)
        }

        return PollOutcome(applied: applied, skippedStale: skippedStale, invalid: invalid, failed: failed)
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
