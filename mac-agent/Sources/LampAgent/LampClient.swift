import Dependencies
import DependenciesMacros
import Foundation
import IssueReporting

/// HomeKit ColorTemperature is mired (reciprocal megakelvin), default range 140...500.
public func miredFromKelvin(_ kelvin: Int) -> Int {
    guard kelvin > 0 else { return 500 }
    let mired = Int((1_000_000.0 / Double(kelvin)).rounded())
    return min(500, max(140, mired))
}

/// The fully-resolved desired lamp state, applied in one shot.
public struct LampState: Equatable, Sendable {
    public var power: Bool
    public var brightness: Int
    public var colorTempK: Int
    public init(power: Bool, brightness: Int, colorTempK: Int) {
        self.power = power
        self.brightness = brightness
        self.colorTempK = colorTempK
    }
}

@DependencyClient
public struct LampClient: Sendable {
    public var apply: @Sendable (_ state: LampState) async throws -> Void
}

extension LampClient: TestDependencyKey {
    public static let testValue = LampClient()
}

extension DependencyValues {
    public var lampClient: LampClient {
        get { self[LampClient.self] }
        set { self[LampClient.self] = newValue }
    }
}

extension LampClient {
    public enum ClientError: Error, Equatable {
        case requestFailed(status: Int)
        case unreachable
    }

    /// Homebridge config-ui-x backend.
    /// `apply()` issues On, then (if on) Brightness + ColorTemperature.
    public static func homebridge(
        baseURL: URL,
        token: String,
        accessoryId: String,
        session: URLSession = .shared
    ) -> LampClient {
        let put: @Sendable (String, any Encodable & Sendable) async throws -> Void = { characteristic, value in
            let url = baseURL
                .appendingPathComponent("api/accessories")
                .appendingPathComponent(accessoryId)
            var request = URLRequest(url: url)
            request.httpMethod = "PUT"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.httpBody = try JSONEncoder().encode(
                CharacteristicWrite(characteristicType: characteristic, value: AnyCodable(value))
            )

            let data: Data, response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
            } catch {
                throw ClientError.unreachable
            }
            _ = data
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                throw ClientError.requestFailed(status: status)
            }
        }

        return LampClient { state in
            try await put("On", state.power)
            if state.power {
                try await put("Brightness", min(100, max(0, state.brightness)))
                try await put("ColorTemperature", miredFromKelvin(state.colorTempK))
            }
        }
    }
}

private struct CharacteristicWrite: Encodable {
    let characteristicType: String
    let value: AnyCodable
}

/// Minimal type-erased encodable so one body type covers Bool and Int values.
private struct AnyCodable: Encodable {
    private let encodeTo: @Sendable (inout SingleValueEncodingContainer) throws -> Void
    init(_ value: some Encodable & Sendable) {
        self.encodeTo = { container in try container.encode(value) }
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try encodeTo(&container)
    }
}
