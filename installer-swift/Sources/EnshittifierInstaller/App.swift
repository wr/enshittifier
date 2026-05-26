import SwiftUI

@main
struct EnshittifierInstallerApp: App {
    @State private var model = AppModel()

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
        }
    }
}
