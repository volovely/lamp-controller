import Foundation
import TOMLKit

public struct Config: Equatable, Sendable {
    public enum Backend: String, Sendable, Equatable {
        case shortcuts
        case homebridge
    }

    public enum ConfigError: Error, Equatable {
        case missingKey(String)
        case invalidURL(String)
        case invalidBackend(String)
    }

    public var commandsPath: String
    public var pollIntervalSeconds: Int
    public var lampBackend: Backend
    public var shortcutPrefix: String
    public var homebridgeURL: URL?
    public var homebridgeToken: String?
    public var accessoryId: String?

    public init(
        commandsPath: String,
        pollIntervalSeconds: Int,
        lampBackend: Backend = .shortcuts,
        shortcutPrefix: String = "Lamp",
        homebridgeURL: URL? = nil,
        homebridgeToken: String? = nil,
        accessoryId: String? = nil
    ) {
        self.commandsPath = commandsPath
        self.pollIntervalSeconds = pollIntervalSeconds
        self.lampBackend = lampBackend
        self.shortcutPrefix = shortcutPrefix
        self.homebridgeURL = homebridgeURL
        self.homebridgeToken = homebridgeToken
        self.accessoryId = accessoryId
    }

    public static func parse(_ text: String) throws -> Config {
        let table = try TOMLTable(string: text)

        func requireString(_ key: String) throws -> String {
            guard let value = table[key]?.string else { throw ConfigError.missingKey(key) }
            return value
        }
        func requireInt(_ key: String) throws -> Int {
            guard let value = table[key]?.int else { throw ConfigError.missingKey(key) }
            return Int(value)
        }
        func optionalString(_ key: String) -> String? {
            table[key]?.string
        }

        let rawPath = try requireString("commands_path")
        let path = (rawPath as NSString).expandingTildeInPath
        let pollInterval = try requireInt("poll_interval_s")

        // lamp_backend — optional, defaults to .shortcuts
        let backend: Backend
        if let rawBackend = optionalString("lamp_backend") {
            guard let parsed = Backend(rawValue: rawBackend) else {
                throw ConfigError.invalidBackend(rawBackend)
            }
            backend = parsed
        } else {
            backend = .shortcuts
        }

        // shortcut_prefix — optional, defaults to "Lamp"
        let prefix = optionalString("shortcut_prefix") ?? "Lamp"

        // Homebridge fields — optional individually
        let urlString = optionalString("homebridge_url")
        let homebridgeURL: URL?
        if let urlString {
            guard let url = URL(string: urlString) else {
                throw ConfigError.invalidURL(urlString)
            }
            homebridgeURL = url
        } else {
            homebridgeURL = nil
        }
        let homebridgeToken = optionalString("homebridge_token")
        let accessoryId = optionalString("accessory_id")

        // Validation: homebridge backend requires all three fields
        if backend == .homebridge {
            if homebridgeURL == nil { throw ConfigError.missingKey("homebridge_url") }
            if homebridgeToken == nil { throw ConfigError.missingKey("homebridge_token") }
            if accessoryId == nil { throw ConfigError.missingKey("accessory_id") }
        }

        return Config(
            commandsPath: path,
            pollIntervalSeconds: pollInterval,
            lampBackend: backend,
            shortcutPrefix: prefix,
            homebridgeURL: homebridgeURL,
            homebridgeToken: homebridgeToken,
            accessoryId: accessoryId
        )
    }

    /// Loads and parses the config file at `url`.
    public static func load(from url: URL) throws -> Config {
        try parse(String(contentsOf: url, encoding: .utf8))
    }
}
