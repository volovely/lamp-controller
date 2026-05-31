import Foundation
import HomeKit

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

    static func parse(_ argv: [String]) -> Args? {
        var args = argv.dropFirst() // drop executable name
        var idx = args.startIndex

        func next() -> String? {
            guard idx < args.endIndex else { return nil }
            let v = args[idx]
            args.formIndex(after: &idx)
            return v
        }

        guard let first = next() else { return nil }

        switch first {
        case "--discover":
            return Args(command: .discover)
        case "--accessory":
            guard let name = next() else {
                fputs("ERROR: --accessory requires a name argument\n", stderr)
                return nil
            }
            guard let actionArg = next() else {
                fputs("ERROR: expected --on or --off after accessory name\n", stderr)
                return nil
            }
            switch actionArg {
            case "--off":
                return Args(command: .setAccessory(name: name, action: .off))
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
                return Args(command: .setAccessory(name: name, action: .on(brightness: brightness, colorTempK: colorTempK)))
            default:
                fputs("ERROR: expected --on or --off, got \(actionArg)\n", stderr)
                return nil
            }
        default:
            fputs("ERROR: unknown command \(first)\n", stderr)
            return nil
        }
    }
}

// MARK: - HomeKit manager delegate

final class HomeKitManager: NSObject, HMHomeManagerDelegate {
    private let manager = HMHomeManager()
    private var continuation: CheckedContinuation<[HMHome], Never>?

    override init() {
        super.init()
        manager.delegate = self
    }

    func homeManagerDidUpdateHomes(_ manager: HMHomeManager) {
        continuation?.resume(returning: manager.homes)
        continuation = nil
    }

    func waitForHomes() async -> [HMHome] {
        // If homes are already loaded, return immediately.
        if !manager.homes.isEmpty {
            return manager.homes
        }
        return await withCheckedContinuation { cont in
            self.continuation = cont
        }
    }
}

// MARK: - Helpers

func kelvinToMired(_ k: Int, min miredMin: Int, max miredMax: Int) -> Int {
    let mired = Int((1_000_000.0 / Double(k)).rounded())
    return Swift.max(miredMin, Swift.min(miredMax, mired))
}

func findAccessory(named name: String, in homes: [HMHome]) -> HMAccessory? {
    for home in homes {
        if let acc = home.accessories.first(where: { $0.name == name }) {
            return acc
        }
    }
    return nil
}

func findLightbulbService(in accessory: HMAccessory) -> HMService? {
    return accessory.services.first(where: { $0.serviceType == HMServiceTypeLightbulb })
}

func findCharacteristic(type: String, in service: HMService) -> HMCharacteristic? {
    return service.characteristics.first(where: { $0.characteristicType == type })
}

@discardableResult
func writeCharacteristic(_ char: HMCharacteristic, value: Any) async -> Error? {
    return await withCheckedContinuation { cont in
        char.writeValue(value) { error in
            cont.resume(returning: error)
        }
    }
}

// MARK: - Commands

func runDiscover(homes: [HMHome]) {
    if homes.isEmpty {
        print("No homes found.")
        return
    }
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
                        if let units = props.units {
                            meta += " units=\(units)"
                        }
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
        fputs("ERROR: accessory '\(name)' not found in any home\n", stderr)
        return 1
    }
    guard let service = findLightbulbService(in: accessory) else {
        fputs("ERROR: accessory '\(name)' has no lightbulb service\n", stderr)
        return 1
    }

    switch action {
    case .off:
        guard let powerChar = findCharacteristic(type: HMCharacteristicTypePowerState, in: service) else {
            fputs("ERROR: no PowerState characteristic found\n", stderr)
            return 1
        }
        if let err = await writeCharacteristic(powerChar, value: false) {
            fputs("ERROR: write PowerState=false failed: \(err)\n", stderr)
            return 1
        }
        print("OK: \(name) turned off")
        return 0

    case .on(let brightness, let colorTempK):
        // 1. Power on
        if let powerChar = findCharacteristic(type: HMCharacteristicTypePowerState, in: service) {
            if let err = await writeCharacteristic(powerChar, value: true) {
                fputs("ERROR: write PowerState=true failed: \(err)\n", stderr)
                return 1
            }
        }

        // 2. Brightness
        if let bVal = brightness,
           let brightnessChar = findCharacteristic(type: HMCharacteristicTypeBrightness, in: service) {
            let clamped = Swift.max(0, Swift.min(100, bVal))
            if let err = await writeCharacteristic(brightnessChar, value: clamped) {
                fputs("ERROR: write Brightness=\(clamped) failed: \(err)\n", stderr)
                return 1
            }
        }

        // 3. Color temperature
        if let kVal = colorTempK,
           let ctChar = findCharacteristic(type: HMCharacteristicTypeColorTemperature, in: service) {
            let meta = ctChar.metadata
            let miredMin = meta?.minimumValue.map { Int(truncating: $0) } ?? 140
            let miredMax = meta?.maximumValue.map { Int(truncating: $0) } ?? 500
            let mired = kelvinToMired(kVal, min: miredMin, max: miredMax)
            if let err = await writeCharacteristic(ctChar, value: mired) {
                fputs("ERROR: write ColorTemperature=\(mired) mired failed: \(err)\n", stderr)
                return 1
            }
        }

        print("OK: \(name) turned on" +
              (brightness.map { " brightness=\($0)%" } ?? "") +
              (colorTempK.map { " colorTemp=\($0)K" } ?? ""))
        return 0
    }
}

// MARK: - Entry point

let parsedArgs = Args.parse(CommandLine.arguments)
guard let args = parsedArgs else {
    fputs("Usage:\n", stderr)
    fputs("  LampHomeKitHelper --discover\n", stderr)
    fputs("  LampHomeKitHelper --accessory \"<name>\" --off\n", stderr)
    fputs("  LampHomeKitHelper --accessory \"<name>\" --on [--brightness 0-100] [--color-temp-k 2700-6500]\n", stderr)
    exit(1)
}

// Watchdog: exit(2) after 15 seconds
let watchdog = DispatchSource.makeTimerSource(queue: .global())
watchdog.schedule(deadline: .now() + 15)
watchdog.setEventHandler {
    fputs("ERROR: timed out waiting for HomeKit (15s)\n", stderr)
    exit(2)
}
watchdog.resume()

let exitCode: Int32 = await {
    let hmManager = HomeKitManager()
    let homes = await hmManager.waitForHomes()

    switch args.command {
    case .discover:
        runDiscover(homes: homes)
        return 0
    case .setAccessory(let name, let action):
        return await runSetAccessory(name: name, action: action, homes: homes)
    }
}()

exit(exitCode)
