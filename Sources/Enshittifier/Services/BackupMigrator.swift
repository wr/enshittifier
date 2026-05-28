import Foundation

/// One-shot migration of the pre-W-194 backup folder
/// (`~/Desktop/Fonts (Backup)/`) to the new home at `~/Library/Font Backups/`.
///
/// Runs on every launch but no-ops if the legacy directory is absent. We
/// keep this in-app rather than as a release-note instruction so users
/// who upgrade across multiple versions don't end up with backups
/// stranded on the Desktop after a future update assumes the new path.
enum BackupMigrator {
    struct Outcome {
        var moved: Bool = false
        var rewroteManifest: Bool = false
        var errors: [String] = []
    }

    @discardableResult
    static func migrateIfNeeded() -> Outcome {
        var outcome = Outcome()
        let fm = FileManager.default
        let legacy = Paths.legacyDesktopBackupDir
        let target = Paths.backupDir

        guard fm.fileExists(atPath: legacy.path) else { return outcome }

        do {
            if !fm.fileExists(atPath: target.path) {
                try fm.createDirectory(at: target.deletingLastPathComponent(),
                                       withIntermediateDirectories: true)
                try fm.moveItem(at: legacy, to: target)
                outcome.moved = true
            } else {
                // Both exist (e.g. partial prior migration). Merge legacy
                // contents into target, preferring whatever already lives
                // at target. Best-effort.
                try mergeDirectory(from: legacy, into: target, fm: fm)
                try? fm.removeItem(at: legacy)
                outcome.moved = true
            }
        } catch {
            outcome.errors.append("Couldn\u{2019}t move backup folder off Desktop: \(error.localizedDescription)")
            return outcome
        }

        // Rewrite any backup_path entries in origins.json that still
        // point at the old root.
        let manifestURL = Paths.originsFile
        guard fm.fileExists(atPath: manifestURL.path) else { return outcome }

        do {
            let data = try Data(contentsOf: manifestURL)
            guard var root = try JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] else {
                return outcome
            }
            let oldPrefix = legacy.standardizedFileURL.path + "/"
            let newPrefix = target.standardizedFileURL.path + "/"
            var changed = false
            for (key, var entry) in root {
                if let bp = entry["backup_path"] as? String, bp.hasPrefix(oldPrefix) {
                    entry["backup_path"] = newPrefix + bp.dropFirst(oldPrefix.count)
                    root[key] = entry
                    changed = true
                }
            }
            if changed {
                let rewritten = try JSONSerialization.data(
                    withJSONObject: root,
                    options: [.prettyPrinted, .sortedKeys]
                )
                try rewritten.write(to: manifestURL, options: [.atomic])
                outcome.rewroteManifest = true
            }
        } catch {
            outcome.errors.append("Couldn\u{2019}t rewrite origins.json paths: \(error.localizedDescription)")
        }

        return outcome
    }

    private static func mergeDirectory(from src: URL, into dst: URL, fm: FileManager) throws {
        guard let enumerator = fm.enumerator(at: src,
                                             includingPropertiesForKeys: [.isDirectoryKey],
                                             options: []) else { return }
        let srcRoot = src.standardizedFileURL.path
        for case let item as URL in enumerator {
            let rel = String(item.standardizedFileURL.path.dropFirst(srcRoot.count + 1))
            let destination = dst.appendingPathComponent(rel)
            let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir {
                try? fm.createDirectory(at: destination, withIntermediateDirectories: true)
            } else if !fm.fileExists(atPath: destination.path) {
                try fm.createDirectory(at: destination.deletingLastPathComponent(),
                                       withIntermediateDirectories: true)
                try fm.copyItem(at: item, to: destination)
            }
        }
    }
}
