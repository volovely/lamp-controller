import Foundation
import TOMLKit

public struct Config: Equatable, Sendable {
    public var homebridgeURL: URL
    public var homebridgeToken: String
    public var accessoryId: String
    public var commandsPath: String
    public var pollIntervalSeconds: Int

    public enum ConfigError: Error, Equatable {
        case missingKey(String)
        case invalidURL(String)
    }

    public static func parse(_ text: String) throws -> Config {
        let table = try TOMLTable(string: text)

        func string(_ key: String) throws -> String {
            guard let value = table[key]?.string else { throw ConfigError.missingKey(key) }
            return value
        }
        func int(_ key: String) throws -> Int {
            guard let value = table[key]?.int else { throw ConfigError.missingKey(key) }
            return Int(value)
        }

        let urlString = try string("homebridge_url")
        guard let url = URL(string: urlString) else { throw ConfigError.invalidURL(urlString) }

        let rawPath = try string("commands_path")
        let path = (rawPath as NSString).expandingTildeInPath

        return Config(
            homebridgeURL: url,
            homebridgeToken: try string("homebridge_token"),
            accessoryId: try string("accessory_id"),
            commandsPath: path,
            pollIntervalSeconds: try int("poll_interval_s")
        )
    }

    /// Loads and parses the config file at `url`.
    public static func load(from url: URL) throws -> Config {
        try parse(String(contentsOf: url, encoding: .utf8))
    }
}
