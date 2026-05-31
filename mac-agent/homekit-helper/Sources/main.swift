import Foundation
import HomeKit
import UIKit

// MARK: - Argument parsing

struct Args {
    enum Command {
        case discover
        case setAccessory(name: String, action: Action)
    }
    enum Action {
        case off
        case on(brightness: Int?, colorTempK: Int?)
    }

    let command: Command
    let verbose: Bool

    static func parse(_ argv: [String]) -> Args? {
        var raw = Array(argv.dropFirst()) // drop executable name
        let verbose = raw.contains("--verbose")
        raw.removeAll { $0 == "--verbose" }

        var idx = raw.startIndex
        func next() -> String? {
            guard idx < raw.endIndex else { return nil }
            let v = raw[idx]; raw.formIndex(after: &idx); return v
        }

        guard let first = next() else { return nil }

        switch first {
        case "--discover":
            return Args(command: .discover, verbose: verbose)
        case "--accessory":
            guard let name = next() else {
                fputs("ERROR: --accessory requires a name argument\n", stderr); return nil
            }
            guard let actionArg = next() else {
                fputs("ERROR: expected --on or --off after accessory name\n", stderr); return nil
            }
            switch actionArg {
            case "--off":
                return Args(command: .setAccessory(name: name, action: .off), verbose: verbose)
            case "--on":
                var brightness: Int? = nil
                var colorTempK: Int? = nil
                while let flag = next() {
                    switch flag {
                    case "--brightness":
                        if let v = next(), let i = Int(v) { brightness = i }
                    case "--color-temp-k":
                        if let v = next(), let i = Int(v) { colorTempK = i }
                    default:
                        fputs("WARNING: unknown flag \(flag)\n", stderr)
                    }
                }
                return Args(command: .setAccessory(name: name, action: .on(brightness: brightness, colorTempK: colorTempK)), verbose: verbose)
            default:
                fputs("ERROR: expected --on or --off, got \(actionArg)\n", stderr); return nil
            }
        default:
            fputs("ERROR: unknown command \(first)\n", stderr); return nil
        }
    }
}

var verbose = false
func log(_ s: String) { if verbose { fputs("INFO: \(s)\n", stderr) } }

// MARK: - Result file (lets the caller read success/failure without parsing stdout)

func writeResult(_ code: Int32, _ message: String) {
    if let path = ProcessInfo.processInfo.environment["LAMP_HK_RESULT"] {
        try? "\(code) \(message)\n".data(using: .utf8)?.write(to: URL(fileURLWithPath: path))
    }
}

// MARK: - Helpers

func kelvinToMired(_ k: Int, min miredMin: Int, max miredMax: Int) -> Int {
    let mired = Int((1_000_000.0 / Double(k)).rounded())
    return Swift.max(miredMin, Swift.min(miredMax, mired))
}

func findAccessory(named name: String, in homes: [HMHome]) -> HMAccessory? {
    for home in homes {
        if let acc = home.accessories.first(where: { $0.name == name }) { return acc }
    }
    return nil
}

func findLightbulbService(in accessory: HMAccessory) -> HMService? {
    accessory.services.first(where: { $0.serviceType == HMServiceTypeLightbulb })
}

func findCharacteristic(type: String, in service: HMService) -> HMCharacteristic? {
    service.characteristics.first(where: { $0.characteristicType == type })
}

@discardableResult
func writeCharacteristic(_ char: HMCharacteristic, value: Any) async -> Error? {
    await withCheckedContinuation { cont in
        char.writeValue(value) { error in cont.resume(returning: error) }
    }
}

func readBack(_ char: HMCharacteristic) async -> String {
    await withCheckedContinuation { cont in
        char.readValue { _ in cont.resume(returning: char.value.map { "\($0)" } ?? "nil") }
    }
}

func runDiscover(homes: [HMHome]) {
    if homes.isEmpty { print("No homes found."); return }
    for home in homes {
        print("HOME: \(home.name)")
        for accessory in home.accessories {
            print("  ACCESSORY: \(accessory.name)")
            for service in accessory.services {
                print("    SERVICE: \(service.serviceType) (\(service.name))")
                for char in service.characteristics {
                    var meta = ""
                    if let props = char.metadata {
                        if let minVal = props.minimumValue, let maxVal = props.maximumValue {
                            meta = " [min=\(minVal), max=\(maxVal)]"
                        }
                        if let units = props.units { meta += " units=\(units)" }
                    }
                    let val = char.value.map { "\($0)" } ?? "nil"
                    print("      CHARACTERISTIC: \(char.characteristicType)\(meta) value=\(val)")
                }
            }
        }
    }
}

func runSetAccessory(name: String, action: Args.Action, homes: [HMHome]) async -> Int32 {
    guard let accessory = findAccessory(named: name, in: homes) else {
        fputs("ERROR: accessory '\(name)' not found in any home\n", stderr); return 1
    }
    guard let service = findLightbulbService(in: accessory) else {
        fputs("ERROR: accessory '\(name)' has no lightbulb service\n", stderr); return 1
    }
    log("reachable=\(accessory.isReachable)")

    switch action {
    case .off:
        guard let powerChar = findCharacteristic(type: HMCharacteristicTypePowerState, in: service) else {
            fputs("ERROR: no PowerState characteristic found\n", stderr); return 1
        }
        if let err = await writeCharacteristic(powerChar, value: false) {
            fputs("ERROR: write PowerState=false failed: \(err)\n", stderr); return 1
        }
        if verbose { try? await Task.sleep(nanoseconds: 1_000_000_000); log("read-back On=\(await readBack(powerChar))") }
        print("OK: \(name) turned off")
        return 0

    case .on(let brightness, let colorTempK):
        if let powerChar = findCharacteristic(type: HMCharacteristicTypePowerState, in: service) {
            if let err = await writeCharacteristic(powerChar, value: true) {
                fputs("ERROR: write PowerState=true failed: \(err)\n", stderr); return 1
            }
        }
        if let bVal = brightness,
           let brightnessChar = findCharacteristic(type: HMCharacteristicTypeBrightness, in: service) {
            let clamped = Swift.max(0, Swift.min(100, bVal))
            if let err = await writeCharacteristic(brightnessChar, value: clamped) {
                fputs("ERROR: write Brightness=\(clamped) failed: \(err)\n", stderr); return 1
            }
        }
        if let kVal = colorTempK,
           let ctChar = findCharacteristic(type: HMCharacteristicTypeColorTemperature, in: service) {
            let meta = ctChar.metadata
            let miredMin = meta?.minimumValue.map { Int(truncating: $0) } ?? 140
            let miredMax = meta?.maximumValue.map { Int(truncating: $0) } ?? 500
            let mired = kelvinToMired(kVal, min: miredMin, max: miredMax)
            if let err = await writeCharacteristic(ctChar, value: mired) {
                fputs("ERROR: write ColorTemperature=\(mired) mired failed: \(err)\n", stderr); return 1
            }
        }
        if verbose {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if let pc = findCharacteristic(type: HMCharacteristicTypePowerState, in: service) { log("read-back On=\(await readBack(pc))") }
            if let bc = findCharacteristic(type: HMCharacteristicTypeBrightness, in: service) { log("read-back Brightness=\(await readBack(bc))") }
        }
        print("OK: \(name) turned on" +
              (brightness.map { " brightness=\($0)%" } ?? "") +
              (colorTempK.map { " colorTemp=\($0)K" } ?? ""))
        return 0
    }
}

// MARK: - App delegate
//
// HomeKit writes require a genuinely ACTIVE foreground app — a bare CLI process
// gets HMError Code=80 "Handler does not support background access". So we run a
// real UIApplication and do the HomeKit work in applicationDidBecomeActive, then
// exit. Launch via `open` so LaunchServices gives it foreground identity.

final class AppDelegate: UIResponder, UIApplicationDelegate, HMHomeManagerDelegate {
    var window: UIWindow?
    private var manager: HMHomeManager!
    private var started = false
    private var acted = false

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        verbose = Args.parse(CommandLine.arguments)?.verbose ?? false

        // 1x1 invisible window — enough to become "active" without showing UI.
        let w = UIWindow(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        w.rootViewController = UIViewController()
        w.alpha = 0
        w.makeKeyAndVisible()
        self.window = w

        DispatchQueue.global().asyncAfter(deadline: .now() + 30) {
            fputs("ERROR: timed out waiting for HomeKit (30s)\n", stderr)
            writeResult(2, "timeout"); exit(2)
        }
        return true
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        guard !started else { return }
        started = true
        manager = HMHomeManager()
        manager.delegate = self
        if !manager.homes.isEmpty { proceed() }
    }

    func homeManagerDidUpdateHomes(_ manager: HMHomeManager) { proceed() }

    private func proceed() {
        guard !acted else { return }
        acted = true
        let homes = manager.homes
        guard let args = Args.parse(CommandLine.arguments) else {
            fputs("Usage: --discover | --accessory <name> --off | --accessory <name> --on [--brightness N] [--color-temp-k K] [--verbose]\n", stderr)
            writeResult(1, "bad-args"); exit(1)
        }
        Task { @MainActor in
            let code: Int32
            switch args.command {
            case .discover:
                runDiscover(homes: homes); code = 0
            case .setAccessory(let name, let action):
                code = await runSetAccessory(name: name, action: action, homes: homes)
            }
            writeResult(code, code == 0 ? "ok" : "error")
            exit(code)
        }
    }
}

UIApplicationMain(
    CommandLine.argc,
    CommandLine.unsafeArgv,
    nil,
    NSStringFromClass(AppDelegate.self)
)
