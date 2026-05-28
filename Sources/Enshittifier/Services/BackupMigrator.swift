import Foundation

/// One-shot migration of the pre-W-194 backup folder
/// (`~/Desktop/Fonts (Backup)/`) to the new home at `~/Library/Font Backups/`.
///
/// Runs on every launch but no-ops if neither the legacy directory nor any
/// stale legacy-prefixed `backup_path` entries are present. We keep this
/// in-app rather than as a release-note instruction so users who upgrade
/// across multiple versions don't end up with backups stranded on the
/// Desktop after a future update assumes the new path.
///
/// The dir-move and the manifest-rewrite are independent and each
/// idempotent: a failure in one half can be retried on the next launch
/// without re-doing the other.
enum BackupMigrator {
    struct Outcome {
        var moved: Bool = false
        var rewroteManifest: Bool = false
        var errors: [String] = []
    }

    /// `phase` is called (off the main actor) when a perceptible step
    /// begins, so the UI can label what's happening. It only fires when
    /// there's real work to do — a no-op launch reports nothing, which is
    /// what lets the caller skip showing any progress UI at all.
    @discardableResult
    static func migrateIfNeeded(phase: @Sendable (String) -> Void = { _ in }) -> Outcome {
        var outcome = Outcome()
        let fm = FileManager.default

        // Rewrite the manifest first. Safe to attempt regardless of whether
        // the legacy folder still exists — if files have already moved but
        // the manifest still points at the old root, this is the only
        // chance to fix it.
        rewriteManifestPaths(fm: fm, outcome: &outcome, phase: phase)

        // Then move the legacy directory. If this fails, the manifest is
        // already pointing at the new location, so a retry next launch
        // will find any remaining work via the same idempotent path.
        moveLegacyDirectory(fm: fm, outcome: &outcome, phase: phase)

        return outcome
    }

    private static func moveLegacyDirectory(
        fm: FileManager,
        outcome: inout Outcome,
        phase: @Sendable (String) -> Void
    ) {
        let legacy = Paths.legacyDesktopBackupDir
        let target = Paths.backupDir

        guard fm.fileExists(atPath: legacy.path) else { return }

        phase("Moving your font backups\u{2026}")

        do {
            if !fm.fileExists(atPath: target.path) {
                try fm.createDirectory(at: target.deletingLastPathComponent(),
                                       withIntermediateDirectories: true)
                try fm.moveItem(at: legacy, to: target)
                outcome.moved = true
            } else {
                // Both exist (partial prior migration, or the user created
                // ~/Library/Font Backups/ themselves). Merge the legacy
                // tree into target, preserving every legacy file — on
                // name collisions the legacy copy is moved aside with a
                // `.legacy` suffix rather than dropped on the floor.
                try mergeDirectory(from: legacy, into: target, fm: fm)
                // Best-effort: only remove the legacy root if it's empty
                // after the merge. Anything left behind survived because
                // we couldn't safely place it; leaving it visible on the
                // Desktop is preferable to silent loss.
                let leftovers = (try? fm.contentsOfDirectory(atPath: legacy.path)) ?? []
                if leftovers.isEmpty {
                    try? fm.removeItem(at: legacy)
                    outcome.moved = true
                } else {
                    outcome.errors.append(
                        "Some backup files couldn\u{2019}t be merged into \(target.path); "
                        + "they remain at \(legacy.path)."
                    )
                }
            }
        } catch {
            outcome.errors.append(
                "Couldn\u{2019}t move backup folder off Desktop: \(error.localizedDescription)"
            )
        }
    }

    private static func rewriteManifestPaths(
        fm: FileManager,
        outcome: inout Outcome,
        phase: @Sendable (String) -> Void
    ) {
        let manifestURL = Paths.originsFile
        guard fm.fileExists(atPath: manifestURL.path) else { return }

        let data: Data
        do {
            data = try Data(contentsOf: manifestURL)
        } catch {
            outcome.errors.append(
                "Couldn\u{2019}t read origins.json for migration: \(error.localizedDescription)"
            )
            return
        }

        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: data)
        } catch {
            outcome.errors.append(
                "Couldn\u{2019}t parse origins.json for migration: \(error.localizedDescription)"
            )
            return
        }

        guard var root = parsed as? [String: [String: Any]] else {
            outcome.errors.append(
                "origins.json wasn\u{2019}t in the expected shape; skipped path rewrite."
            )
            return
        }

        // Match on both the standardized form and the raw "~/Desktop/..."
        // expansion in case the manifest was written before path
        // normalization changed (symlinks, /private prefix, etc).
        let legacyStandardized = Paths.legacyDesktopBackupDir.standardizedFileURL.path + "/"
        let legacyHomeRelative =
            (NSString(string: "~/Desktop/Fonts (Backup)/").expandingTildeInPath as String) + "/"
        let candidates = Set([legacyStandardized, legacyHomeRelative])
        let newPrefix = Paths.backupDir.standardizedFileURL.path + "/"

        var changed = false
        for (key, var entry) in root {
            guard let bp = entry["backup_path"] as? String else { continue }
            for old in candidates where bp.hasPrefix(old) {
                entry["backup_path"] = newPrefix + bp.dropFirst(old.count)
                root[key] = entry
                changed = true
                break
            }
        }

        guard changed else { return }

        phase("Updating font records\u{2026}")

        do {
            let rewritten = try JSONSerialization.data(
                withJSONObject: root,
                options: [.prettyPrinted, .sortedKeys]
            )
            try rewritten.write(to: manifestURL, options: [.atomic])
            outcome.rewroteManifest = true
        } catch {
            outcome.errors.append(
                "Couldn\u{2019}t rewrite origins.json paths: \(error.localizedDescription)"
            )
        }
    }

    /// Copy every file under `src` into the matching location under `dst`,
    /// preserving the legacy copy on name collisions by appending `.legacy`
    /// (numbered if that's also taken). Files copied successfully are
    /// removed from `src`; conflicting files that couldn't be moved aside
    /// stay put so the caller can surface them rather than delete them.
    private static func mergeDirectory(from src: URL, into dst: URL, fm: FileManager) throws {
        guard let enumerator = fm.enumerator(
            at: src,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) else { return }

        let srcRoot = src.standardizedFileURL.path
        for case let item as URL in enumerator {
            let rel = String(item.standardizedFileURL.path.dropFirst(srcRoot.count + 1))
            let destination = dst.appendingPathComponent(rel)
            let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir {
                try? fm.createDirectory(at: destination, withIntermediateDirectories: true)
                continue
            }

            try fm.createDirectory(at: destination.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)

            let placed: URL
            if !fm.fileExists(atPath: destination.path) {
                placed = destination
            } else {
                // Don't clobber. Park the legacy file next to the target
                // with a `.legacy` (or `.legacy.N`) suffix so the user
                // can resolve the collision by hand.
                let parked = uniqueLegacyURL(for: destination, fm: fm)
                placed = parked
            }
            try fm.copyItem(at: item, to: placed)
            try? fm.removeItem(at: item)
        }
    }

    private static func uniqueLegacyURL(for original: URL, fm: FileManager) -> URL {
        let base = original.appendingPathExtension("legacy")
        if !fm.fileExists(atPath: base.path) { return base }
        var i = 2
        while true {
            let next = original.appendingPathExtension("legacy.\(i)")
            if !fm.fileExists(atPath: next.path) { return next }
            i += 1
        }
    }
}
