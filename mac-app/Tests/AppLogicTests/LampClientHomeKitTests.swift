import Testing
import LampAgent
@testable import LampController

@Suite("LampClient.homeKit")
struct LampClientHomeKitTests {
    @Test("apply forwards the exact LampState to the apply closure")
    func forwards() async throws {
        final class Box: @unchecked Sendable { var states: [LampState] = [] }
        let box = Box()
        let client = LampClient.homeKit { state in box.states.append(state) }

        try await client.apply(LampState(power: true, brightness: 30, colorTempK: 2700))
        try await client.apply(LampState(power: false, brightness: 0, colorTempK: 4000))

        #expect(box.states == [
            LampState(power: true, brightness: 30, colorTempK: 2700),
            LampState(power: false, brightness: 0, colorTempK: 4000),
        ])
    }
}
