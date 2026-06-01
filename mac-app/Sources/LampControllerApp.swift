import SwiftUI

@main
struct LampControllerApp: App {
    @State private var model = AppModel()

    init() {
        AppKitBridge.setAccessoryActivationPolicy()
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
