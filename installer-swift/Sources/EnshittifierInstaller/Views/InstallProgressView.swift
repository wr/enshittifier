import SwiftUI
import Observation

@Observable
final class InstallProgress: Identifiable {
    let id = UUID()
    var action: String = "Installing"
    /// Label shown under the action title. Either the current font being
    /// patched, or a post-loop phase label like "Refreshing font cache…".
    var currentFontName: String = ""
    var completed: Int = 0
    var total: Int = 0
    var rows: [Row] = []
    var finished: Bool = false
    /// True after every selected style has been processed but before the
    /// finalization steps (cache flush, fontd bounce, re-registration) have
    /// finished. The bar holds at 100% and the label says what's happening.
    var finalizing: Bool = false

    struct Row: Identifiable {
        let id = UUID()
        let name: String
        let success: Bool
        let detail: String?
    }

    func apply(_ update: InstallUpdate) {
        switch update {
        case .start(let total):
            self.total = total
            self.completed = 0
        case .progress(_, let name):
            self.currentFontName = name
        case .completed(let name):
            self.completed = min(self.completed + 1, self.total)
            self.rows.append(Row(name: name, success: true, detail: nil))
        case .failed(let name, let message):
            self.completed = min(self.completed + 1, self.total)
            self.rows.append(Row(name: name, success: false, detail: message))
        case .phase(let label):
            // `.phase` events fire after `.done` to flag background work
            // (cache flush, fontd bounce, registration). Dialog is already
            // dismissable; we just expose the label for an inline hint.
            self.finalizing = true
            self.finalizingLabel = label
            self.completed = self.total
        case .done:
            // Patches are done — let the user close the dialog. Background
            // refresh may still be in flight (tracked by `finalizing`).
            self.finished = true
            self.completed = self.total
        case .finalized:
            self.finalizing = false
        }
    }

    /// Sub-label shown under "All set" while background work is in flight.
    var finalizingLabel: String = ""

    func markFinished() {
        self.finished = true
        self.finalizing = false
        self.completed = self.total
    }

    var successCount: Int { rows.filter(\.success).count }
    var failureCount: Int { rows.filter { !$0.success }.count }
}

enum InstallUpdate {
    case start(total: Int)
    case progress(index: Int, name: String)
    case completed(name: String)
    case failed(name: String, message: String)
    /// Long post-loop phase (cache flush, fontd bounce, etc.). Fires after
    /// `.done` — the dialog is already dismissable; this just labels the
    /// background work for an inline hint.
    case phase(String)
    /// Patches are written + manifest saved. The dialog can be closed; the
    /// fontd / cache refresh below may still be in flight.
    case done
    /// All background work (cache flush, fontd bounce, registration) is
    /// complete. Used to drop the "still working" indicator.
    case finalized
}

struct InstallProgressView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var progress: InstallProgress

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                heroSection
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 28)
                    .padding(.top, 28)
                    .padding(.bottom, 22)

                if !progress.rows.isEmpty {
                    Divider()
                    rowsList
                } else if !progress.finished {
                    // Subtle placeholder while no rows have streamed in yet.
                    Spacer(minLength: 24)
                }

                if progress.finished {
                    footerNote
                }
            }
            .frame(minWidth: 560, minHeight: 460)
            .navigationTitle(progress.finished ? "\(progress.action) complete" : "\(progress.action)\u{2026}")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(progress.finished ? "Done" : "Close") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!progress.finished)
                }
            }
        }
    }

    // MARK: - Hero

    @ViewBuilder
    private var heroSection: some View {
        if progress.finished {
            finishedHero
        } else {
            inFlightHero
        }
    }

    @ViewBuilder
    private var inFlightHero: some View {
        VStack(spacing: 16) {
            heroIcon
                .frame(height: 60)

            VStack(spacing: 6) {
                Text(heroTitle)
                    .font(.title2.weight(.semibold))
                HStack(spacing: 8) {
                    if progress.finalizing {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(heroSubtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .animation(.default, value: progress.currentFontName)
                }
                .frame(maxWidth: .infinity)
            }

            VStack(spacing: 6) {
                ProgressView(value: Double(progress.completed),
                             total: Double(max(progress.total, 1)))
                    .progressViewStyle(.linear)
                    .tint(progress.action == "Restoring" ? .orange : .accentColor)
                HStack(spacing: 8) {
                    Text("\(progress.completed) of \(progress.total)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(percentComplete)%")
                        .font(.caption.monospacedDigit().weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var heroTitle: String {
        if progress.finalizing { return "Finalizing\u{2026}" }
        return "\(progress.action)\u{2026}"
    }

    private var heroSubtitle: String {
        if !progress.currentFontName.isEmpty { return progress.currentFontName }
        return "Getting ready\u{2026}"
    }

    @ViewBuilder
    private var finishedHero: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(finishedTint.opacity(0.16))
                    .frame(width: 72, height: 72)
                Image(systemName: progress.failureCount == 0 ? "checkmark" : "exclamationmark")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(finishedTint)
            }
            VStack(spacing: 4) {
                Text(finishedTitle)
                    .font(.title2.weight(.semibold))
                Text(finishedSubtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if progress.finalizing {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(progress.finalizingLabel.isEmpty
                         ? "Refreshing font system\u{2026}"
                         : progress.finalizingLabel)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(.top, 4)
            }
        }
    }

    @ViewBuilder
    private var heroIcon: some View {
        if progress.action == "Restoring" {
            Image(systemName: "arrow.uturn.backward.circle.fill")
                .font(.system(size: 52, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.orange)
        } else {
            PoopGlyph(size: 52, tint: .accentColor)
        }
    }

    private var finishedTint: Color {
        progress.failureCount == 0 ? .green : .orange
    }

    private var percentComplete: Int {
        let t = max(progress.total, 1)
        return Int((Double(progress.completed) / Double(t)) * 100)
    }

    // MARK: - Rows

    @ViewBuilder
    private var rowsList: some View {
        List(progress.rows) { row in
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: row.success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(row.success ? Color.green : Color.orange)
                    .symbolRenderingMode(.hierarchical)
                    .font(.body)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.name)
                        .font(.callout)
                    if let d = row.detail {
                        Text(d)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                }
                Spacer()
            }
            .listRowSeparator(.hidden)
            .padding(.vertical, 2)
        }
        .listStyle(.plain)
        .frame(minHeight: 200)
    }

    @ViewBuilder
    private var footerNote: some View {
        Divider()
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(.blue)
                .font(.callout)
            Text("Restart apps that were using the patched font to see changes. Browsers usually pick up the new glyph on the next page load.")
                .font(.callout)
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Color.blue.opacity(0.07))
    }

    private var finishedTitle: String {
        if progress.failureCount == 0 {
            return "All set"
        } else if progress.successCount == 0 {
            return "Nothing patched"
        } else {
            return "Finished with \(progress.failureCount) issue\(progress.failureCount == 1 ? "" : "s")"
        }
    }

    private var finishedSubtitle: String {
        let s = progress.successCount
        let f = progress.failureCount
        switch (s, f) {
        case (let s, 0):
            return "\(s) style\(s == 1 ? "" : "s") \(progress.action == "Restoring" ? "restored" : "patched")."
        case (0, let f):
            return "\(f) style\(f == 1 ? "" : "s") couldn\u{2019}t be \(progress.action == "Restoring" ? "restored" : "patched")."
        case (let s, let f):
            let verb = progress.action == "Restoring" ? "restored" : "patched"
            return "\(s) \(verb), \(f) failed."
        }
    }
}
