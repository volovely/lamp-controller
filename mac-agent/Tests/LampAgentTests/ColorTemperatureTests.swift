import Testing
@testable import LampAgent

@Suite("Color temperature")
struct ColorTemperatureTests {
    @Test("converts Kelvin to mired (reciprocal megakelvin)")
    func basic() {
        #expect(miredFromKelvin(2700) == 370)   // 1_000_000 / 2700 = 370.37 → 370
        #expect(miredFromKelvin(5000) == 200)
    }

    @Test("clamps to the HomeKit mired range 140...500")
    func clamps() {
        #expect(miredFromKelvin(1000) == 500)    // would be 1000 mired, clamps down
        #expect(miredFromKelvin(10000) == 140)   // would be 100 mired, clamps up
    }
}
