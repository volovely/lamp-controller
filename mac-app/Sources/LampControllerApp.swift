import SwiftUI

@main
struct LampControllerApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .frame(minWidth: 420, minHeight: 360)
                .onAppear { model.loadConfig() }
        }
    }
}
