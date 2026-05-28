import SwiftUI
import AppKit

/// Dismissible promo card pinned to the bottom of the sidebar that pitches the
/// companion browser extension. Self-hides via @AppStorage once dismissed, so
/// it never reappears after the user acts on or closes it.
struct ExtensionCalloutView: View {
    @AppStorage("extensionCalloutDismissed") private var dismissed = false

    private static let extensionURL = URL(string: "https://enshittifier.wells.ee#extension")!

    var body: some View {
        if !dismissed {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "puzzlepiece.extension.fill")
                        .foregroundStyle(.secondary)
                    Text("Browser Extension")
                        .font(.callout.weight(.semibold))
                    Spacer()
                    Button {
                        dismissed = true
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Dismiss")
                }

                Text("Enshittify fonts on the web, too.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    NSWorkspace.shared.open(Self.extensionURL)
                } label: {
                    Text("Get Extension")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.small)
            }
            .padding(10)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
        }
    }
}
