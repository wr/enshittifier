import Foundation

struct FontFamily: Identifiable, Hashable {
    let id: String
    let name: String
    var styles: [FontStyle]

    var styleCount: Int { styles.count }

    var primaryLocation: FontLocation {
        styles.contains(where: { $0.location == .system }) && !styles.contains(where: { $0.location == .user })
            ? .system
            : .user
    }

    /// File URL to render in the preview tile. Prefers the upright Regular
    /// face so previews don't surprise the user with Italic/Thin glyphs —
    /// `styles` is sorted by weight (Thin first) in `FontDiscovery`, so
    /// `styles[0]` is usually *not* what we want here.
    var previewURL: URL? {
        if let regular = styles.first(where: { PreviewStyle.isRegular($0.styleName) }) {
            return regular.url
        }
        if let upright = styles.first(where: { !PreviewStyle.isItalic($0.styleName) }) {
            return upright.url
        }
        return styles.first?.url
    }
}

enum PreviewStyle {
    static func isRegular(_ styleName: String) -> Bool {
        let s = styleName.lowercased()
        if isItalic(s) { return false }
        return s == "regular" || s == "book" || s == "normal" || s == "roman"
    }

    static func isItalic(_ styleName: String) -> Bool {
        let s = styleName.lowercased()
        return s.contains("italic") || s.contains("oblique")
    }
}
