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

/// Compact, stateful progress sheet. Three states:
///   • working   — header + determinate bar + current font
///   • done/ok    — green check; ContentView auto-dismisses it
///   • done/issues — warning + a list of what failed + a Close button
struct InstallProgressView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var progress: InstallProgress

    private var isRestore: Bool { progress.action == "Restoring" }
    private var verb: String { isRestore ? "Restoring" : "Enshittifying" }
    private var pastVerb: String { isRestore ? "restored" : "enshittified" }
    private var accent: Color { isRestore ? Self.restorePurple : .orange }
    private var hasFailures: Bool { progress.finished && progress.failureCount > 0 }

    static let restorePurple = Color(red: 0.45, green: 0.30, blue: 0.78)

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 28)
                .padding(.top, 28)
                .padding(.bottom, hasFailures ? 18 : 28)

            if hasFailures {
                Divider()
                failureList
                Divider()
                HStack {
                    Spacer()
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                        .controlSize(.large)
                }
                .padding(16)
            }
        }
        .frame(width: 460)
    }

    // MARK: - Header (state-dependent)

    @ViewBuilder
    private var header: some View {
        VStack(spacing: 16) {
            icon
                .frame(height: 56)

            VStack(spacing: 5) {
                Text(title)
                    .font(.title2.weight(.semibold))
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .animation(.default, value: subtitle)
            }

            if !progress.finished {
                VStack(spacing: 6) {
                    ProgressView(value: Double(progress.completed),
                                 total: Double(max(progress.total, 1)))
                        .progressViewStyle(.linear)
                        .tint(accent)
                    HStack {
                        Text("\(progress.completed) of \(progress.total)")
                        Spacer()
                        Text("\(percent)%")
                            .fontWeight(.medium)
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var icon: some View {
        if progress.finished {
            ZStack {
                Circle()
                    .fill((hasFailures ? Color.orange : Color.green).opacity(0.15))
                    .frame(width: 56, height: 56)
                Image(systemName: hasFailures ? "exclamationmark" : "checkmark")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(hasFailures ? .orange : .green)
            }
        } else if isRestore {
            Image(systemName: "arrow.uturn.backward.circle.fill")
                .font(.system(size: 48))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(accent)
        } else {
            PoopGlyph(size: 48, tint: accent)
        }
    }

    private var title: String {
        if !progress.finished { return "\(verb)\u{2026}" }
        if hasFailures {
            return "Finished with \(progress.failureCount) issue\(progress.failureCount == 1 ? "" : "s")"
        }
        return "Done"
    }

    private var subtitle: String {
        if progress.finalizing {
            return progress.finalizingLabel.isEmpty ? "Refreshing font system\u{2026}" : progress.finalizingLabel
        }
        if !progress.finished {
            return progress.currentFontName.isEmpty ? "Preparing\u{2026}" : progress.currentFontName
        }
        let s = progress.successCount
        if hasFailures {
            return "\(s) \(pastVerb), \(progress.failureCount) failed"
        }
        return "\(s) style\(s == 1 ? "" : "s") \(pastVerb)"
    }

    private var percent: Int {
        Int((Double(progress.completed) / Double(max(progress.total, 1))) * 100)
    }

    // MARK: - Failure list (only when finished with issues)

    @ViewBuilder
    private var failureList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(progress.rows.filter { !$0.success }) { row in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .symbolRenderingMode(.hierarchical)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.name)
                                .font(.callout.weight(.medium))
                            if let d = row.detail {
                                Text(d)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(3)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(maxHeight: 200)
    }
}
