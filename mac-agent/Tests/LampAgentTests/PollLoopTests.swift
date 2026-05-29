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

    private func command(_ id: String, action: Command.Action = .on, ageSeconds: TimeInterval = 0, brightness: Int? = nil) -> Command {
        Command(id: id, action: action, brightness: brightness, colorTempK: nil, durationMinutes: nil,
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
        try await withKnownIssue {
            try await withDependencies {
                $0.date = .constant(Date(timeIntervalSince1970: 1000))
            } operation: {
                let source = CommandSource(pending: { [a] }, ack: { _ in })
                let executor = CommandExecutor { _ in throw Boom() }
                outcome = try await PollLoop(source: source, executor: executor, ackStore: ackStore).runOnce()
            }
        } matching: { $0.comments.map(\.rawValue).joined().contains("Failed to apply command") }

        #expect(try ackStore.load().isEmpty)
        #expect(outcome?.applied == [])
        #expect(outcome?.failed == true)
    }

    @Test("an invalid command is dropped and acked without executing, and does not mark outcome failed")
    func dropsInvalidWithoutRetry() async throws {
        let ackURL = tempURL(); defer { try? FileManager.default.removeItem(at: ackURL) }
        let executed = Box()
        // brightness: 150 fails validate() — out of range
        let bad = command("bad", brightness: 150)
        let ackStore = AckStore.file(at: ackURL)
        var outcome: PollOutcome?

        // runOnce calls reportIssue for the invalid command; withKnownIssue absorbs it.
        try await withKnownIssue {
            try await withDependencies {
                $0.date = .constant(Date(timeIntervalSince1970: 1000))
            } operation: {
                let source = CommandSource(pending: { [bad] }, ack: { _ in })
                let executor = CommandExecutor { await executed.add($0.id) }
                outcome = try await PollLoop(source: source, executor: executor, ackStore: ackStore).runOnce()
            }
        } matching: { $0.comments.map(\.rawValue).joined().contains("Invalid command") }

        // Must NOT have been executed
        #expect(await executed.ids.isEmpty)
        // Must have been acked (dropped permanently)
        #expect(try ackStore.load().contains("bad"))
        // Must appear in outcome.invalid
        #expect(outcome?.invalid == ["bad"])
        // Must NOT mark the cycle as a transient failure
        #expect(outcome?.failed == false)
    }
}
