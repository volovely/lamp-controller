import Foundation
import TOMLKit

public struct Config: Equatable, Sendable {
    public enum Backend: String, Sendable, Equatable {
        case shortcuts
        case homebridge
        case homekit
    }

    public enum CommandSourceKind: String, Sendable, Equatable {
        case worker
        case file
    }

    public enum ConfigError: Error, Equatable {
        case missingKey(String)
        case invalidURL(String)
        case invalidBackend(String)
    }

    public var commandsPath: String?
    public var statePath: String
    public var pollIntervalSeconds: Int
    public var commandSource: CommandSourceKind
    public var workerURL: URL?
    public var sharedSecret: String?
    public var lampBackend: Backend
    public var shortcutPrefix: String
    public var homebridgeURL: URL?
    public var homebridgeToken: String?
    public var accessoryId: String?
    public var homekitHelperPath: String?
    public var homekitAccessoryName: String?

    public init(
        commandsPath: String? = nil,
        statePath: String,
        pollIntervalSeconds: Int,
        commandSource: CommandSourceKind = .worker,
        workerURL: URL? = nil,
        sharedSecret: String? = nil,
        lampBackend: Backend = .homekit,
        shortcutPrefix: String = "Lamp",
        homebridgeURL: URL? = nil,
        homebridgeToken: String? = nil,
        accessoryId: String? = nil,
        homekitHelperPath: String? = nil,
        homekitAccessoryName: String? = nil
    ) {
        self.commandsPath = commandsPath
        self.statePath = statePath
        self.pollIntervalSeconds = pollIntervalSeconds
        self.commandSource = commandSource
        self.workerURL = workerURL
        self.sharedSecret = sharedSecret
        self.lampBackend = lampBackend
        self.shortcutPrefix = shortcutPrefix
        self.homebridgeURL = homebridgeURL
        self.homebridgeToken = homebridgeToken
        self.accessoryId = accessoryId
        self.homekitHelperPath = homekitHelperPath
        self.homekitAccessoryName = homekitAccessoryName
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

        let pollInterval = try requireInt("poll_interval_s")

        // command_source — optional, defaults to .worker
        let commandSource: CommandSourceKind
        if let raw = optionalString("command_source") {
            guard let parsed = CommandSourceKind(rawValue: raw) else {
                throw ConfigError.invalidBackend(raw)
            }
            commandSource = parsed
        } else {
            commandSource = .worker
        }

        // commands_path — required only for the file source
        let commandsPath = optionalString("commands_path").map { ($0 as NSString).expandingTildeInPath }
        if commandSource == .file, commandsPath == nil {
            throw ConfigError.missingKey("commands_path")
        }

        // worker_url + shared_secret — required only for the worker source
        let workerURLString = optionalString("worker_url")
        let workerURL: URL?
        if let workerURLString {
            guard let url = URL(string: workerURLString) else {
                throw ConfigError.invalidURL(workerURLString)
            }
            workerURL = url
        } else {
            workerURL = nil
        }
        let sharedSecret = optionalString("shared_secret")
        if commandSource == .worker {
            if workerURL == nil { throw ConfigError.missingKey("worker_url") }
            if sharedSecret == nil { throw ConfigError.missingKey("shared_secret") }
        }

        // state_path — where acked.json lives; defaults under ~/.local/state
        let statePath = (optionalString("state_path")
            ?? "~/.local/state/lamp-agent/acked.json")
        let expandedStatePath = (statePath as NSString).expandingTildeInPath

        // lamp_backend — optional, defaults to .homekit
        let backend: Backend
        if let rawBackend = optionalString("lamp_backend") {
            guard let parsed = Backend(rawValue: rawBackend) else {
                throw ConfigError.invalidBackend(rawBackend)
            }
            backend = parsed
        } else {
            backend = .homekit
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

        // HomeKit fields — optional individually, but both required together
        let rawHelperPath = optionalString("homekit_helper_path")
        let homekitHelperPath = rawHelperPath.map { ($0 as NSString).expandingTildeInPath }
        let homekitAccessoryName = optionalString("homekit_accessory_name")

        // Validation: homekit backend requires both fields
        if backend == .homekit {
            if homekitHelperPath == nil { throw ConfigError.missingKey("homekit_helper_path") }
            if homekitAccessoryName == nil { throw ConfigError.missingKey("homekit_accessory_name") }
        }

        return Config(
            commandsPath: commandsPath,
            statePath: expandedStatePath,
            pollIntervalSeconds: pollInterval,
            commandSource: commandSource,
            workerURL: workerURL,
            sharedSecret: sharedSecret,
            lampBackend: backend,
            shortcutPrefix: prefix,
            homebridgeURL: homebridgeURL,
            homebridgeToken: homebridgeToken,
            accessoryId: accessoryId,
            homekitHelperPath: homekitHelperPath,
            homekitAccessoryName: homekitAccessoryName
        )
    }

    /// Loads and parses the config file at `url`.
    public static func load(from url: URL) throws -> Config {
        try parse(String(contentsOf: url, encoding: .utf8))
    }
}
