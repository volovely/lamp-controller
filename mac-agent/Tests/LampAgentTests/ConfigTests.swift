import Foundation
import Testing
@testable import LampAgent

@Suite("Config")
struct ConfigTests {

    // MARK: - Full homebridge config

    @Test("parses a complete homebridge config.toml")
    func parsesAllHomebridge() throws {
        let toml = """
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

    // MARK: - HomeKit default

    @Test("homekit backend is default when lamp_backend is absent (with required fields)")
    func homekitIsDefault() throws {
        let toml = """
        commands_path          = "/tmp/commands.json"
        poll_interval_s        = 5
        homekit_helper_path    = "/Applications/LampHK.app"
        homekit_accessory_name = "Lamp"
        """
        let config = try Config.parse(toml)

        #expect(config.lampBackend == .homekit)
        #expect(config.homekitHelperPath == "/Applications/LampHK.app")
        #expect(config.homekitAccessoryName == "Lamp")
    }

    @Test("homekit backend without required fields throws missingKey")
    func homekitBackendMissingFields() throws {
        let toml = """
        commands_path   = "/tmp/commands.json"
        poll_interval_s = 5
        """
        #expect(throws: Config.ConfigError.self) { try Config.parse(toml) }
    }

    @Test("homekit backend missing accessory_name throws missingKey")
    func homekitBackendMissingAccessoryName() throws {
        let toml = """
        commands_path          = "/tmp/commands.json"
        poll_interval_s        = 5
        lamp_backend           = "homekit"
        homekit_helper_path    = "/Applications/LampHK.app"
        """
        #expect(throws: Config.ConfigError.missingKey("homekit_accessory_name")) {
            try Config.parse(toml)
        }
    }

    @Test("homekit backend missing helper_path throws missingKey")
    func homekitBackendMissingHelperPath() throws {
        let toml = """
        commands_path          = "/tmp/commands.json"
        poll_interval_s        = 5
        lamp_backend           = "homekit"
        homekit_accessory_name = "Lamp"
        """
        #expect(throws: Config.ConfigError.missingKey("homekit_helper_path")) {
            try Config.parse(toml)
        }
    }

    @Test("homekit backend parses with both required fields")
    func homekitBackendParses() throws {
        let toml = """
        commands_path          = "/tmp/commands.json"
        poll_interval_s        = 10
        lamp_backend           = "homekit"
        homekit_helper_path    = "/Applications/LampHK.app"
        homekit_accessory_name = "Mijia desk lamp 1S"
        """
        let config = try Config.parse(toml)

        #expect(config.lampBackend == .homekit)
        #expect(config.homekitHelperPath == "/Applications/LampHK.app")
        #expect(config.homekitAccessoryName == "Mijia desk lamp 1S")
    }

    @Test("tilde is expanded in homekit_helper_path")
    func homekitHelperPathTildeExpanded() throws {
        let toml = """
        commands_path          = "/tmp/commands.json"
        poll_interval_s        = 5
        lamp_backend           = "homekit"
        homekit_helper_path    = "~/Applications/LampHK.app"
        homekit_accessory_name = "Lamp"
        """
        let config = try Config.parse(toml)
        #expect(config.homekitHelperPath?.hasPrefix("~") == false)
        #expect(config.homekitHelperPath?.hasSuffix("/Applications/LampHK.app") == true)
    }

    // MARK: - Shortcuts (explicit)

    @Test("shortcuts backend parses when explicitly set")
    func shortcutsExplicit() throws {
        let toml = """
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
        commands_path   = "~/x/commands.json"
        poll_interval_s = 5
        lamp_backend    = "shortcuts"
        """
        let config = try Config.parse(toml)
        #expect(!config.commandsPath.hasPrefix("~"))
        #expect(config.commandsPath.hasSuffix("/x/commands.json"))
    }

    // MARK: - Missing required keys

    @Test("missing commands_path throws missingKey")
    func missingCommandsPathThrows() throws {
        let toml = #"poll_interval_s = 5"#
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
}
