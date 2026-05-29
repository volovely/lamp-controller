import Foundation
import Testing
@testable import LampAgent

// MARK: - Stub URLProtocol
//
// Tests in this suite are `.serialized` (one at a time), so a single global
// handler is safe.  Each test sets the handler before calling the client and
// the protocol clears it after the response/error is delivered.

private typealias StubHandler = @Sendable (URLRequest, Data?) throws -> (HTTPURLResponse, Data)

private final class GlobalStubHandler: @unchecked Sendable {
    static let shared = GlobalStubHandler()
    private let lock = NSLock()
    private var _handler: StubHandler?

    var handler: StubHandler? {
        get { lock.withLock { _handler } }
        set { lock.withLock { _handler = newValue } }
    }
}

/// `URLProtocol` that routes every request through `GlobalStubHandler.shared`.
private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool {
        GlobalStubHandler.shared.handler != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // URLSession moves `httpBody` into an InputStream for upload tasks.
        // Drain it so the handler receives the raw bytes.
        let bodyData: Data?
        if let body = request.httpBody {
            bodyData = body
        } else if let stream = request.httpBodyStream {
            var data = Data()
            stream.open()
            let bufSize = 4_096
            var buf = [UInt8](repeating: 0, count: bufSize)
            while stream.hasBytesAvailable {
                let n = stream.read(&buf, maxLength: bufSize)
                if n > 0 { data.append(contentsOf: buf[..<n]) }
            }
            stream.close()
            bodyData = data.isEmpty ? nil : data
        } else {
            bodyData = nil
        }

        guard let handler = GlobalStubHandler.shared.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }

        do {
            let (response, responseData) = try handler(request, bodyData)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: responseData)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

// MARK: - Helpers

/// A URLSession backed by `StubURLProtocol`.  One shared instance is fine
/// because `GlobalStubHandler` is what drives the behaviour per test.
private let stubSession: URLSession = {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubURLProtocol.self]
    return URLSession(configuration: config)
}()

private let baseURL = URL(string: "http://homebridge.local:8581")!
private let token = "test-token"
private let accessoryId = "lamp-001"
private let expectedURL = baseURL
    .appendingPathComponent("api/accessories")
    .appendingPathComponent(accessoryId)

private func makeClient() -> HomebridgeClient {
    HomebridgeClient.live(
        baseURL: baseURL,
        token: token,
        accessoryId: accessoryId,
        session: stubSession
    )
}

private func okResponse(url: URL, status: Int = 200) -> HTTPURLResponse {
    HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
}

/// Thread-safe box that captures the request and drained body from the stub handler.
private final class CapturedRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var _request: URLRequest?
    private var _body: Data?

    func set(_ request: URLRequest, body: Data?) {
        lock.withLock { _request = request; _body = body }
    }

    var request: URLRequest? { lock.withLock { _request } }
    var body: Data? { lock.withLock { _body } }
}

// MARK: - Suite

/// The `.serialized` trait ensures tests run one at a time, which is required
/// because they share the global `StubURLProtocol` handler.
@Suite("HomebridgeClient.live — REST requests", .serialized)
struct HomebridgeClientLiveTests {

    // MARK: 1. setPower sends the correct request

    @Test("setPower(true) sends PUT with correct URL, headers, and a boolean body value")
    func setPowerSendsCorrectRequest() async throws {
        let capture = CapturedRequest()
        GlobalStubHandler.shared.handler = { req, body in
            capture.set(req, body: body)
            return (okResponse(url: req.url!), Data())
        }
        defer { GlobalStubHandler.shared.handler = nil }

        try await makeClient().setPower(true)

        let req = try #require(capture.request)
        #expect(req.httpMethod == "PUT")
        #expect(req.url == expectedURL)
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer \(token)")
        #expect(req.value(forHTTPHeaderField: "Content-Type") == "application/json")

        let bodyData = try #require(capture.body)
        let json = try #require(
            try JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
        )
        #expect(json["characteristicType"] as? String == "On")
        // The value must arrive as a JSON boolean (Bool), not a number or string.
        let rawValue = try #require(json["value"])
        let boolValue = try #require(rawValue as? Bool)
        #expect(boolValue == true)
    }

    // MARK: 2. setBrightness encodes a JSON number

    @Test("setBrightness(30) body has characteristicType Brightness and value as a JSON number")
    func setBrightnessSendsNumber() async throws {
        let capture = CapturedRequest()
        GlobalStubHandler.shared.handler = { req, body in
            capture.set(req, body: body)
            return (okResponse(url: req.url!), Data())
        }
        defer { GlobalStubHandler.shared.handler = nil }

        try await makeClient().setBrightness(30)

        let bodyData = try #require(capture.body)
        let json = try #require(
            try JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
        )
        #expect(json["characteristicType"] as? String == "Brightness")
        let rawValue = try #require(json["value"])
        // Must be a numeric type, never the string "30".
        let number = try #require(rawValue as? NSNumber)
        #expect(number.intValue == 30)
        #expect(rawValue as? String == nil)
    }

    // MARK: 3. setColorTemperature converts Kelvin → mired

    @Test("setColorTemperature(2700) converts to 370 mired in the request body")
    func setColorTemperatureConvertsToMired() async throws {
        let capture = CapturedRequest()
        GlobalStubHandler.shared.handler = { req, body in
            capture.set(req, body: body)
            return (okResponse(url: req.url!), Data())
        }
        defer { GlobalStubHandler.shared.handler = nil }

        try await makeClient().setColorTemperature(2700)

        let bodyData = try #require(capture.body)
        let json = try #require(
            try JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
        )
        #expect(json["characteristicType"] as? String == "ColorTemperature")
        let rawValue = try #require(json["value"])
        let number = try #require(rawValue as? NSNumber)
        // 1_000_000 / 2700 ≈ 370.37 → rounds to 370 mired
        #expect(number.intValue == 370)
    }

    // MARK: 4. HTTP 500 → ClientError.requestFailed

    @Test("HTTP 500 response throws ClientError.requestFailed(status: 500)")
    func http500ThrowsRequestFailed() async throws {
        GlobalStubHandler.shared.handler = { req, _ in
            (okResponse(url: req.url!, status: 500), Data())
        }
        defer { GlobalStubHandler.shared.handler = nil }

        await #expect(throws: HomebridgeClient.ClientError.requestFailed(status: 500)) {
            try await makeClient().setPower(true)
        }
    }

    // MARK: 5. Transport error → ClientError.unreachable

    @Test("transport error throws ClientError.unreachable")
    func transportErrorThrowsUnreachable() async throws {
        GlobalStubHandler.shared.handler = { _, _ in
            throw URLError(.cannotConnectToHost)
        }
        defer { GlobalStubHandler.shared.handler = nil }

        await #expect(throws: HomebridgeClient.ClientError.unreachable) {
            try await makeClient().setPower(true)
        }
    }
}
