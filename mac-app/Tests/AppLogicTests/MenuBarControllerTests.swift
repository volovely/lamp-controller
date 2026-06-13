import Testing
import Foundation
@testable import LampController

@Suite("MenuBarMenu.menuModel")
struct MenuBarMenuTests {
    private let ready = HomeKitController.State.ready(accessoryCount: 1, accessoryFound: true)

    @Test("running -> Stop enabled, status ● Running")
    func running() {
        let m = MenuBarMenu.menuModel(runState: .running, homeKit: ready, configError: nil)
        #expect(m.statusLine == "● Running")
        #expect(m.items[0] == MenuItem(title: "Stop", enabled: true, action: .toggle))
    }

    @Test("stopped + ready -> Start enabled, status ○ Stopped")
    func stoppedReady() {
        let m = MenuBarMenu.menuModel(runState: .stopped, homeKit: ready, configError: nil)
        #expect(m.statusLine == "○ Stopped")
        #expect(m.items[0] == MenuItem(title: "Start", enabled: true, action: .toggle))
    }

    @Test("stopped + denied -> Start disabled, status ⚠ HomeKit denied")
    func deniedDisablesStart() {
        let m = MenuBarMenu.menuModel(runState: .stopped, homeKit: .denied, configError: nil)
        #expect(m.statusLine == "⚠ HomeKit denied")
        #expect(m.items[0] == MenuItem(title: "Start", enabled: false, action: .toggle))
    }

    @Test("config error -> Start disabled, status ⚠ Config error")
    func configErrorDisablesStart() {
        let m = MenuBarMenu.menuModel(runState: .stopped, homeKit: .loading, configError: "bad toml")
        #expect(m.statusLine == "⚠ Config error")
        #expect(m.items[0].enabled == false)
    }

    @Test("running + accessory not found -> running suffix")
    func accessoryNotFound() {
        let m = MenuBarMenu.menuModel(
            runState: .running,
            homeKit: .ready(accessoryCount: 1, accessoryFound: false),
            configError: nil)
        #expect(m.statusLine == "● Running · accessory not found")
    }

    @Test("running + denied -> Stop still enabled, status ⚠ HomeKit denied")
    func runningDenied() {
        let m = MenuBarMenu.menuModel(runState: .running, homeKit: .denied, configError: nil)
        #expect(m.statusLine == "⚠ HomeKit denied")
        #expect(m.items[0] == MenuItem(title: "Stop", enabled: true, action: .toggle))
    }

    @Test("running + config error -> Stop still enabled, status ⚠ Config error")
    func runningConfigError() {
        let m = MenuBarMenu.menuModel(runState: .running, homeKit: ready, configError: "bad toml")
        #expect(m.statusLine == "⚠ Config error")
        #expect(m.items[0] == MenuItem(title: "Stop", enabled: true, action: .toggle))
    }

    @Test("always offers Show Activity and Quit, both enabled")
    func alwaysHasShowAndQuit() {
        let m = MenuBarMenu.menuModel(runState: .stopped, homeKit: ready, configError: nil)
        #expect(m.items.contains(MenuItem(title: "Show Activity…", enabled: true, action: .showActivity)))
        #expect(m.items.contains(MenuItem(title: "Quit", enabled: true, action: .quit)))
    }
}
