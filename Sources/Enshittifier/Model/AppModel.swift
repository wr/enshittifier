import Foundation
import Observation

@Observable
final class AppModel {
    enum Tab: String, CaseIterable, Identifiable, Hashable {
        case allFonts = "All Fonts"
        case unshittified = "Un-shittified"
        case enshittified = "Enshittified"
        case restoreOriginals = "Restore Originals"

        var id: String { rawValue }
        var systemImage: String {
            switch self {
            case .allFonts: return "square.grid.2x2"
            case .unshittified: return "character.book.closed"
            case .enshittified: return "wand.and.stars"
            case .restoreOriginals: return "arrow.uturn.backward"
            }
        }

        /// True when the tab is purely informational — no selection, no
        /// primary action. Used by the Enshittified tab so it doubles as
        /// a "what's been changed" surface without inviting clicks that
        /// belong on Restore Originals.
        var isReadOnly: Bool { self == .enshittified }
    }

    enum LoadState {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    enum ViewMode: String, CaseIterable, Hashable, Identifiable {
        case grid, list
        var id: String { rawValue }
        var systemImage: String {
            switch self {
            case .grid: return "square.grid.2x2"
            case .list: return "list.bullet"
            }
        }
    }

    enum LocationFilter: String, CaseIterable, Hashable, Identifiable {
        case all = "All Locations"
        case user = "User Fonts Only"
        case system = "System Fonts Only"
        var id: String { rawValue }
    }

    enum ActivationFilter: String, CaseIterable, Hashable, Identifiable {
        case all = "All"
        case active = "Active"
        case inactive = "Inactive"
        var id: String { rawValue }
    }

    var tab: Tab = .allFonts
    var viewMode: ViewMode = .grid
    var locationFilter: LocationFilter = .all
    var activationFilter: ActivationFilter = .all
    /// Tile width for grid view; bound to size slider (range 128…260).
    var tileSize: Double = 168
    /// Bumped after every install/restore so font-preview views can use
    /// `.id(model.fontGeneration)` to force SwiftUI to re-resolve fonts
    /// against CoreText's freshly-updated registration.
    var fontGeneration: Int = 0
    /// Toggles visibility of the horizontal filter pill bar.
    var showFilterBar: Bool = true

    var families: [FontFamily] = []
    var loadState: LoadState = .idle
    var searchQuery: String = ""

    /// IDs of selected styles. A family is "all selected" iff every style id is in this set.
    var selectedStyleIDs: Set<String> = []

    var restoreFamilies: [RestoreFamily] = [] {
        didSet { patchedOriginalPaths = Self.computePatchedPaths(from: restoreFamilies) }
    }
    /// Selected restore entry IDs (entry.id == original_path string).
    var selectedRestoreIDs: Set<String> = []

    // MARK: Derived

    /// Set of absolute file paths currently recorded as patched in the
    /// origins manifest. Used to filter "Un-shittified" vs "Enshittified
    /// Fonts" and to mark families as patched.
    ///
    /// Includes both `originalPath` (the pre-patch location, which is what
    /// the manifest is keyed by) AND `livePath` (the file with the
    /// patched bytes — same as originalPath for user fonts, but the
    /// ~/Library/Fonts/ shadow for system fonts). Discovery records the
    /// shadow URL for system fonts (since the user-dir copy wins the
    /// dedupe), so we need both to recognise a shadowed family as patched.
    ///
    /// Cached: recomputed only when `restoreFamilies` is assigned. Reading
    /// this on every tile/row render burned measurable CPU on large
    /// libraries when it was a `var { get }`.
    private(set) var patchedOriginalPaths: Set<String> = []

    private static func computePatchedPaths(from families: [RestoreFamily]) -> Set<String> {
        var out = Set<String>()
        for f in families {
            for e in f.entries {
                out.insert(e.originalPath.path)
                out.insert(e.livePath.path)
            }
        }
        return out
    }

    func isFamilyFullyPatched(_ family: FontFamily) -> Bool {
        let patched = patchedOriginalPaths
        return !family.styles.isEmpty &&
            family.styles.allSatisfy { patched.contains($0.url.path) }
    }

    func isFamilyPartiallyPatched(_ family: FontFamily) -> Bool {
        let patched = patchedOriginalPaths
        return family.styles.contains { patched.contains($0.url.path) }
    }

    var filteredFamilies: [FontFamily] {
        let q = searchQuery.trimmingCharacters(in: .whitespaces).lowercased()
        var base: [FontFamily]
        switch tab {
        case .allFonts:
            base = families
        case .unshittified:
            // Hide families with no remaining work to do — i.e. every
            // style already patched. Partially-patched families stay
            // visible so the user can finish the rest.
            base = families.filter { !isFamilyFullyPatched($0) }
        case .enshittified:
            // Read-only view of what's currently patched. Driven off the
            // same `families` list so previews come from live patched
            // bytes via `family.previewURL`. Restore actions live on the
            // dedicated `.restoreOriginals` tab.
            base = families.filter { isFamilyPartiallyPatched($0) }
        case .restoreOriginals:
            return []  // handled via restoreFamilies path
        }

        // Location filter — the Enshittified tab hides the location chips
        // (every patched system font lives at the same shadow path, so
        // the split has no meaning there) so applying a stale filter
        // from a previous tab would invisibly hide rows.
        let effectiveLocationFilter: LocationFilter = (tab == .enshittified) ? .all : locationFilter
        switch effectiveLocationFilter {
        case .all: break
        case .user:
            base = base.compactMap { f in
                let userStyles = f.styles.filter { $0.location == .user }
                return userStyles.isEmpty ? nil : FontFamily(id: f.id, name: f.name, styles: userStyles)
            }
        case .system:
            base = base.compactMap { f in
                let sysStyles = f.styles.filter { $0.location == .system }
                return sysStyles.isEmpty ? nil : FontFamily(id: f.id, name: f.name, styles: sysStyles)
            }
        }

        // Activation filter (Font Book activated vs deactivated)
        switch activationFilter {
        case .all: break
        case .active:
            base = base.compactMap { f in
                let keep = f.styles.filter { $0.isActivated }
                return keep.isEmpty ? nil : FontFamily(id: f.id, name: f.name, styles: keep)
            }
        case .inactive:
            base = base.compactMap { f in
                let keep = f.styles.filter { !$0.isActivated }
                return keep.isEmpty ? nil : FontFamily(id: f.id, name: f.name, styles: keep)
            }
        }

        guard !q.isEmpty else { return base }
        return base.filter { $0.name.lowercased().contains(q) }
    }

    func selectionState(for family: FontFamily) -> SelectionState {
        let total = family.styles.count
        let selected = family.styles.lazy.filter { self.selectedStyleIDs.contains($0.id) }.count
        if selected == 0 { return .off }
        if selected == total { return .on }
        return .partial
    }

    func toggleFamily(_ family: FontFamily) {
        let state = selectionState(for: family)
        if state == .on {
            for s in family.styles { selectedStyleIDs.remove(s.id) }
        } else {
            for s in family.styles { selectedStyleIDs.insert(s.id) }
        }
    }

    func selectAll() {
        selectedStyleIDs = Set(families.flatMap { $0.styles.map(\.id) })
    }

    func selectNone() {
        selectedStyleIDs.removeAll()
    }

    var selectedStyles: [FontStyle] {
        families.flatMap { $0.styles }.filter { selectedStyleIDs.contains($0.id) }
    }

    // MARK: Restore-side derived

    func restoreSelectionState(for family: RestoreFamily) -> SelectionState {
        let total = family.entries.count
        let selected = family.entries.lazy.filter { self.selectedRestoreIDs.contains($0.id) }.count
        if selected == 0 { return .off }
        if selected == total { return .on }
        return .partial
    }

    func toggleRestoreFamily(_ family: RestoreFamily) {
        let state = restoreSelectionState(for: family)
        if state == .on {
            for e in family.entries { selectedRestoreIDs.remove(e.id) }
        } else {
            for e in family.entries { selectedRestoreIDs.insert(e.id) }
        }
    }

    func selectAllRestore() {
        selectedRestoreIDs = Set(restoreFamilies.flatMap { $0.entries.map(\.id) })
    }

    func selectNoneRestore() {
        selectedRestoreIDs.removeAll()
    }

    var allRestoreEntries: [RestoreEntry] {
        restoreFamilies.flatMap { $0.entries }
    }

    var selectedRestoreEntries: [RestoreEntry] {
        allRestoreEntries.filter { selectedRestoreIDs.contains($0.id) }
    }
}

enum SelectionState {
    case off, partial, on
}

struct RestoreEntry: Identifiable, Hashable {
    let id: String              // original_path string (unique key)
    let filename: String
    let familyName: String
    let styleName: String
    /// Where the font lived *before* we touched it. For user fonts this is
    /// also the live patched file (we patch in place). For system fonts
    /// this points at /System/Library/Fonts/... which is **never modified**
    /// — the patched copy lives at `livePath`.
    let originalPath: URL
    let backupPath: URL
    let location: FontLocation

    /// File currently on disk holding the *patched* bytes.
    /// - User fonts: same as `originalPath` (in-place patch).
    /// - System fonts: `~/Library/Fonts/<filename>` (the shadow copy).
    ///
    /// Use this for previews, "Reveal in Finder", and "Show in Font Book"
    /// so the user always lands on the file whose bytes were changed.
    var livePath: URL {
        switch location {
        case .user: return originalPath
        case .system: return Paths.userFontDir.appendingPathComponent(filename)
        }
    }
}

struct RestoreFamily: Identifiable, Hashable {
    let id: String              // family name
    let name: String
    var entries: [RestoreEntry]

    var entryCount: Int { entries.count }

    /// Live (patched) file URL to render in the preview tile. Prefers the
    /// upright Regular entry; falls back to the first. Uses `livePath` so
    /// system-font entries render bytes from the user-dir shadow, not the
    /// untouched /System original.
    var previewURL: URL? {
        if let regular = entries.first(where: { PreviewStyle.isRegular($0.styleName) }) {
            return regular.livePath
        }
        if let upright = entries.first(where: { !PreviewStyle.isItalic($0.styleName) }) {
            return upright.livePath
        }
        return entries.first?.livePath
    }
}
