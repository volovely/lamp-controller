import Foundation
import Testing
@testable import LampAgent

@Suite("WorkerCommandSource", .serialized)
struct WorkerCommandSourceTests {
    // MARK: Stub URLProtocol (one handler at a time; suite is .serialized)
    private final class Stub: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var handler: (@Sendable (URLRequest, Data?) throws -> (HTTPURLResponse, Data))?
        override class func canInit(with request: URLRequest) -> Bool { handler != nil }
        override class func canonicalRequest(for r: URLRequest) -> URLRequest { r }
        override func startLoading() {
            var bodyData: Data? = request.httpBody
            if bodyData == nil, let s = request.httpBodyStream {
                var d = Data(); s.open(); var buf = [UInt8](repeating: 0, count: 4096)
                while s.hasBytesAvailable { let n = s.read(&buf, maxLength: 4096); if n > 0 { d.append(contentsOf: buf[..<n]) } }
                s.close(); bodyData = d
            }
            do {
                let (resp, data) = try Self.handler!(request, bodyData)
                client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }
        override func stopLoading() {}
    }

    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [Stub.self]
        return URLSession(configuration: c)
    }()

    private let baseURL = URL(string: "https://lamp.example.workers.dev")!

    private func source() -> CommandSource {
        .worker(baseURL: baseURL, sharedSecret: "s3cret", session: Self.session)
    }

    private func ok(_ url: URL, _ status: Int = 200) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    @Test("pending GETs /commands with bearer and decodes the array")
    func pendingDecodes() async throws {
        final class Box: @unchecked Sendable { var req: URLRequest? }
        let box = Box()
        Stub.handler = { req, _ in
            box.req = req
            let body = """
            {"commands":[{"id":"a","action":"on","brightness":30,"color_temp_k":2700,"created_at":"2026-05-31T10:00:00Z","source_msg_id":"m"}]}
            """.data(using: .utf8)!
            return (self.ok(req.url!), body)
        }
        defer { Stub.handler = nil }

        let cmds = try await source().pending()

        #expect(cmds.count == 1)
        #expect(cmds.first?.id == "a")
        #expect(cmds.first?.colorTempK == 2700)
        #expect(box.req?.url?.path == "/commands")
        #expect(box.req?.value(forHTTPHeaderField: "Authorization") == "Bearer s3cret")
    }

    @Test("pending skips a malformed element")
    func pendingLossy() async throws {
        Stub.handler = { req, _ in
            let body = """
            {"commands":[{"id":"a","action":"off","created_at":"2026-05-31T10:00:00Z","source_msg_id":"m"},{"id":"b","action":"explode","created_at":"2026-05-31T10:00:00Z","source_msg_id":"m"}]}
            """.data(using: .utf8)!
            return (self.ok(req.url!), body)
        }
        defer { Stub.handler = nil }
        let cmds = try await source().pending()
        #expect(cmds.map(\.id) == ["a"])
    }

    @Test("pending throws on non-2xx")
    func pendingThrows() async {
        Stub.handler = { req, _ in (self.ok(req.url!, 500), Data()) }
        defer { Stub.handler = nil }
        await #expect(throws: (any Error).self) { try await self.source().pending() }
    }

    @Test("ack POSTs ids with bearer and accepts 204")
    func ackPosts() async throws {
        final class Box: @unchecked Sendable { var req: URLRequest?; var body: Data? }
        let box = Box()
        Stub.handler = { req, body in
            box.req = req; box.body = body
            return (self.ok(req.url!, 204), Data())
        }
        defer { Stub.handler = nil }

        try await source().ack(["a", "b"])

        #expect(box.req?.httpMethod == "POST")
        #expect(box.req?.url?.path == "/ack")
        #expect(box.req?.value(forHTTPHeaderField: "Authorization") == "Bearer s3cret")
        let parsed = try JSONSerialization.jsonObject(with: box.body ?? Data()) as? [String: Any]
        #expect((parsed?["ids"] as? [String]) == ["a", "b"])
    }

    @Test("ack throws on non-2xx")
    func ackThrows() async {
        Stub.handler = { req, _ in (self.ok(req.url!, 401), Data()) }
        defer { Stub.handler = nil }
        await #expect(throws: (any Error).self) { try await self.source().ack(["a"]) }
    }

    @Test("pending throws hostMismatch when response URL host differs from baseURL host")
    func pendingHostMismatch() async {
        let evilURL = URL(string: "https://evil.example.com/commands")!
        Stub.handler = { _, _ in
            let resp = HTTPURLResponse(url: evilURL, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let body = """
            {"commands":[]}
            """.data(using: .utf8)!
            return (resp, body)
        }
        defer { Stub.handler = nil }
        await #expect(throws: CommandSource.WorkerError.hostMismatch) {
            try await self.source().pending()
        }
    }
}
