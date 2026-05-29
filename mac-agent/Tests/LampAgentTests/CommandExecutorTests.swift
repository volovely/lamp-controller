import Dependencies
import Foundation
import Testing
@testable import LampAgent

@Suite("CommandExecutor")
struct CommandExecutorTests {
    /// Records the ordered calls made to HomebridgeClient.
    actor Recorder {
        enum Call: Equatable { case power(Bool), brightness(Int), colorTemp(Int) }
        private(set) var calls: [Call] = []
        func append(_ call: Call) { calls.append(call) }
    }

    private func makeClient(_ recorder: Recorder) -> HomebridgeClient {
        HomebridgeClient(
            setPower: { await recorder.append(.power($0)) },
            setBrightness: { await recorder.append(.brightness($0)) },
            setColorTemperature: { await recorder.append(.colorTemp($0)) }
        )
    }

    private func command(_ action: Command.Action, brightness: Int? = nil, colorTempK: Int? = nil) -> Command {
        Command(id: "a", action: action, brightness: brightness, colorTempK: colorTempK,
                durationMinutes: nil, createdAt: .init(timeIntervalSince1970: 0), sourceMsgId: "m")
    }

    @Test("on with brightness and temp sets power first, then brightness, then temp")
    func onFull() async throws {
        let recorder = Recorder()
        try await withDependencies {
            $0.homebridgeClient = makeClient(recorder)
        } operation: {
            try await CommandExecutor.live().execute(command(.on, brightness: 30, colorTempK: 2700))
        }
        #expect(await recorder.calls == [.power(true), .brightness(30), .colorTemp(2700)])
    }

    @Test("off only powers off, ignoring other fields")
    func off() async throws {
        let recorder = Recorder()
        try await withDependencies {
            $0.homebridgeClient = makeClient(recorder)
        } operation: {
            try await CommandExecutor.live().execute(command(.off, brightness: 80, colorTempK: 4000))
        }
        #expect(await recorder.calls == [.power(false)])
    }

    @Test("set adjusts brightness and temp without touching power")
    func set() async throws {
        let recorder = Recorder()
        try await withDependencies {
            $0.homebridgeClient = makeClient(recorder)
        } operation: {
            try await CommandExecutor.live().execute(command(.set, brightness: 55, colorTempK: 5000))
        }
        #expect(await recorder.calls == [.brightness(55), .colorTemp(5000)])
    }
}
