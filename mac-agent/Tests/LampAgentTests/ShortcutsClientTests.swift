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

    @Test("power=true, brightness=30, 2700 K → Lamp Warm 50 (30→50; 2700≤4000 Warm)")
    func warmLow() async throws {
        let box = Box()
        let client = LampClient.shortcuts(prefix: "Lamp", runner: stubRunner(box: box))
        try await client.apply(LampState(power: true, brightness: 30, colorTempK: 2700))
        let ran = await box.ran
        expectNoDifference(ran, ["Lamp Warm 50"])
    }

    @Test("power=true, brightness=80, 6000 K → Lamp Cool 100 (80→100; 6000>4000 Cool)")
    func coolHigh() async throws {
        let box = Box()
        let client = LampClient.shortcuts(prefix: "Lamp", runner: stubRunner(box: box))
        try await client.apply(LampState(power: true, brightness: 80, colorTempK: 6000))
        let ran = await box.ran
        expectNoDifference(ran, ["Lamp Cool 100"])
    }

    @Test("power=true, brightness=75, 5000 K → Lamp Cool 100 (75 ties → rounds up to 100; Cool)")
    func coolTieBreakRoundsUp() async throws {
        let box = Box()
        let client = LampClient.shortcuts(prefix: "Lamp", runner: stubRunner(box: box))
        try await client.apply(LampState(power: true, brightness: 75, colorTempK: 5000))
        let ran = await box.ran
        expectNoDifference(ran, ["Lamp Cool 100"])
    }

    @Test("power=true, brightness=60, 4000 K → Lamp Warm 50 (60→50; 4000≤4000 Warm)")
    func warmBoundary() async throws {
        let box = Box()
        let client = LampClient.shortcuts(prefix: "Lamp", runner: stubRunner(box: box))
        try await client.apply(LampState(power: true, brightness: 60, colorTempK: 4000))
        let ran = await box.ran
        expectNoDifference(ran, ["Lamp Warm 50"])
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
