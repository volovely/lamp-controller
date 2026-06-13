import UIKit

/// Launch bootstrap. Owns the single AppModel and the MenuBarController.
/// didFinishLaunching runs with the run loop active — the correct place to set
/// the activation policy and install the status item.
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    let model = AppModel()
    private var menuBar: MenuBarController?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // When the app is only hosting unit tests, skip the menu-bar bootstrap:
        // flipping to .accessory and installing an NSStatusItem prevents the
        // XCTest runner from establishing its connection to the host.
        if isRunningUnitTests { return true }
        AppKitBridge.setAccessoryActivationPolicy()
        model.loadConfig()
        menuBar = MenuBarController(model: model)
        model.autoStart()
        return true
    }

    private var isRunningUnitTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || ProcessInfo.processInfo.environment["XCTestSessionIdentifier"] != nil
            || NSClassFromString("XCTestCase") != nil
    }
}
