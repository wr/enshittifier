import Foundation

/// On-disk record of what the installer backed up and where it came from.
/// Persisted as `~/Desktop/Fonts (Backup)/origins.json`.
///
/// Schema v2 (current): keyed by absolute original_path string so two
/// fonts sharing a filename in different directories don't collide.
/// Each entry stores the backup_path explicitly so the backup folder can
/// mirror the source's subdirectory structure (e.g.
/// `Fonts (Backup)/user/Cabin/Cabin-Regular.ttf`).
///
/// Schema v1 (legacy, read-only): keyed by filename, no backup_path —
/// the backup lived at `~/Desktop/Fonts (Backup)/<filename>` (flat).
/// Old entries are migrated implicitly: on read they get a synthesized
/// backup_path; on next write they're persisted in the v2 shape.
struct OriginsManifest: Codable {
    struct Entry: Codable, Hashable {
        let filename: String
        let originalPath: String
        let backupPath: String
        let location: String  // "user" or "system"

        enum CodingKeys: String, CodingKey {
            case filename
            case originalPath = "original_path"
            case backupPath = "backup_path"
            case location
        }
    }

    /// Keyed by absolute original_path string.
    var entries: [String: Entry]

    init(entries: [String: Entry] = [:]) {
        self.entries = entries
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode([String: [String: String]].self)

        var migrated: [String: Entry] = [:]
        for (key, value) in raw {
            let originalPath = value["original_path"] ?? key
            let filename = value["filename"] ?? (originalPath as NSString).lastPathComponent
            let location = value["location"] ?? "user"
            let backupPath = value["backup_path"]
                ?? (Paths.backupDir.appendingPathComponent(filename).path)
            migrated[originalPath] = Entry(
                filename: filename,
                originalPath: originalPath,
                backupPath: backupPath,
                location: location
            )
        }
        self.entries = migrated
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(entries)
    }

    mutating func record(filename: String, originalPath: URL, backupPath: URL, location: FontLocation) {
        entries[originalPath.path] = Entry(
            filename: filename,
            originalPath: originalPath.path,
            backupPath: backupPath.path,
            location: location.rawValue
        )
    }

    mutating func remove(originalPath: String) {
        entries.removeValue(forKey: originalPath)
    }
}
