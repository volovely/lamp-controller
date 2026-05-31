import Foundation
import Testing
@testable import LampAgent

// MARK: - Stub URLProtocol
//
// Tests in this suite are `.serialized` (one at a time), so a single global
// handler is safe.  Each test sets the handler before calling the client and
// the protocol clears it after all responses are delivered.

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

// MARK: - Captured request + ordered capture list

/// One captured PUT: the raw URLRequest and the decoded body dictionary.
private struct CapturedPut: @unchecked Sendable {
    let request: URLRequest
    let body: [String: Any]
}

/// Thread-safe ordered list of captured PUTs across multiple requests in a single `apply` call.
private final class CaptureList: @unchecked Sendable {
    private let lock = NSLock()
    private var _items: [CapturedPut] = []

    func append(_ item: CapturedPut) {
        lock.withLock { _items.append(item) }
    }

    var items: [CapturedPut] { lock.withLock { _items } }
}

// MARK: - Helpers

/// A URLSession backed by `StubURLProtocol`. One shared instance is fine
/// because `GlobalStubHandler` drives the behaviour per test.
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

private func makeClient() -> LampClient {
    LampClient.homebridge(
        baseURL: baseURL,
        token: token,
        accessoryId: accessoryId,
        session: stubSession
    )
}

private func okResponse(url: URL, status: Int = 200) -> HTTPURLResponse {
    HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
}

/// Installs a handler that returns 200 OK for every request and appends each
/// decoded body into `capture`.
private func installCapturingOKHandler(into capture: CaptureList) {
    GlobalStubHandler.shared.handler = { req, bodyData in
        if let data = bodyData,
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            capture.append(CapturedPut(request: req, body: json))
        }
        return (okResponse(url: req.url!), Data())
    }
}

// MARK: - Suite

/// The `.serialized` trait ensures tests run one at a time, which is required
/// because they share the global `StubURLProtocol` handler.
@Suite("LampClient.homebridge — REST requests", .serialized)
struct LampClientHomebridgeTests {

    // MARK: 1. power=true → three PUTs in order: On, Brightness, ColorTemperature

    @Test("apply(on, 30, 2700) issues On=true, Brightness=30, ColorTemperature=370 in order")
    func applyOnIssuesThreePuts() async throws {
        let capture = CaptureList()
        installCapturingOKHandler(into: capture)
        defer { GlobalStubHandler.shared.handler = nil }

        try await makeClient().apply(LampState(power: true, brightness: 30, colorTempK: 2700))

        let puts = capture.items
        #expect(puts.count == 3)

        // PUT 1: On = true (must be JSON boolean, not a number)
        let put1 = try #require(puts.first)
        #expect(put1.request.httpMethod == "PUT")
        #expect(put1.request.url == expectedURL)
        #expect(put1.request.value(forHTTPHeaderField: "Authorization") == "Bearer \(token)")
        #expect(put1.request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(put1.body["characteristicType"] as? String == "On")
        let onValue = try #require(put1.body["value"])
        let onBool = try #require(onValue as? Bool)
        #expect(onBool == true)

        // PUT 2: Brightness = 30 (JSON number, not string)
        let put2 = try #require(puts.dropFirst().first)
        #expect(put2.body["characteristicType"] as? String == "Brightness")
        let brightnessValue = try #require(put2.body["value"])
        let brightnessNum = try #require(brightnessValue as? NSNumber)
        #expect(brightnessNum.intValue == 30)
        #expect(brightnessValue as? String == nil)

        // PUT 3: ColorTemperature = 370 mired (1_000_000 / 2700 ≈ 370.37 → 370)
        let put3 = try #require(puts.dropFirst(2).first)
        #expect(put3.body["characteristicType"] as? String == "ColorTemperature")
        let ctValue = try #require(put3.body["value"])
        let ctNum = try #require(ctValue as? NSNumber)
        #expect(ctNum.intValue == 370)
    }

    // MARK: 2. power=false → exactly one PUT (On=false, no Brightness or ColorTemperature)

    @Test("apply(off, 50, 4000) issues exactly one PUT: On=false")
    func applyOffIssuesOnlyOnePut() async throws {
        let capture = CaptureList()
        installCapturingOKHandler(into: capture)
        defer { GlobalStubHandler.shared.handler = nil }

        try await makeClient().apply(LampState(power: false, brightness: 50, colorTempK: 4000))

        let puts = capture.items
        #expect(puts.count == 1)

        let put1 = try #require(puts.first)
        #expect(put1.body["characteristicType"] as? String == "On")
        let onValue = try #require(put1.body["value"])
        let onBool = try #require(onValue as? Bool)
        #expect(onBool == false)
    }

    // MARK: 3. HTTP 500 on first PUT → ClientError.requestFailed(status: 500)

    @Test("HTTP 500 on first PUT throws ClientError.requestFailed(status: 500)")
    func http500ThrowsRequestFailed() async throws {
        GlobalStubHandler.shared.handler = { req, _ in
            (okResponse(url: req.url!, status: 500), Data())
        }
        defer { GlobalStubHandler.shared.handler = nil }

        await #expect(throws: LampClient.ClientError.requestFailed(status: 500)) {
            try await makeClient().apply(LampState(power: true, brightness: 30, colorTempK: 2700))
        }
    }

    // MARK: 4. Transport error → ClientError.unreachable

    @Test("transport error throws ClientError.unreachable")
    func transportErrorThrowsUnreachable() async throws {
        GlobalStubHandler.shared.handler = { _, _ in
            throw URLError(.cannotConnectToHost)
        }
        defer { GlobalStubHandler.shared.handler = nil }

        await #expect(throws: LampClient.ClientError.unreachable) {
            try await makeClient().apply(LampState(power: true, brightness: 30, colorTempK: 2700))
        }
    }
}
