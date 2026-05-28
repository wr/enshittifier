import SwiftUI

@main
struct EnshittifierApp: App {
    @State private var model = AppModel()
    @StateObject private var updater = UpdaterController()

    var body: some Scene {
        WindowGroup("Enshittifier") {
            ContentView()
                .environment(model)
                .frame(minWidth: 880, minHeight: 600)
        }
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            CommandGroup(replacing: .newItem) {}
            // Sparkle "Check for Updates…" lives in the application menu,
            // just below "About Enshittifier". Disabled while Sparkle is
            // already running a check.
            CommandGroup(after: .appInfo) {
                Button("Check for Updates\u{2026}") {
                    updater.checkForUpdates()
                }
                .disabled(!updater.canCheckForUpdates)
            }
        }

        Settings {
            SettingsView()
                .environment(model)
                .environmentObject(updater)
        }
    }
}
