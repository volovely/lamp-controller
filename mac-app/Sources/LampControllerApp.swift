import SwiftUI
import Darwin

@main
struct LampControllerApp: App {
    @State private var model = AppModel()

    init() {
        // Spike: set AppKit activation policy to .accessory so the app has no
        // Dock icon and behaves as a menu-bar-style process. We reach NSApplication
        // via the ObjC runtime because this is Mac Catalyst (no direct AppKit import).
        // NSApplicationActivationPolicyAccessory == 1
        //
        // setActivationPolicy: takes a primitive NSInteger. perform(_:with:) only
        // handles object params, so we grab objc_msgSend via dlsym and cast it to
        // the correct C function signature (AnyObject, Selector, Int) -> Bool.
        if let appKitAppClass = NSClassFromString("NSApplication") as? NSObject.Type,
           let sharedApp = appKitAppClass.value(forKey: "sharedApplication") as? NSObject,
           let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "objc_msgSend") {
            typealias SetPolicyFn = @convention(c) (AnyObject, Selector, Int) -> Bool
            let fn = unsafeBitCast(sym, to: SetPolicyFn.self)
            _ = fn(sharedApp, NSSelectorFromString("setActivationPolicy:"), 1)
        }

    }

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .frame(minWidth: 420, minHeight: 360)
                .onAppear {
                    // Spike: install the status-bar item after the run loop is running
                    // so that perform:afterDelay: timers fire correctly.
                    StatusItemSpike.shared.install()
                    model.loadConfig()
                    // Spike: auto-start polling when launched with LAMP_SPIKE_AUTOSTART=1
                    if ProcessInfo.processInfo.environment["LAMP_SPIKE_AUTOSTART"] == "1" {
                        Task { @MainActor in
                            // Give HomeKit a moment to load homes before starting.
                            try? await Task.sleep(for: .seconds(3))
                            model.start()
                        }
                    }
                }
        }
    }
}
