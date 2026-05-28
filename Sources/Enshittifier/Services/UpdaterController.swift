import Foundation
import SwiftUI
import Sparkle

/// Thin wrapper around `SPUStandardUpdaterController` so SwiftUI views can
/// observe enable-state and trigger an update check without juggling
/// Sparkle's AppKit-style delegate protocol directly.
///
/// Configuration lives in the app's Info.plist (`SUFeedURL`,
/// `SUPublicEDKey`, `SUEnableAutomaticChecks`, etc.), declared in
/// `project.yml`. The updater is started automatically; calling
/// `checkForUpdates()` opens the standard Sparkle "An update is
/// available" / "You're up to date" dialog.
@MainActor
final class UpdaterController: ObservableObject {
    @Published var canCheckForUpdates = false

    private let controller: SPUStandardUpdaterController

    init() {
        // `startingUpdater: true` makes Sparkle perform its initial scheduled
        // check shortly after launch. `updaterDelegate: nil` keeps us on the
        // default behavior (no custom feed URL, no per-update gating, etc.).
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .assign(to: &$canCheckForUpdates)
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    /// Sparkle's scheduled-check preference. Sparkle persists this itself
    /// (under `SUEnableAutomaticChecks`), so the toggle state survives
    /// relaunches without any extra storage on our side.
    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }
}
