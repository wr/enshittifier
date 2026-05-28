import SwiftUI
import Observation

/// Drives the one-time backup-migration sheet (W-216). Minimal by design:
/// the migration is a no-op on virtually every launch, so this only ever
/// appears once, briefly, on the first run after upgrading from a build
/// that kept backups on the Desktop.
@Observable
final class MigrationProgress: Identifiable {
    let id = UUID()
    /// Current step label, updated from `BackupMigrator`'s phase callback.
    var phase: String = "Tidying up your font backups\u{2026}"
}

struct MigrationProgressView: View {
    let progress: MigrationProgress

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "folder.fill")
                .font(.system(size: 42, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.accentColor)

            VStack(spacing: 6) {
                Text("Moving backups")
                    .font(.title2.weight(.semibold))
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(progress.phase)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .animation(.default, value: progress.phase)
                }
            }

            Text("Your original fonts are moving to ~/Library/Font Backups so they survive removing the app. This happens once.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(36)
        .frame(width: 420)
        // No close button — the sheet dismisses itself when the migration
        // finishes. Block interactive dismissal so the user can't cancel
        // a half-done move.
        .interactiveDismissDisabled(true)
    }
}
