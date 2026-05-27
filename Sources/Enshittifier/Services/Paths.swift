import Foundation

enum Paths {
    static var userFontDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Fonts", isDirectory: true)
    }

    static var systemFontDir: URL {
        URL(fileURLWithPath: "/System/Library/Fonts", isDirectory: true)
    }

    static var backupDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop/Fonts (Backup)", isDirectory: true)
    }

    static var originsFile: URL {
        backupDir.appendingPathComponent("origins.json", isDirectory: false)
    }

    /// Compute the backup destination for a source font that mirrors its
    /// source directory structure under `Fonts (Backup)/user|system/...`.
    ///
    /// Examples:
    ///   ~/Library/Fonts/Foo/Foo-Regular.ttf
    ///     → Fonts (Backup)/user/Foo/Foo-Regular.ttf
    ///   /System/Library/Fonts/Bar.ttf
    ///     → Fonts (Backup)/system/Bar.ttf
    ///   /System/Library/Fonts/Supplemental/Baz.ttf
    ///     → Fonts (Backup)/system/Supplemental/Baz.ttf
    static func backupDestination(for source: URL, location: FontLocation) -> URL {
        let root = location == .system ? systemFontDir : userFontDir
        let rootPath = root.standardizedFileURL.path
        let srcPath = source.standardizedFileURL.path
        let suffix: String
        if srcPath.hasPrefix(rootPath + "/") {
            suffix = String(srcPath.dropFirst(rootPath.count + 1))
        } else {
            // Source isn't actually under the expected root — fall back to the
            // bare filename in the location bucket.
            suffix = source.lastPathComponent
        }
        return backupDir
            .appendingPathComponent(location.rawValue, isDirectory: true)
            .appendingPathComponent(suffix, isDirectory: false)
    }
}
