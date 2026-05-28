import SwiftUI
import Observation
import AppKit

/// Thread-safe one-way cancellation flag. The patch/restore loops run on
/// a background queue and poll `isCancelled` between fonts; the Cancel
/// button (main actor) sets it. `@unchecked Sendable` is sound because
/// every access is guarded by the lock.
final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _cancelled = false
    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return _cancelled
    }
    func cancel() {
        lock.lock(); _cancelled = true; lock.unlock()
    }
}

@Observable
final class InstallProgress: Identifiable {
    let id = UUID()
    var action: String = "Installing"

    /// Coarse stage of the operation. The sheet shows green/Done only at
    /// `.done` — the finalization phases (cache flush, fontd bounce,
    /// re-registration) advance the bar but are NOT "done" yet.
    enum Stage { case patching, finalizing, done }
    var stage: Stage = .patching

    /// Current label under the title: the font being patched, or the
    /// active finalization phase.
    var currentLabel: String = ""
    /// Set when the user hits Cancel — the loop will stop after the
    /// in-flight font and finalize whatever was done so far.
    var cancelling: Bool = false
    var fontTotal: Int = 0
    var fontsCompleted: Int = 0
    /// How many finalization phases have arrived (drives the tail of the
    /// progress bar between patching and done).
    var phaseIndex: Int = 0
    var rows: [Row] = []

    var finished: Bool { stage == .done }

    struct Row: Identifiable {
        let id = UUID()
        let name: String
        let success: Bool
        let detail: String?
    }

    func apply(_ update: InstallUpdate) {
        switch update {
        case .start(let total):
            fontTotal = total
            fontsCompleted = 0
            phaseIndex = 0
            rows = []
            stage = .patching
        case .progress(_, let name):
            currentLabel = name
        case .completed(let name):
            fontsCompleted = min(fontsCompleted + 1, fontTotal)
            rows.append(Row(name: name, success: true, detail: nil))
        case .failed(let name, let message):
            fontsCompleted = min(fontsCompleted + 1, fontTotal)
            rows.append(Row(name: name, success: false, detail: message))
        case .done:
            // Patches written — but font services still need to reload.
            // Enter the finalizing stage; green doesn't show until
            // `.finalized`.
            stage = .finalizing
        case .phase(let label):
            stage = .finalizing
            currentLabel = label
            phaseIndex += 1
        case .finalized:
            stage = .done
            currentLabel = ""
        }
    }

    func markFinished() {
        stage = .done
        currentLabel = ""
    }

    /// 0…1 progress. Fonts fill the first 85%; the finalization phases
    /// nudge through the last 15%; only `.done` reaches 1.0 (green).
    var fraction: Double {
        switch stage {
        case .patching:
            guard fontTotal > 0 else { return 0 }
            return (Double(fontsCompleted) / Double(fontTotal)) * 0.85
        case .finalizing:
            return min(0.85 + Double(phaseIndex) * 0.07, 0.99)
        case .done:
            return 1.0
        }
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
    /// Called when the user hits Cancel while the op is in flight.
    var onCancel: () -> Void = {}

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
                .padding(.bottom, hasFailures ? 18 : 22)

            // Cancel is only offered while patching (Enshittify). Restore
            // — including the rollback that a cancel triggers — isn't
            // cancellable, so its in-flight state shows no footer button.
            if !progress.finished && progress.action != "Restoring" {
                Divider()
                HStack {
                    Spacer()
                    Button("Cancel") {
                        progress.cancelling = true
                        onCancel()
                    }
                    .controlSize(.large)
                    .keyboardShortcut(.cancelAction)
                    .focusEffectDisabled()
                    .disabled(progress.cancelling)
                }
                .padding(16)
            } else if hasFailures {
                Divider()
                failureList
                Divider()
                HStack {
                    Button {
                        copyDebugInfo()
                    } label: {
                        Label(copiedDebug ? "Copied" : "Copy Debug Info",
                              systemImage: copiedDebug ? "checkmark" : "doc.on.clipboard")
                    }
                    .controlSize(.large)
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

    @State private var copiedDebug = false

    /// Copies a structured, AI-readable report of the run to the clipboard
    /// so the user can paste it straight into a chat/issue for diagnosis.
    private func copyDebugInfo() {
        let info = Bundle.main.infoDictionary
        let appVer = (info?["CFBundleShortVersionString"] as? String) ?? "?"
        let build = (info?["CFBundleVersion"] as? String) ?? "?"

        var lines: [String] = []
        lines.append("# Enshittifier \(progress.action.lowercased()) report")
        lines.append("")
        lines.append("- action: \(progress.action)")
        lines.append("- app: \(appVer) (build \(build))")
        lines.append("- macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        lines.append("- arch: \(machineArch())")
        lines.append("- total: \(progress.rows.count), succeeded: \(progress.successCount), failed: \(progress.failureCount)")
        lines.append("")
        lines.append("## Failures")
        let failures = progress.rows.filter { !$0.success }
        if failures.isEmpty {
            lines.append("(none)")
        } else {
            for row in failures {
                lines.append("- \(row.name): \(row.detail ?? "no detail provided")")
            }
        }
        if progress.successCount > 0 {
            lines.append("")
            lines.append("## Succeeded")
            for row in progress.rows where row.success {
                lines.append("- \(row.name)")
            }
        }

        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(lines.joined(separator: "\n"), forType: .string)

        copiedDebug = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            copiedDebug = false
        }
    }

    private func machineArch() -> String {
        var sysinfo = utsname()
        uname(&sysinfo)
        return withUnsafePointer(to: &sysinfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
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
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .animation(.default, value: subtitle)
            }

            if !progress.finished {
                VStack(spacing: 6) {
                    ProgressView(value: progress.fraction, total: 1.0)
                        .progressViewStyle(.linear)
                        .tint(accent)
                        .animation(.easeInOut(duration: 0.25), value: progress.fraction)
                    HStack {
                        // During patching show the font count; during the
                        // finalization phases show the step label instead.
                        Text(progress.stage == .patching
                             ? "\(progress.fontsCompleted) of \(progress.fontTotal)"
                             : "Finishing up\u{2026}")
                        Spacer()
                        Text("\(Int(progress.fraction * 100))%")
                            .fontWeight(.medium)
                    }
                    .font(.callout.monospacedDigit())
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
        if progress.cancelling && !progress.finished {
            return "Cancelling \u{2014} undoing changes\u{2026}"
        }
        switch progress.stage {
        case .patching:
            return progress.currentLabel.isEmpty ? "Preparing\u{2026}" : progress.currentLabel
        case .finalizing:
            return progress.currentLabel.isEmpty ? "Reloading font services\u{2026}" : progress.currentLabel
        case .done:
            let s = progress.successCount
            if hasFailures { return "\(s) \(pastVerb), \(progress.failureCount) failed" }
            return "\(s) style\(s == 1 ? "" : "s") \(pastVerb)"
        }
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
