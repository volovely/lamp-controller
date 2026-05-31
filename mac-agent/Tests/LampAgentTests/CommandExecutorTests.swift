import Dependencies
import Foundation
import Testing
@testable import LampAgent

@Suite("CommandExecutor")
struct CommandExecutorTests {
    /// Records the LampState passed to apply.
    actor Recorder {
        private(set) var states: [LampState] = []
        func append(_ state: LampState) { states.append(state) }
    }

    private func makeClient(_ recorder: Recorder) -> LampClient {
        LampClient { state in
            await recorder.append(state)
        }
    }

    private func command(_ action: Command.Action, brightness: Int? = nil, colorTempK: Int? = nil) -> Command {
        Command(id: "a", action: action, brightness: brightness, colorTempK: colorTempK,
                durationMinutes: nil, createdAt: .init(timeIntervalSince1970: 0), sourceMsgId: "m")
    }

    @Test("on with nil brightness and nil colorTempK resolves to defaults (100, 2700)")
    func onDefaults() async throws {
        let recorder = Recorder()
        try await withDependencies {
            $0.lampClient = makeClient(recorder)
        } operation: {
            try await CommandExecutor.live().execute(command(.on, brightness: nil, colorTempK: nil))
        }
        #expect(await recorder.states == [LampState(power: true, brightness: 100, colorTempK: 2700)])
    }

    @Test("on with brightness and temp resolves to power=true with given brightness and colorTempK")
    func onFull() async throws {
        let recorder = Recorder()
        try await withDependencies {
            $0.lampClient = makeClient(recorder)
        } operation: {
            try await CommandExecutor.live().execute(command(.on, brightness: 30, colorTempK: 2700))
        }
        #expect(await recorder.states == [LampState(power: true, brightness: 30, colorTempK: 2700)])
    }

    @Test("off resolves to power=false, using command brightness and colorTempK when provided")
    func off() async throws {
        let recorder = Recorder()
        try await withDependencies {
            $0.lampClient = makeClient(recorder)
        } operation: {
            try await CommandExecutor.live().execute(command(.off, brightness: 80, colorTempK: 4000))
        }
        // power=false; brightness and colorTempK come from the command (not defaults) since they are present
        #expect(await recorder.states == [LampState(power: false, brightness: 80, colorTempK: 4000)])
    }

    @Test("set resolves to power=true with given brightness and colorTempK")
    func set() async throws {
        let recorder = Recorder()
        try await withDependencies {
            $0.lampClient = makeClient(recorder)
        } operation: {
            try await CommandExecutor.live().execute(command(.set, brightness: 55, colorTempK: 5000))
        }
        #expect(await recorder.states == [LampState(power: true, brightness: 55, colorTempK: 5000)])
    }
}
