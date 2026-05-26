import Foundation

enum FontLocation: String, Codable, Hashable, CaseIterable {
    case user
    case system
}

struct FontStyle: Identifiable, Hashable {
    let id: String
    let styleName: String
    let familyName: String
    let url: URL
    let location: FontLocation
    /// Whether CoreText considers this file currently active. Deactivated
    /// fonts live on disk but Font Book (or another manager) has turned them
    /// off, so apps aren't loading them. Default `true` so callers that
    /// don't supply activation state get the historical behavior.
    let isActivated: Bool

    init(id: String, styleName: String, familyName: String, url: URL, location: FontLocation, isActivated: Bool = true) {
        self.id = id
        self.styleName = styleName
        self.familyName = familyName
        self.url = url
        self.location = location
        self.isActivated = isActivated
    }

    var shouldShadow: Bool { location == .system }

    var filename: String { url.lastPathComponent }
}
