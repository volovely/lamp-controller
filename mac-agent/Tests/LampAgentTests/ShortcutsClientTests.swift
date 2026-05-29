import CustomDump
import Testing
@testable import LampAgent

// MARK: - Recording stub

/// Thread-safe box that records shortcut names passed to the stub runner.
private actor Box {
    private(set) var ran: [String] = []
    func append(_ name: String) { ran.append(name) }
}

/// A `ShortcutRunner` that appends every name it receives to `box`.
private func stubRunner(box: Box) -> ShortcutRunner {
    ShortcutRunner { name in
        await box.append(name)
    }
}

// MARK: - Suite

@Suite("LampClient.shortcuts — name mapping")
struct ShortcutsClientTests {

    // MARK: brightness snap + color bucket

    @Test("power=true, brightness=30, 2700 K → Lamp Warm 25")
    func warmLow() async throws {
        let box = Box()
        let client = LampClient.shortcuts(prefix: "Lamp", runner: stubRunner(box: box))
        try await client.apply(LampState(power: true, brightness: 30, colorTempK: 2700))
        let ran = await box.ran
        expectNoDifference(ran, ["Lamp Warm 25"])
    }

    @Test("power=true, brightness=60, 4000 K → Lamp Neutral 50")
    func neutralMid() async throws {
        let box = Box()
        let client = LampClient.shortcuts(prefix: "Lamp", runner: stubRunner(box: box))
        try await client.apply(LampState(power: true, brightness: 60, colorTempK: 4000))
        let ran = await box.ran
        expectNoDifference(ran, ["Lamp Neutral 50"])
    }

    @Test("power=true, brightness=90, 6000 K → Lamp Cool 100")
    func coolHigh() async throws {
        let box = Box()
        let client = LampClient.shortcuts(prefix: "Lamp", runner: stubRunner(box: box))
        try await client.apply(LampState(power: true, brightness: 90, colorTempK: 6000))
        let ran = await box.ran
        expectNoDifference(ran, ["Lamp Cool 100"])
    }

    @Test("power=true, brightness=37, 5000 K → Lamp Cool 25 (37 snaps to nearest 25)")
    func coolSnapTo25() async throws {
        let box = Box()
        let client = LampClient.shortcuts(prefix: "Lamp", runner: stubRunner(box: box))
        try await client.apply(LampState(power: true, brightness: 37, colorTempK: 5000))
        let ran = await box.ran
        expectNoDifference(ran, ["Lamp Cool 25"])
    }

    @Test("power=true, brightness=75, 2700 K → Lamp Warm 100 (tie-break rounds up)")
    func warmTieBreakRoundsUp() async throws {
        let box = Box()
        let client = LampClient.shortcuts(prefix: "Lamp", runner: stubRunner(box: box))
        try await client.apply(LampState(power: true, brightness: 75, colorTempK: 2700))
        let ran = await box.ran
        expectNoDifference(ran, ["Lamp Warm 100"])
    }

    @Test("power=false → Lamp Off (brightness and color ignored)")
    func off() async throws {
        let box = Box()
        let client = LampClient.shortcuts(prefix: "Lamp", runner: stubRunner(box: box))
        try await client.apply(LampState(power: false, brightness: 50, colorTempK: 4000))
        let ran = await box.ran
        expectNoDifference(ran, ["Lamp Off"])
    }
}
