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
        AppKitBridge.setAccessoryActivationPolicy()
        model.loadConfig()
        menuBar = MenuBarController(model: model)
        model.autoStart()
        return true
    }
}
