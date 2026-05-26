import Foundation

enum PatcherError: LocalizedError {
    case pythonNotFound
    case fontToolsMissing
    case scriptNotFound
    case patchFailed(String)

    var errorDescription: String? {
        switch self {
        case .pythonNotFound:
            return "python3 not found. Install with:  brew install python@3.14"
        case .fontToolsMissing:
            return "python3 found, but fontTools is not installed. Run:  python3 -m pip install fonttools svgpathtools cu2qu"
        case .scriptNotFound:
            return "Bundled enshittifier.py is missing. Re-install the app."
        case .patchFailed(let detail):
            return detail
        }
    }
}

/// Front door for patching a font file. Drives the bundled Python
/// patching engine via `PythonPatcher`. The Swift table patchers in this
/// directory are exploratory scaffolding for a possible future native
/// port — not wired into the production path; exercised only by
/// `Patcher.shared.patchWithSwiftOnly(url:)` for isolated testing.
final class Patcher: Sendable {
    static let shared = Patcher()
    private init() {}

    /// Production patch path.
    func patch(url: URL) throws {
        try PythonPatcher().patch(url: url)
    }

    /// Test-only path that runs the in-Swift table patchers in isolation.
    /// Does not substitute "ai" with the poop glyph (glyph drawing + GSUB
    /// compilation aren't ported); useful only for unit-testing the
    /// cmap/name parsers.
    func patchWithSwiftOnly(url: URL) throws {
        var data = try Data(contentsOf: url)
        data = try CmapTablePatcher.addPoopMapping(in: data)
        data = try NameTablePatcher.addSpacelessAlias(in: data)
        try data.write(to: url, options: [.atomic])
    }
}
