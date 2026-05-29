import Foundation
import Testing
@testable import LampAgent

@Suite("Command")
struct CommandTests {
    @Test("decodes a full on-command from contract JSON")
    func decodeFull() throws {
        let json = """
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "action": "on",
          "brightness": 30,
          "color_temp_k": 2700,
          "created_at": "2026-05-29T10:00:00Z",
          "source_msg_id": "msg-1"
        }
        """.data(using: .utf8)!

        let command = try Command.jsonDecoder.decode(Command.self, from: json)

        #expect(command.id == "11111111-1111-1111-1111-111111111111")
        #expect(command.action == .on)
        #expect(command.brightness == 30)
        #expect(command.colorTempK == 2700)
        #expect(command.sourceMsgId == "msg-1")
        #expect(command.createdAt == Date(timeIntervalSince1970: 1_780_048_800))
    }

    @Test("decodes a minimal off-command")
    func decodeMinimal() throws {
        let json = """
        {"id":"a","action":"off","created_at":"2026-05-29T10:00:00Z","source_msg_id":"m"}
        """.data(using: .utf8)!

        let command = try Command.jsonDecoder.decode(Command.self, from: json)

        #expect(command.action == .off)
        #expect(command.brightness == nil)
        #expect(command.colorTempK == nil)
    }

    @Test("validate rejects brightness out of range")
    func rejectBrightness() throws {
        let command = Command(
            id: "a", action: .on, brightness: 150, colorTempK: nil,
            durationMinutes: nil, createdAt: .init(timeIntervalSince1970: 0), sourceMsgId: "m"
        )
        #expect(throws: Command.ValidationError.self) { try command.validate() }
    }

    @Test("validate rejects color_temp_k out of range")
    func rejectColorTemp() throws {
        let command = Command(
            id: "a", action: .set, brightness: nil, colorTempK: 1000,
            durationMinutes: nil, createdAt: .init(timeIntervalSince1970: 0), sourceMsgId: "m"
        )
        #expect(throws: Command.ValidationError.self) { try command.validate() }
    }

    @Test("validate accepts a well-formed command")
    func acceptValid() throws {
        let command = Command(
            id: "a", action: .on, brightness: 50, colorTempK: 4000,
            durationMinutes: nil, createdAt: .init(timeIntervalSince1970: 0), sourceMsgId: "m"
        )
        try command.validate()
    }

    @Test("isStale is true past the 10-minute window")
    func staleness() {
        let created = Date(timeIntervalSince1970: 0)
        let command = Command(
            id: "a", action: .on, brightness: nil, colorTempK: nil,
            durationMinutes: nil, createdAt: created, sourceMsgId: "m"
        )
        #expect(command.isStale(now: created.addingTimeInterval(601)))
        #expect(!command.isStale(now: created.addingTimeInterval(599)))
    }
}
