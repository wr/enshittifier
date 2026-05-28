import SwiftUI
import AppKit

/// Dismissible promo card pinned to the bottom of the sidebar that pitches the
/// companion browser extension. Self-hides via @AppStorage once dismissed, so
/// it never reappears after the user acts on or closes it.
struct ExtensionCalloutView: View {
    @AppStorage("extensionCalloutDismissed") private var dismissed = false

    private static let extensionURL = URL(string: "https://enshittifier.wells.ee#extension")!

    private let target = ExtensionTarget.resolve()

    var body: some View {
        if !dismissed {
            ZStack(alignment: .topTrailing) {
                VStack(spacing: 8) {
                    targetIcon
                        .frame(width: 60, height: 60)
                        .shadow(color: .black.opacity(0.18), radius: 4, y: 1)
                        .padding(.top, 4)

                    Text("Browser Extension")
                        .font(.title3.weight(.semibold))

                    Text("Enshittify fonts on the web, too.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)

                    Button {
                        NSWorkspace.shared.open(Self.extensionURL)
                    } label: {
                        Text("Add to \(target.name)")
                            .fontWeight(.medium)
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 2)
                }
                .frame(maxWidth: .infinity)
                .padding(12)

                Button {
                    dismissed = true
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding(8)
                .help("Dismiss")
            }
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
        }
    }

    @ViewBuilder
    private var targetIcon: some View {
        if let icon = target.icon {
            Image(nsImage: icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            // Fallback when the named browser isn't installed (e.g. Chrome
            // not present on a Safari default).
            Image(systemName: "puzzlepiece.extension.fill")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
        }
    }
}

/// Resolves the browser the extension callout should pitch: the user's
/// default browser when it's Chromium-based (the extension only runs
/// there), otherwise Chrome as the fallback target.
enum ExtensionTarget {
    struct Target {
        let name: String
        let appURL: URL?
        var icon: NSImage? {
            guard let appURL else { return nil }
            return NSWorkspace.shared.icon(forFile: appURL.path)
        }
    }

    /// Bundle ids (lowercased) of Chromium/Blink-based browsers. The id read
    /// from the app is lowercased before matching, so these stay lowercase.
    /// Matched by exact id or `base + "."` prefix, so beta/dev/canary
    /// variants (com.google.Chrome.canary, com.microsoft.edgemac.Dev,
    /// com.brave.Browser.nightly, com.vivaldi.Vivaldi.snapshot, …) resolve
    /// too — except a few Opera channels that don't follow base+suffix and
    /// are listed explicitly.
    private static let chromiumBundleIDs: [String] = [
        "com.google.chrome",
        "org.chromium.chromium",            // also ungoogled-chromium
        "com.brave.browser",
        "com.microsoft.edgemac",
        "company.thebrowser.browser",       // Arc
        "company.thebrowser.dia",           // Dia
        "com.vivaldi.vivaldi",
        "com.operasoftware.opera",
        "com.operasoftware.operagx",        // Opera GX
        "com.operasoftware.operaair",       // Opera Air
        "com.operasoftware.operanext",      // Opera beta (not base+suffix)
        "com.operasoftware.operadeveloper", // Opera developer
        "ru.yandex.desktop.yandex-browser",
        "com.naver.whale",
        "com.coccoc.coccoc",
        "ai.perplexity.comet",              // Comet
        "io.wavebox.wavebox",               // Wavebox
        "net.imput.helium",                 // Helium
        "de.iridiumbrowser",                // Iridium
    ]

    /// Friendlier names for the common cases; otherwise fall back to the
    /// app bundle's display name.
    private static let prettyNames: [String: String] = [
        "com.google.chrome": "Chrome",
        "com.brave.browser": "Brave",
        "com.microsoft.edgemac": "Edge",
        "com.vivaldi.vivaldi": "Vivaldi",
        "org.chromium.chromium": "Chromium",
    ]

    static func resolve() -> Target {
        if let probe = URL(string: "https://example.com"),
           let appURL = NSWorkspace.shared.urlForApplication(toOpen: probe),
           let bundle = Bundle(url: appURL) {
            let id = (bundle.bundleIdentifier ?? "").lowercased()
            if chromiumBundleIDs.contains(where: { id == $0 || id.hasPrefix($0 + ".") }) {
                return Target(name: name(for: id, appURL: appURL, bundle: bundle), appURL: appURL)
            }
        }
        // Non-Chromium (Safari/Firefox) or undetectable → pitch Chrome.
        let chromeURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.google.Chrome"
        )
        return Target(name: "Chrome", appURL: chromeURL)
    }

    private static func name(for id: String, appURL: URL, bundle: Bundle) -> String {
        if let pretty = prettyNames[id] { return pretty }
        let info = bundle.infoDictionary
        if let display = info?["CFBundleDisplayName"] as? String { return display }
        if let name = info?["CFBundleName"] as? String { return name }
        return appURL.deletingPathExtension().lastPathComponent
    }
}
