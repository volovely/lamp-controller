import CustomDump
import Testing
@testable import LampAgent

// MARK: - Recording stub

/// Thread-safe box that records every (helperAppPath, args) call to the stub runner.
private actor CallBox {
    private(set) var calls: [(helperAppPath: String, args: [String])] = []
    func append(helperAppPath: String, args: [String]) {
        calls.append((helperAppPath: helperAppPath, args: args))
    }
}

/// A `HomeKitRunner` that records calls and succeeds immediately.
private func stubRunner(box: CallBox) -> HomeKitRunner {
    HomeKitRunner { helperAppPath, args in
        await box.append(helperAppPath: helperAppPath, args: args)
    }
}

// MARK: - Suite

@Suite("LampClient.homekit — arg building")
struct HomeKitClientTests {

    // MARK: Power on

    @Test("power=true, brightness=30, colorTempK=2700 → --on with exact values")
    func powerOnWarm() async throws {
        let box = CallBox()
        let client = LampClient.homekit(
            helperAppPath: "/x/Helper.app",
            accessoryName: "Lamp",
            runner: stubRunner(box: box)
        )
        try await client.apply(LampState(power: true, brightness: 30, colorTempK: 2700))

        let calls = await box.calls
        #expect(calls.count == 1)
        expectNoDifference(calls[0].helperAppPath, "/x/Helper.app")
        expectNoDifference(
            calls[0].args,
            ["--accessory", "Lamp", "--on", "--brightness", "30", "--color-temp-k", "2700"]
        )
    }

    // MARK: Power off

    @Test("power=false → --off (brightness and colorTempK ignored)")
    func powerOff() async throws {
        let box = CallBox()
        let client = LampClient.homekit(
            helperAppPath: "/x/Helper.app",
            accessoryName: "Lamp",
            runner: stubRunner(box: box)
        )
        try await client.apply(LampState(power: false, brightness: 50, colorTempK: 4000))

        let calls = await box.calls
        #expect(calls.count == 1)
        expectNoDifference(calls[0].args, ["--accessory", "Lamp", "--off"])
    }

    // MARK: Brightness clamp

    @Test("brightness > 100 is clamped to 100")
    func brightnessClampHigh() async throws {
        let box = CallBox()
        let client = LampClient.homekit(
            helperAppPath: "/x/Helper.app",
            accessoryName: "Lamp",
            runner: stubRunner(box: box)
        )
        try await client.apply(LampState(power: true, brightness: 150, colorTempK: 5000))

        let calls = await box.calls
        #expect(calls.count == 1)
        expectNoDifference(
            calls[0].args,
            ["--accessory", "Lamp", "--on", "--brightness", "100", "--color-temp-k", "5000"]
        )
    }

    @Test("brightness < 0 is clamped to 0")
    func brightnessClampLow() async throws {
        let box = CallBox()
        let client = LampClient.homekit(
            helperAppPath: "/x/Helper.app",
            accessoryName: "Lamp",
            runner: stubRunner(box: box)
        )
        try await client.apply(LampState(power: true, brightness: -10, colorTempK: 3000))

        let calls = await box.calls
        #expect(calls.count == 1)
        expectNoDifference(
            calls[0].args,
            ["--accessory", "Lamp", "--on", "--brightness", "0", "--color-temp-k", "3000"]
        )
    }

    // MARK: colorTempK pass-through

    @Test("colorTempK is passed through as-is (no mired conversion)")
    func colorTempPassThrough() async throws {
        let box = CallBox()
        let client = LampClient.homekit(
            helperAppPath: "/x/Helper.app",
            accessoryName: "Lamp",
            runner: stubRunner(box: box)
        )
        try await client.apply(LampState(power: true, brightness: 50, colorTempK: 6500))

        let calls = await box.calls
        #expect(calls.count == 1)
        let colorTempArg = calls[0].args.last
        expectNoDifference(colorTempArg, "6500")
    }

    // MARK: Accessory name

    @Test("accessory name is forwarded correctly")
    func accessoryNameForwarded() async throws {
        let box = CallBox()
        let client = LampClient.homekit(
            helperAppPath: "/x/Helper.app",
            accessoryName: "Mijia desk lamp 1S",
            runner: stubRunner(box: box)
        )
        try await client.apply(LampState(power: true, brightness: 50, colorTempK: 4000))

        let calls = await box.calls
        #expect(calls.count == 1)
        let accessoryArgIndex = calls[0].args.firstIndex(of: "--accessory").map { $0 + 1 }
        #expect(accessoryArgIndex != nil)
        expectNoDifference(calls[0].args[accessoryArgIndex!], "Mijia desk lamp 1S")
    }
}
