import Foundation
import HomeKit
import LampAgent

/// Owns a long-lived HMHomeManager and applies LampState to the configured
/// accessory. The app is a foreground UIApplication, so HomeKit writes succeed
/// (no Code=80 background error).
@MainActor
final class HomeKitController: NSObject, @preconcurrency HMHomeManagerDelegate, ObservableObject {
    enum State: Equatable {
        case loading
        case ready(accessoryCount: Int, accessoryFound: Bool)
        case denied
    }

    @Published private(set) var state: State = .loading

    private let manager = HMHomeManager()
    private let accessoryName: String
    private var loadContinuations: [CheckedContinuation<Void, Never>] = []
    private var loaded = false

    init(accessoryName: String) {
        self.accessoryName = accessoryName
        super.init()
        manager.delegate = self
    }

    // MARK: HMHomeManagerDelegate

    func homeManagerDidUpdateHomes(_ manager: HMHomeManager) {
        refreshState()
        loaded = true
        let conts = loadContinuations
        loadContinuations.removeAll()
        for c in conts { c.resume() }
    }

    func homeManager(_ manager: HMHomeManager, didUpdate status: HMHomeManagerAuthorizationStatus) {
        if !status.contains(.authorized) {
            state = .denied
        } else {
            refreshState()
        }
    }

    private func refreshState() {
        let all = manager.homes.flatMap(\.accessories)
        let found = all.contains { $0.name == accessoryName }
        state = .ready(accessoryCount: all.count, accessoryFound: found)
    }

    /// Suspends until HMHomeManager has loaded homes at least once.
    func waitUntilLoaded() async {
        if loaded { return }
        await withCheckedContinuation { loadContinuations.append($0) }
    }

    // MARK: Applying state

    enum ApplyError: Error, Equatable {
        case accessoryNotFound(String)
        case noLightbulbService
        case writeFailed(String)
    }

    func apply(_ lamp: LampState) async throws {
        guard let accessory = manager.homes
            .flatMap(\.accessories)
            .first(where: { $0.name == accessoryName })
        else { throw ApplyError.accessoryNotFound(accessoryName) }

        guard let service = accessory.services
            .first(where: { $0.serviceType == HMServiceTypeLightbulb })
        else { throw ApplyError.noLightbulbService }

        func characteristic(_ type: String) -> HMCharacteristic? {
            service.characteristics.first { $0.characteristicType == type }
        }
        func write(_ char: HMCharacteristic, _ value: Any, _ label: String) async throws {
            do { try await char.writeValue(value) }
            catch { throw ApplyError.writeFailed("\(label): \(error.localizedDescription)") }
        }

        if let power = characteristic(HMCharacteristicTypePowerState) {
            try await write(power, lamp.power, "PowerState")
        }
        guard lamp.power else { return }

        if let brightness = characteristic(HMCharacteristicTypeBrightness) {
            try await write(brightness, max(0, min(100, lamp.brightness)), "Brightness")
        }
        if let ct = characteristic(HMCharacteristicTypeColorTemperature) {
            let meta = ct.metadata
            let lo = meta?.minimumValue.map { Int(truncating: $0) } ?? 140
            let hi = meta?.maximumValue.map { Int(truncating: $0) } ?? 500
            let mired = max(lo, min(hi, miredFromKelvin(lamp.colorTempK)))
            try await write(ct, mired, "ColorTemperature")
        }
    }
}
