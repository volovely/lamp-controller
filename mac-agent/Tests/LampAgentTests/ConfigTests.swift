import Foundation
import Testing
@testable import LampAgent

@Suite("Config")
struct ConfigTests {
    @Test("parses a complete config.toml")
    func parsesAll() throws {
        let toml = """
        homebridge_url   = "http://127.0.0.1:8581"
        homebridge_token = "tok-123"
        accessory_id     = "lamp-desk"
        commands_path    = "/tmp/commands.json"
        poll_interval_s  = 12
        """
        let config = try Config.parse(toml)

        #expect(config.homebridgeURL == URL(string: "http://127.0.0.1:8581")!)
        #expect(config.homebridgeToken == "tok-123")
        #expect(config.accessoryId == "lamp-desk")
        #expect(config.commandsPath == "/tmp/commands.json")
        #expect(config.pollIntervalSeconds == 12)
    }

    @Test("expands a leading ~ in commands_path")
    func expandsTilde() throws {
        let toml = """
        homebridge_url   = "http://127.0.0.1:8581"
        homebridge_token = "t"
        accessory_id     = "a"
        commands_path    = "~/x/commands.json"
        poll_interval_s  = 5
        """
        let config = try Config.parse(toml)
        #expect(!config.commandsPath.hasPrefix("~"))
        #expect(config.commandsPath.hasSuffix("/x/commands.json"))
    }

    @Test("missing required key throws")
    func missingKeyThrows() throws {
        let toml = #"homebridge_token = "t""#
        #expect(throws: Config.ConfigError.self) { try Config.parse(toml) }
    }
}
