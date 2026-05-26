import Foundation
import CoreText

/// Walks the user + system font directories, reads family/style metadata
/// via Core Text, and groups results into FontFamily values.
///
/// Mirrors the discovery behavior of `installer/enshittifier_installer.py`:
/// - recursive (post W-124) so /System/Library/Fonts/Supplemental/ is covered
/// - dedupes by (family, style) with user winning over system (CoreText
///   prefers user copies, so shadowing the system one is redundant)
/// - excludes SF Pro / SF Compact / SFNS / .AppleSystemUIFont (loaded by
///   WindowServer via private paths, can't be shadowed)
enum FontDiscovery {
    static let userFontDir: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Fonts", isDirectory: true)
    }()

    static let systemFontDir = URL(fileURLWithPath: "/System/Library/Fonts", isDirectory: true)

    static let patchableExtensions: Set<String> = ["ttf", "otf"]

    // Substrings (case-insensitive) that mark a family as load-via-private-path
    // and therefore not patchable by ~/Library/Fonts/ shadowing:
    //   "SF Pro", "SF Compact", "SF Mono", ".AppleSystemUIFont", "SFNS"
    private static let excludedFamilySubstrings = [
        "sf pro", "sfpro",
        "sf compact", "sfcompact",
        "sf mono", "sfmono",
        ".applesystemuifont",
        "sfns",
    ]

    static func isExcluded(family: String) -> Bool {
        let lower = family.lowercased()
        for needle in excludedFamilySubstrings where lower.contains(needle) {
            return true
        }
        return false
    }

    static func discover() async -> [FontFamily] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let families = discoverSync()
                continuation.resume(returning: families)
            }
        }
    }

    /// URLs of every font CoreText currently considers active. Used to flag
    /// deactivated-in-Font-Book files at discovery time.
    static func activeFontURLPaths() -> Set<String> {
        let collection = CTFontCollectionCreateFromAvailableFonts(nil)
        guard let descriptors = CTFontCollectionCreateMatchingFontDescriptors(collection) as? [CTFontDescriptor] else {
            return []
        }
        var out = Set<String>()
        out.reserveCapacity(descriptors.count)
        for d in descriptors {
            if let url = CTFontDescriptorCopyAttribute(d, kCTFontURLAttribute) as? URL {
                out.insert(url.standardizedFileURL.path)
            }
        }
        return out
    }

    static func discoverSync() -> [FontFamily] {
        var seenStyleKeys = Set<String>()  // "Family|Style"
        var familiesByName: [String: FontFamily] = [:]

        // User first so user wins on collisions
        let userURLs = collectFontFiles(in: userFontDir)
        let systemURLs = collectFontFiles(in: systemFontDir)
        let activePaths = activeFontURLPaths()

        for (urls, location) in [(userURLs, FontLocation.user), (systemURLs, FontLocation.system)] {
            for url in urls {
                guard let descriptors = readDescriptors(at: url) else { continue }
                let isActive = activePaths.contains(url.standardizedFileURL.path)
                for desc in descriptors {
                    let font = CTFontCreateWithFontDescriptor(desc, 12.0, nil)
                    guard let family = CTFontCopyFamilyName(font) as String? else { continue }
                    if family.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
                    if isExcluded(family: family) { continue }
                    let style = (CTFontCopyName(font, kCTFontStyleNameKey) as String?) ?? "Regular"

                    let key = "\(family)|\(style)"
                    if seenStyleKeys.contains(key) { continue }
                    seenStyleKeys.insert(key)

                    let id = "\(family)|\(style)|\(url.path)"
                    let fontStyle = FontStyle(
                        id: id,
                        styleName: style,
                        familyName: family,
                        url: url,
                        location: location,
                        isActivated: isActive
                    )

                    if var existing = familiesByName[family] {
                        existing.styles.append(fontStyle)
                        familiesByName[family] = existing
                    } else {
                        familiesByName[family] = FontFamily(
                            id: family,
                            name: family,
                            styles: [fontStyle]
                        )
                    }
                }
            }
        }

        return familiesByName.values
            .map { family -> FontFamily in
                var f = family
                f.styles.sort { lhs, rhs in
                    sortRank(of: lhs.styleName) < sortRank(of: rhs.styleName) ||
                    (sortRank(of: lhs.styleName) == sortRank(of: rhs.styleName) &&
                     lhs.styleName.localizedCompare(rhs.styleName) == .orderedAscending)
                }
                return f
            }
            .sorted { lhs, rhs in
                // Dot-prefixed family names (".Keyboard", ".AppleSystemUIFont",
                // etc.) sort after regular names so they don't clutter the
                // top of the list.
                let lDot = lhs.name.hasPrefix(".")
                let rDot = rhs.name.hasPrefix(".")
                if lDot != rDot { return !lDot }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    // MARK: -

    private static func collectFontFiles(in dir: URL) -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: dir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var results: [URL] = []
        for case let url as URL in enumerator {
            let ext = url.pathExtension.lowercased()
            guard patchableExtensions.contains(ext) else { continue }
            results.append(url)
        }
        return results
    }

    private static func readDescriptors(at url: URL) -> [CTFontDescriptor]? {
        guard let cfArray = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) else { return nil }
        let count = CFArrayGetCount(cfArray)
        if count == 0 { return nil }
        var results: [CTFontDescriptor] = []
        results.reserveCapacity(count)
        for i in 0..<count {
            let raw = CFArrayGetValueAtIndex(cfArray, i)!
            results.append(unsafeBitCast(raw, to: CTFontDescriptor.self))
        }
        return results
    }

    /// Sort weight first (Thin → Black), then italic suffix. Common ordering.
    private static func sortRank(of style: String) -> Int {
        let s = style.lowercased()
        if s.contains("thin") { return 0 }
        if s.contains("hairline") { return 0 }
        if s.contains("extralight") || s.contains("ultralight") { return 10 }
        if s.contains("light") { return 20 }
        if s.contains("regular") || s == "italic" || s == "oblique" { return 30 }
        if s.contains("medium") { return 40 }
        if s.contains("semibold") || s.contains("demibold") { return 50 }
        if s.contains("bold") && !s.contains("extra") && !s.contains("ultra") { return 60 }
        if s.contains("extrabold") || s.contains("ultrabold") || s.contains("heavy") { return 70 }
        if s.contains("black") { return 80 }
        return 35
    }
}
