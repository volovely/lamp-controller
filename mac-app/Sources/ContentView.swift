import SwiftUI
import LampAgent

struct ContentView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Lamp Controller").font(.title2).bold()

            if let error = model.configError {
                Label("Config error: \(error)", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            } else if let config = model.config {
                VStack(alignment: .leading, spacing: 4) {
                    row("Lamp", config.homekitAccessoryName ?? "—")
                    row("Worker", config.workerURL?.absoluteString ?? "—")
                    row("HomeKit", homeKitStatus)
                }
                .font(.callout)
            }

            Button(model.runState == .running ? "Stop" : "Start") {
                model.runState == .running ? model.stop() : model.start()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(model.config == nil)

            Divider()
            Text("Activity").font(.headline)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(model.activity) { entry in
                        Text("\(entry.time, format: .dateTime.hour().minute().second())  \(entry.message)")
                            .font(.caption.monospaced())
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding()
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label).foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
            Text(value).textSelection(.enabled)
        }
    }

    private var homeKitStatus: String {
        switch model.homeKitController?.state {
        case .loading, nil: "loading…"
        case .denied: "access denied — System Settings ▸ Privacy ▸ Home"
        case let .ready(count, found): found ? "ready · \(count) accessories" : "accessory not found"
        }
    }
}
