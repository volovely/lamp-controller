import Foundation
import Testing
@testable import LampAgent

@Suite("Config")
struct ConfigTests {

    // MARK: - Full homebridge config

    @Test("parses a complete homebridge config.toml")
    func parsesAllHomebridge() throws {
        let toml = """
        command_source   = "file"
        commands_path    = "/tmp/commands.json"
        poll_interval_s  = 12
        lamp_backend     = "homebridge"
        homebridge_url   = "http://127.0.0.1:8581"
        homebridge_token = "tok-123"
        accessory_id     = "lamp-desk"
        """
        let config = try Config.parse(toml)

        #expect(config.commandsPath == "/tmp/commands.json")
        #expect(config.pollIntervalSeconds == 12)
        #expect(config.lampBackend == .homebridge)
        #expect(config.homebridgeURL == URL(string: "http://127.0.0.1:8581")!)
        #expect(config.homebridgeToken == "tok-123")
        #expect(config.accessoryId == "lamp-desk")
    }

    // MARK: - Shortcuts default

    @Test("shortcuts backend is default when lamp_backend is absent")
    func shortcutsIsDefault() throws {
        let toml = """
        command_source  = "file"
        commands_path   = "/tmp/commands.json"
        poll_interval_s = 5
        """
        let config = try Config.parse(toml)

        #expect(config.lampBackend == .shortcuts)
    }

    @Test("homekit_accessory_name is parsed as an optional field")
    func homekitAccessoryNameParses() throws {
        let toml = """
        command_source         = "file"
        commands_path          = "/tmp/commands.json"
        poll_interval_s        = 10
        lamp_backend           = "shortcuts"
        homekit_accessory_name = "Mijia desk lamp 1S"
        """
        let config = try Config.parse(toml)

        #expect(config.lampBackend == .shortcuts)
        #expect(config.homekitAccessoryName == "Mijia desk lamp 1S")
    }

    @Test("homekit_accessory_name is nil when not set")
    func homekitAccessoryNameNilByDefault() throws {
        let toml = """
        command_source  = "file"
        commands_path   = "/tmp/commands.json"
        poll_interval_s = 5
        lamp_backend    = "shortcuts"
        """
        let config = try Config.parse(toml)

        #expect(config.homekitAccessoryName == nil)
    }

    // MARK: - Shortcuts (explicit)

    @Test("shortcuts backend parses when explicitly set")
    func shortcutsExplicit() throws {
        let toml = """
        command_source  = "file"
        commands_path   = "/tmp/commands.json"
        poll_interval_s = 5
        lamp_backend    = "shortcuts"
        """
        let config = try Config.parse(toml)

        #expect(config.lampBackend == .shortcuts)
        #expect(config.shortcutPrefix == "Lamp")
        #expect(config.homebridgeURL == nil)
        #expect(config.homebridgeToken == nil)
        #expect(config.accessoryId == nil)
    }

    // MARK: - Custom shortcut_prefix

    @Test("custom shortcut_prefix is parsed")
    func customShortcutPrefix() throws {
        let toml = """
        command_source  = "file"
        commands_path   = "/tmp/commands.json"
        poll_interval_s = 5
        lamp_backend    = "shortcuts"
        shortcut_prefix = "Desk"
        """
        let config = try Config.parse(toml)

        #expect(config.lampBackend == .shortcuts)
        #expect(config.shortcutPrefix == "Desk")
    }

    // MARK: - Validation: homebridge backend requires all three fields

    @Test("homebridge backend without homebridge fields throws")
    func homebridgeBackendMissingFields() throws {
        let toml = """
        command_source  = "file"
        commands_path   = "/tmp/commands.json"
        poll_interval_s = 5
        lamp_backend    = "homebridge"
        """
        #expect(throws: Config.ConfigError.self) { try Config.parse(toml) }
    }

    // MARK: - Unknown backend

    @Test("unrecognized lamp_backend value throws invalidBackend")
    func unknownBackendThrows() throws {
        let toml = """
        command_source  = "file"
        commands_path   = "/tmp/commands.json"
        poll_interval_s = 5
        lamp_backend    = "bogus"
        """
        #expect(throws: Config.ConfigError.invalidBackend("bogus")) { try Config.parse(toml) }
    }

    // MARK: - Tilde expansion

    @Test("expands a leading ~ in commands_path")
    func expandsTilde() throws {
        let toml = """
        command_source  = "file"
        commands_path   = "~/x/commands.json"
        poll_interval_s = 5
        lamp_backend    = "shortcuts"
        """
        let config = try Config.parse(toml)
        #expect(config.commandsPath?.hasPrefix("~") == false)
        #expect(config.commandsPath?.hasSuffix("/x/commands.json") == true)
    }

    // MARK: - Missing required keys

    @Test("file source without commands_path throws missingKey")
    func missingCommandsPathThrows() throws {
        let toml = """
        command_source  = "file"
        poll_interval_s = 5
        lamp_backend    = "shortcuts"
        """
        #expect(throws: Config.ConfigError.missingKey("commands_path")) {
            try Config.parse(toml)
        }
    }

    @Test("missing poll_interval_s throws missingKey")
    func missingPollIntervalThrows() throws {
        let toml = #"commands_path = "/tmp/commands.json""#
        #expect(throws: Config.ConfigError.missingKey("poll_interval_s")) {
            try Config.parse(toml)
        }
    }

    // MARK: - Command source selection

    @Test("command_source defaults to worker and requires worker_url + shared_secret")
    func commandSourceDefaultsWorker() throws {
        let toml = """
        poll_interval_s = 12
        lamp_backend = "shortcuts"
        worker_url = "https://lamp.example.workers.dev"
        shared_secret = "s3cret"
        """
        let config = try Config.parse(toml)
        #expect(config.commandSource == .worker)
        #expect(config.workerURL == URL(string: "https://lamp.example.workers.dev")!)
        #expect(config.sharedSecret == "s3cret")
    }

    @Test("worker command source without worker_url throws")
    func workerMissingURL() {
        let toml = """
        poll_interval_s = 12
        lamp_backend = "shortcuts"
        shared_secret = "s3cret"
        """
        #expect(throws: Config.ConfigError.self) { try Config.parse(toml) }
    }

    @Test("worker command source without shared_secret throws")
    func workerMissingSharedSecret() {
        let toml = """
        poll_interval_s = 12
        lamp_backend = "shortcuts"
        worker_url = "https://lamp.example.workers.dev"
        """
        #expect(throws: Config.ConfigError.missingKey("shared_secret")) {
            try Config.parse(toml)
        }
    }

    @Test("opaque (host-less) worker_url throws invalidURL")
    func workerOpaqueURLThrows() {
        let toml = """
        poll_interval_s = 12
        lamp_backend = "shortcuts"
        worker_url = "opaque:value"
        shared_secret = "s3cret"
        """
        #expect(throws: Config.ConfigError.self) { try Config.parse(toml) }
    }

    @Test("file command source requires commands_path")
    func fileSourceParses() throws {
        let toml = """
        command_source = "file"
        commands_path = "/tmp/commands.json"
        poll_interval_s = 12
        lamp_backend = "shortcuts"
        """
        let config = try Config.parse(toml)
        #expect(config.commandSource == .file)
        #expect(config.commandsPath == "/tmp/commands.json")
    }

    @Test("state_path defaults under the home dir and expands ~")
    func statePathDefaultAndTilde() throws {
        let toml = """
        poll_interval_s = 12
        lamp_backend = "shortcuts"
        worker_url = "https://lamp.example.workers.dev"
        shared_secret = "s3cret"
        state_path = "~/x/acked.json"
        """
        let config = try Config.parse(toml)
        #expect(!config.statePath.hasPrefix("~"))
        #expect(config.statePath.hasSuffix("/x/acked.json"))
    }
}
