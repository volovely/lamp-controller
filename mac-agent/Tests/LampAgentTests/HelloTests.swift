import Testing
@testable import LampAgent

@Suite("Hello")
struct HelloTests {
    @Test("greet returns the configured greeting")
    func greet() {
        let result = Hello.greet(name: "lamp")
        #expect(result == "hello, lamp")
    }
}
