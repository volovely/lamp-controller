import Foundation
import Testing
@testable import LampAgent

@Suite("AckStore")
struct AckStoreTests {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ack-\(UUID().uuidString).json")
    }

    @Test("missing file loads as empty set")
    func missingFileEmpty() throws {
        let store = AckStore.file(at: tempURL())
        #expect(try store.load().isEmpty)
    }

    @Test("recorded ids round-trip through the file")
    func roundTrip() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = AckStore.file(at: url)

        try store.record(["a", "b"])
        try store.record(["c"])

        #expect(try store.load() == ["a", "b", "c"])
    }

    @Test("corrupt file loads as empty rather than throwing")
    func corruptFileEmpty() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try "not json".data(using: .utf8)!.write(to: url)

        let store = AckStore.file(at: url)
        #expect(try store.load().isEmpty)
    }

    @Test("recording is idempotent for duplicate ids")
    func dedupes() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = AckStore.file(at: url)

        try store.record(["a"])
        try store.record(["a"])

        #expect(try store.load() == ["a"])
    }
}
