import SwiftUI
import AppKit

/// Dismissible promo card pinned to the bottom of the sidebar that pitches the
/// companion browser extension. Self-hides via @AppStorage once dismissed, so
/// it never reappears after the user acts on or closes it.
struct ExtensionCalloutView: View {
    @AppStorage("extensionCalloutDismissed") private var dismissed = false

    private static let extensionURL = URL(string: "https://enshittifier.wells.ee#extension")!

    private let browser = DefaultBrowser.detect()

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

                // AI → 💩 — the transform, at a glance.
                transformVisual
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)

                Text("Enshittify fonts on the web, too.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    NSWorkspace.shared.open(Self.extensionURL)
                } label: {
                    Text(ctaTitle)
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

    private var transformVisual: some View {
        HStack(spacing: 10) {
            Text("AI")
                .font(.system(size: 26, weight: .bold, design: .serif))
                .foregroundStyle(.primary)
            Image(systemName: "arrow.right")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)
            PoopGlyph(size: 28, tint: .primary)
        }
    }

    /// "Add to Arc/Brave/Chrome/…" — the user's default browser when it's
    /// Chromium-based (the extension only runs there), otherwise a plain
    /// "Add to Chrome".
    private var ctaTitle: String {
        if let b = browser, b.isChromium {
            return "Add to \(b.name)"
        }
        return "Add to Chrome"
    }
}

/// Resolves the system default browser and whether it's Chromium-based,
/// so the extension callout can address it by name.
enum DefaultBrowser {
    struct Info {
        let name: String
        let isChromium: Bool
    }

    /// Bundle ids (lowercased) of Chromium-based browsers. Matched by exact
    /// id or prefix, so beta/canary variants (e.g. com.google.Chrome.canary)
    /// resolve too.
    private static let chromiumBundleIDs: [String] = [
        "com.google.chrome",
        "org.chromium.chromium",
        "com.brave.browser",
        "com.microsoft.edgemac",
        "company.thebrowser.browser",   // Arc
        "company.thebrowser.dia",       // Dia
        "com.vivaldi.vivaldi",
        "com.operasoftware.opera",
        "com.operasoftware.operagx",
        "ru.yandex.desktop.yandex-browser",
        "com.naver.whale",
        "com.coccoc.coccoc",
        "ai.perplexity.comet",          // Comet
        "com.pushplaylabs.sidekick",
    ]

    /// Friendlier names for the common cases; otherwise we fall back to the
    /// app bundle's display name.
    private static let prettyNames: [String: String] = [
        "com.google.chrome": "Chrome",
        "com.brave.browser": "Brave",
        "com.microsoft.edgemac": "Edge",
        "com.vivaldi.vivaldi": "Vivaldi",
        "org.chromium.chromium": "Chromium",
    ]

    static func detect() -> Info? {
        guard let probe = URL(string: "https://example.com"),
              let appURL = NSWorkspace.shared.urlForApplication(toOpen: probe),
              let bundle = Bundle(url: appURL) else {
            return nil
        }
        let id = (bundle.bundleIdentifier ?? "").lowercased()
        let isChromium = chromiumBundleIDs.contains { id == $0 || id.hasPrefix($0 + ".") }
        return Info(name: name(for: id, appURL: appURL, bundle: bundle), isChromium: isChromium)
    }

    private static func name(for id: String, appURL: URL, bundle: Bundle) -> String {
        if let pretty = prettyNames[id] { return pretty }
        let info = bundle.infoDictionary
        if let display = info?["CFBundleDisplayName"] as? String { return display }
        if let name = info?["CFBundleName"] as? String { return name }
        return appURL.deletingPathExtension().lastPathComponent
    }
}
