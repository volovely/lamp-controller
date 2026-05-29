import Foundation
import Testing
@testable import LampAgent

@Suite("FileCommandSource")
struct FileCommandSourceTests {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("cmds-\(UUID().uuidString).json")
    }

    @Test("missing file yields no pending commands")
    func missingFileEmpty() async throws {
        let source = CommandSource.file(at: tempURL())
        let pending = try await source.pending()
        #expect(pending.isEmpty)
    }

    @Test("reads and decodes the command array")
    func readsArray() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let json = """
        [{"id":"a","action":"on","brightness":30,"created_at":"2026-05-29T10:00:00Z","source_msg_id":"m"}]
        """
        try json.data(using: .utf8)!.write(to: url)

        let source = CommandSource.file(at: url)
        let pending = try await source.pending()

        #expect(pending.count == 1)
        #expect(pending.first?.id == "a")
        #expect(pending.first?.brightness == 30)
    }

    @Test("skips a malformed element but keeps the valid ones")
    func skipsMalformed() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let json = """
        [{"id":"a","action":"on","created_at":"2026-05-29T10:00:00Z","source_msg_id":"m"},
         {"id":"bad","action":"explode","created_at":"2026-05-29T10:00:00Z","source_msg_id":"m"}]
        """
        try json.data(using: .utf8)!.write(to: url)

        let source = CommandSource.file(at: url)
        let pending = try await source.pending()

        #expect(pending.map(\.id) == ["a"])
    }

    @Test("ack is a no-op that does not throw")
    func ackNoOp() async throws {
        let source = CommandSource.file(at: tempURL())
        try await source.ack(["a", "b"])
    }
}
