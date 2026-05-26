import Foundation
import CoreText

struct RestoreResult {
    var restored: [String] = []
    var errors: [String] = []
    /// URLs whose CoreText registration should be refreshed after restore.
    /// For system fonts this is the (now-deleted) shadow URL; for user
    /// fonts it's the in-place URL whose contents have been replaced.
    var touchedURLs: [URL] = []
}

enum RestoreService {
    /// Read the manifest and group its entries by font family for display.
    /// Family/style metadata is read from each backup file via Core Text.
    static func discover() -> [RestoreFamily] {
        let manifest = (try? OriginsManifestStore.load()) ?? OriginsManifest()
        let fm = FileManager.default

        var entries: [RestoreEntry] = []
        for (_, m) in manifest.entries {
            let backupURL = URL(fileURLWithPath: m.backupPath)
            // If the backup file is missing (user moved it, etc.) skip silently.
            guard fm.fileExists(atPath: backupURL.path) else { continue }

            let location = FontLocation(rawValue: m.location) ?? .user
            let (family, style) = readFamilyStyle(at: backupURL) ?? (m.filename, "Regular")

            entries.append(RestoreEntry(
                id: m.originalPath,
                filename: m.filename,
                familyName: family,
                styleName: style,
                originalPath: URL(fileURLWithPath: m.originalPath),
                backupPath: backupURL,
                location: location
            ))
        }

        var byFamily: [String: [RestoreEntry]] = [:]
        for e in entries {
            byFamily[e.familyName, default: []].append(e)
        }
        return byFamily
            .map { (name, list) in
                RestoreFamily(id: name, name: name,
                              entries: list.sorted { $0.styleName.localizedCompare($1.styleName) == .orderedAscending })
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func readFamilyStyle(at url: URL) -> (String, String)? {
        guard let cfArray = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL),
              CFArrayGetCount(cfArray) > 0 else { return nil }
        let raw = CFArrayGetValueAtIndex(cfArray, 0)!
        let desc = unsafeBitCast(raw, to: CTFontDescriptor.self)
        let font = CTFontCreateWithFontDescriptor(desc, 12.0, nil)
        guard let family = CTFontCopyFamilyName(font) as String? else { return nil }
        let style = (CTFontCopyName(font, kCTFontStyleNameKey) as String?) ?? "Regular"
        return (family, style)
    }

    static func restore(
        entries: [RestoreEntry],
        progress: @escaping @Sendable (InstallUpdate) -> Void
    ) async -> RestoreResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: restoreSync(entries: entries, progress: progress))
            }
        }
    }

    private static func restoreSync(
        entries: [RestoreEntry],
        progress: @escaping @Sendable (InstallUpdate) -> Void
    ) -> RestoreResult {
        var result = RestoreResult()
        let fm = FileManager.default
        var manifest = (try? OriginsManifestStore.load()) ?? OriginsManifest()

        progress(.start(total: entries.count))

        for (index, entry) in entries.enumerated() {
            progress(.progress(index: index, name: entry.filename))

            do {
                switch entry.location {
                case .system:
                    // Remove shadow copy from ~/Library/Fonts/; system original untouched.
                    let shadow = Paths.userFontDir.appendingPathComponent(entry.filename)
                    if fm.fileExists(atPath: shadow.path) {
                        try fm.removeItem(at: shadow)
                    }
                    result.touchedURLs.append(shadow)
                case .user:
                    // Copy backup back to original path (overwriting the patched in-place file).
                    if fm.fileExists(atPath: entry.originalPath.path) {
                        try fm.removeItem(at: entry.originalPath)
                    }
                    try fm.createDirectory(at: entry.originalPath.deletingLastPathComponent(),
                                           withIntermediateDirectories: true)
                    try fm.copyItem(at: entry.backupPath, to: entry.originalPath)
                    result.touchedURLs.append(entry.originalPath)
                }

                try fm.removeItem(at: entry.backupPath)
                // Best-effort: clean up now-empty backup subdirectories so the
                // mirrored Fonts (Backup)/user/Cabin/ folder vanishes once the
                // last style under it is restored.
                pruneEmptyParents(of: entry.backupPath, stopAt: Paths.backupDir)
                manifest.remove(originalPath: entry.originalPath.path)
                result.restored.append(entry.filename)
                progress(.completed(name: entry.filename))
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                result.errors.append("\(entry.filename): \(message)")
                progress(.failed(name: entry.filename, message: message))
            }
        }

        // Save (or delete) the manifest
        if manifest.entries.isEmpty {
            try? fm.removeItem(at: Paths.originsFile)
        } else {
            try? OriginsManifestStore.save(manifest)
        }

        progress(.done)
        progress(.phase("Restarting font services\u{2026}"))
        FontCacheFlusher.flush()
        progress(.phase("Reactivating fonts\u{2026}"))
        refreshFontRegistration(urls: result.touchedURLs)
        progress(.finalized)
        return result
    }

    /// Drop any CoreText registrations for touched URLs, and re-register the
    /// ones that still exist on disk (in-place user-font restores). Hits
    /// both `.process` (for our previews) and `.user` (for other apps via
    /// fontd). Mirrors `InstallService.refreshFontRegistration`.
    private static func refreshFontRegistration(urls: [URL]) {
        guard !urls.isEmpty else { return }
        let fm = FileManager.default
        let cfAll = urls as CFArray
        CTFontManagerUnregisterFontURLs(cfAll, .process, nil)
        CTFontManagerUnregisterFontURLs(cfAll, .user, nil)
        let existing = urls.filter { fm.fileExists(atPath: $0.path) }
        if !existing.isEmpty {
            let cf = existing as CFArray
            CTFontManagerRegisterFontURLs(cf, .user, true, nil)
            CTFontManagerRegisterFontURLs(cf, .process, true, nil)
        }
    }

    private static func pruneEmptyParents(of file: URL, stopAt root: URL) {
        let fm = FileManager.default
        var dir = file.deletingLastPathComponent().standardizedFileURL
        let rootPath = root.standardizedFileURL.path
        while dir.path.hasPrefix(rootPath) && dir.path != rootPath {
            let contents = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
            if !contents.isEmpty { return }
            try? fm.removeItem(at: dir)
            dir = dir.deletingLastPathComponent().standardizedFileURL
        }
    }
}
