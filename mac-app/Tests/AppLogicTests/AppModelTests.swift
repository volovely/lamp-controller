import Testing
import Foundation
import Dependencies
import LampAgent
@testable import LampController

@MainActor
@Suite("AppModel")
struct AppModelTests {
    private func tempState() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("acked-\(UUID().uuidString).json")
    }

    @Test("runOnceForTesting applies a queued command via the lamp closure")
    func appliesQueued() async throws {
        let stateURL = tempState()
        defer { try? FileManager.default.removeItem(at: stateURL) }

        final class Box: @unchecked Sendable { var states: [LampState] = [] }
        let box = Box()

        let cmd = Command(
            id: "a", action: .on, brightness: 30, colorTempK: 2700,
            durationMinutes: nil, createdAt: Date(timeIntervalSince1970: 1000), sourceMsgId: "m"
        )
        let source = CommandSource(pending: { [cmd] }, ack: { _ in })

        let model = AppModel()
        try await withDependencies {
            $0.date = .constant(Date(timeIntervalSince1970: 1000))
            $0.lampClient = .homeKit { box.states.append($0) }
        } operation: {
            try await model.runOnceForTesting(source: source, ackStorePath: stateURL.path)
        }

        #expect(box.states == [LampState(power: true, brightness: 30, colorTempK: 2700)])
    }

    @Test("start sets running, stop sets stopped")
    func startStop() async {
        let model = AppModel()
        #expect(model.runState == .stopped)
        // start with a never-yielding source so the loop idles; we just check the flag flips.
        model.beginForTesting()
        #expect(model.runState == .running)
        model.stop()
        #expect(model.runState == .stopped)
    }
}
