import SwiftUI

/// Standard macOS Settings window (⌘,). Binds directly to the live
/// `AppModel` and `UpdaterController` from the environment, so changes take
/// effect in the running app immediately and persist for the next launch.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @EnvironmentObject private var updater: UpdaterController

    var body: some View {
        @Bindable var model = model

        Form {
            Section("General") {
                Picker("Default view", selection: $model.viewMode) {
                    ForEach(AppModel.ViewMode.allCases) { mode in
                        Label(mode.rawValue.capitalized, systemImage: mode.systemImage)
                            .tag(mode)
                    }
                }

                LabeledContent("Default preview size") {
                    HStack(spacing: 6) {
                        Image(systemName: "textformat.size.smaller")
                            .foregroundStyle(.secondary)
                        Slider(value: $model.tileSize, in: 128...260)
                        Image(systemName: "textformat.size.larger")
                            .foregroundStyle(.secondary)
                    }
                    .frame(width: 220)
                }
            }

            Section("Updates") {
                Toggle("Automatically check for updates", isOn: Binding(
                    get: { updater.automaticallyChecksForUpdates },
                    set: { updater.automaticallyChecksForUpdates = $0 }
                ))
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }
}
