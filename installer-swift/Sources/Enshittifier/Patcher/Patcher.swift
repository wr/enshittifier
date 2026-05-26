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

/// Front door for patching a font file. Phase 1: delegates to the bundled
/// Python patcher (full functionality). The native Swift table patchers
/// in this directory exist for incremental porting; they're exercised by
/// `Patcher.shared.patchWithSwiftOnly(url:)` (test/debug path only).
final class Patcher: Sendable {
    static let shared = Patcher()
    private init() {}

    /// Production patch path. Currently shells out to the bundled Python
    /// patcher so the app produces correct output today.
    func patch(url: URL) throws {
        try PythonFallbackPatcher().patch(url: url)
    }

    /// Debug/test path — runs only the native Swift table edits. Does not
    /// substitute "ai" with the poop glyph (glyph drawing + GSUB
    /// compilation aren't ported yet); useful for verifying the Swift
    /// cmap/name patchers in isolation.
    func patchWithSwiftOnly(url: URL) throws {
        var data = try Data(contentsOf: url)
        data = try CmapTablePatcher.addPoopMapping(in: data)
        data = try NameTablePatcher.addSpacelessAlias(in: data)
        try data.write(to: url, options: [.atomic])
    }
}
