import Dependencies
import DependenciesMacros
import Foundation
import IssueReporting

/// HomeKit `ColorTemperature` is expressed in mired (reciprocal megakelvin),
/// default range 140...500. Convert and clamp.
public func miredFromKelvin(_ kelvin: Int) -> Int {
    guard kelvin > 0 else { return 500 }
    let mired = Int((1_000_000.0 / Double(kelvin)).rounded())
    return min(500, max(140, mired))
}

/// Drives a single lamp accessory through the homebridge-config-ui-x REST API.
@DependencyClient
public struct HomebridgeClient: Sendable {
    public var setPower: @Sendable (_ on: Bool) async throws -> Void
    public var setBrightness: @Sendable (_ percent: Int) async throws -> Void
    public var setColorTemperature: @Sendable (_ kelvin: Int) async throws -> Void
}

extension HomebridgeClient: TestDependencyKey {
    public static let testValue = HomebridgeClient()
}

extension DependencyValues {
    public var homebridgeClient: HomebridgeClient {
        get { self[HomebridgeClient.self] }
        set { self[HomebridgeClient.self] = newValue }
    }
}

extension HomebridgeClient {
    public enum ClientError: Error, Equatable {
        case requestFailed(status: Int)
        case unreachable
    }

    /// Live implementation. Endpoints/auth per `homebridge/README.md` (Task 1):
    /// `PUT {baseURL}/api/accessories/{accessoryId}` with a bearer token and
    /// body `{ "characteristicType": <name>, "value": <bool|int> }`.
    public static func live(
        baseURL: URL,
        token: String,
        accessoryId: String,
        session: URLSession = .shared
    ) -> HomebridgeClient {
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

        return HomebridgeClient(
            setPower: { on in try await put("On", on) },
            setBrightness: { percent in try await put("Brightness", min(100, max(0, percent))) },
            setColorTemperature: { kelvin in try await put("ColorTemperature", miredFromKelvin(kelvin)) }
        )
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
