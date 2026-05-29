import Foundation

/// A single lamp command. Mirrors `shared/command-schema.json`.
public struct Command: Codable, Equatable, Identifiable, Sendable {
    public enum Action: String, Codable, Sendable {
        case on, off, set
    }

    public let id: String
    public let action: Action
    public let brightness: Int?
    public let colorTempK: Int?
    public let durationMinutes: Int?
    public let createdAt: Date
    public let sourceMsgId: String

    public init(
        id: String,
        action: Action,
        brightness: Int?,
        colorTempK: Int?,
        durationMinutes: Int?,
        createdAt: Date,
        sourceMsgId: String
    ) {
        self.id = id
        self.action = action
        self.brightness = brightness
        self.colorTempK = colorTempK
        self.durationMinutes = durationMinutes
        self.createdAt = createdAt
        self.sourceMsgId = sourceMsgId
    }

    enum CodingKeys: String, CodingKey {
        case id, action, brightness
        case colorTempK = "color_temp_k"
        case durationMinutes = "duration_minutes"
        case createdAt = "created_at"
        case sourceMsgId = "source_msg_id"
    }

    /// Stale-guard: commands older than 10 minutes are dropped without applying.
    public static let staleAfter: TimeInterval = 600

    public func isStale(now: Date) -> Bool {
        now.timeIntervalSince(createdAt) > Self.staleAfter
    }

    public enum ValidationError: Error, Equatable {
        case brightnessOutOfRange(Int)
        case colorTempOutOfRange(Int)
    }

    /// Enforces field-range invariants. Mapping order/ignoring of fields per
    /// action is the executor's job; this only guards ranges.
    public func validate() throws {
        if let brightness, !(0...100).contains(brightness) {
            throw ValidationError.brightnessOutOfRange(brightness)
        }
        if let colorTempK, !(2700...6500).contains(colorTempK) {
            throw ValidationError.colorTempOutOfRange(colorTempK)
        }
    }

    /// Decoder configured for the contract's RFC3339 / ISO-8601 timestamps.
    public static let jsonDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            guard let date = iso8601.date(from: string) ?? iso8601NoFraction.date(from: string) else {
                throw DecodingError.dataCorruptedError(
                    in: container, debugDescription: "Invalid RFC3339 date: \(string)"
                )
            }
            return date
        }
        return decoder
    }()

    public static let jsonEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(iso8601NoFraction.string(from: date))
        }
        return encoder
    }()

    nonisolated(unsafe) private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    nonisolated(unsafe) private static let iso8601NoFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
