import SwiftUI

@main
struct LampControllerApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // NOTE: .defaultLaunchBehavior(.suppressed) is @available(iOS, unavailable)
        // even in the Mac Catalyst (macabi) swiftinterface, so it cannot be called
        // here. The activity window opens on launch. Suppress it at the UIKit level
        // (application(_:configurationForConnecting:options:)) if needed in a
        // follow-up, or wait for Apple to lift the Catalyst restriction.
        WindowGroup(id: "activity") {
            ContentView(model: appDelegate.model)
                .frame(minWidth: 420, minHeight: 360)
        }
    }
}
