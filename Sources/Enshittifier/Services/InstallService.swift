import Foundation
import CoreText

struct InstallResult {
    var installed: [String] = []
    var errors: [String] = []
    /// Live URLs of the patched font files (shadow copy under
    /// ~/Library/Fonts/ for system fonts, in-place URL for user fonts).
    /// Used by the UI to ask CoreText to re-register so previews
    /// refresh without an app restart.
    var patchedURLs: [URL] = []
}

enum InstallService {
    /// Back up and patch each selected style. Reports progress via the
    /// callback (which may be invoked from a background thread; callers
    /// should marshal to the main actor if updating UI).
    ///
    /// Same on-disk contract as the Python installer (W-114, W-124):
    ///  - Backup folder:  ~/Library/Font Backups/
    ///  - Manifest:       ~/Library/Font Backups/origins.json
    ///  - System fonts:   copy to ~/Library/Fonts/, patch the copy
    ///  - User fonts:     patch original in place
    ///
    /// Patching itself is delegated to `Patcher.patch(url:)`, which drives
    /// the bundled Python patching engine.
    static func install(
        styles: [FontStyle],
        progress: @escaping @Sendable (InstallUpdate) -> Void
    ) async -> InstallResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = installSync(styles: styles, progress: progress)
                continuation.resume(returning: result)
            }
        }
    }

    private static func installSync(
        styles: [FontStyle],
        progress: @escaping @Sendable (InstallUpdate) -> Void
    ) -> InstallResult {
        var result = InstallResult()
        let fm = FileManager.default

        do {
            try fm.createDirectory(at: Paths.backupDir, withIntermediateDirectories: true)
        } catch {
            result.errors.append("Could not create backup folder: \(error.localizedDescription)")
            return result
        }

        var manifest = (try? OriginsManifestStore.load()) ?? OriginsManifest()

        progress(.start(total: styles.count))

        for (index, style) in styles.enumerated() {
            progress(.progress(index: index, name: style.filename))

            do {
                let patched = try installOne(style: style, manifest: &manifest, fm: fm)
                result.installed.append(style.filename)
                result.patchedURLs.append(contentsOf: patched)
                progress(.completed(name: style.filename))
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                result.errors.append("\(style.filename): \(message)")
                progress(.failed(name: style.filename, message: message))
            }
        }

        do {
            try OriginsManifestStore.save(manifest)
        } catch {
            result.errors.append("Could not write origins manifest: \(error.localizedDescription)")
        }

        // Patches are written + manifest saved. Tell the UI it can close
        // before kicking off the slow fontd bounce, so the dialog doesn't
        // hold the user hostage for ~10s.
        progress(.done)

        progress(.phase("Restarting font services\u{2026}"))
        FontCacheFlusher.flush()
        progress(.phase("Reactivating fonts\u{2026}"))
        InstallService.refreshFontRegistration(urls: result.patchedURLs)
        progress(.finalized)

        return result
    }

    /// Ask CoreText to re-read each patched file. We hit two scopes:
    ///   - `.user`: persists across processes via fontd, so other apps pick
    ///     up the new bytes once fontd has finished its post-bounce scan.
    ///   - `.process`: registers directly in this app's font manager, so
    ///     `.font(.custom(family))` resolves to the freshly-read descriptor
    ///     in our previews without waiting for fontd's IPC to propagate (or
    ///     for the in-process CoreText cache to invalidate on its own).
    static func refreshFontRegistration(urls: [URL]) {
        guard !urls.isEmpty else { return }
        let cf = urls as CFArray
        CTFontManagerUnregisterFontURLs(cf, .process, nil)
        CTFontManagerUnregisterFontURLs(cf, .user, nil)
        CTFontManagerRegisterFontURLs(cf, .user, true, nil)
        CTFontManagerRegisterFontURLs(cf, .process, true, nil)
    }

    private static func installOne(
        style: FontStyle,
        manifest: inout OriginsManifest,
        fm: FileManager
    ) throws -> [URL] {
        let canonical = style.url
        var patched: [URL] = []

        // 1. Back up + patch the user-selected canonical file (or its shadow,
        //    for system fonts).
        let backupURL = Paths.backupDestination(for: canonical, location: style.location)
        try fm.createDirectory(at: backupURL.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        if !fm.fileExists(atPath: backupURL.path) {
            try fm.copyItem(at: canonical, to: backupURL)
        }

        let patchTarget: URL
        if style.shouldShadow {
            // System font: copy into ~/Library/Fonts/ (flat) and patch the copy.
            // Flat shadow is correct — CoreText resolves by PostScript name,
            // and ~/Library/Fonts/ is the canonical user-font directory.
            let shadowURL = Paths.userFontDir.appendingPathComponent(style.filename)
            try fm.createDirectory(at: Paths.userFontDir, withIntermediateDirectories: true)
            if !fm.fileExists(atPath: shadowURL.path) {
                try fm.copyItem(at: canonical, to: shadowURL)
            }
            patchTarget = shadowURL
        } else {
            patchTarget = canonical
        }
        try Patcher.shared.patch(url: patchTarget)
        manifest.record(filename: style.filename,
                        originalPath: canonical,
                        backupPath: backupURL,
                        location: style.location)
        patched.append(patchTarget)

        // 2. For user fonts only: any sibling in ~/Library/Fonts/ sharing this
        //    PostScript name would compete with the patched canonical and may
        //    cause macOS to either prefer the un-patched copy or — if every
        //    copy gets patched — deactivate them all as duplicates. Move each
        //    duplicate into backup so only the patched canonical remains.
        if !style.shouldShadow {
            let canonicalPath = canonical.standardizedFileURL.path
            let dupes = findSiblings(of: canonical, in: Paths.userFontDir)
                .filter { $0.standardizedFileURL.path != canonicalPath }
            for dupe in dupes {
                let dupeBackup = Paths.backupDestination(for: dupe, location: .user)
                try fm.createDirectory(at: dupeBackup.deletingLastPathComponent(),
                                       withIntermediateDirectories: true)
                // If the backup already exists, it holds the original bytes
                // from an earlier run — leave it alone; the `dupe` on disk may
                // have been patched and we don't want to overwrite the
                // pristine backup with patched bytes.
                if !fm.fileExists(atPath: dupeBackup.path) {
                    try fm.copyItem(at: dupe, to: dupeBackup)
                }
                manifest.record(filename: dupe.lastPathComponent,
                                originalPath: dupe,
                                backupPath: dupeBackup,
                                location: .user)
                try? fm.removeItem(at: dupe)
            }
        }

        return patched
    }

    /// Return every patchable font file under `root` whose first descriptor's
    /// PostScript name matches the seed's. Always includes the seed itself.
    private static func findSiblings(of seed: URL, in root: URL) -> [URL] {
        guard let seedKey = postScriptName(at: seed) else { return [seed] }
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return [seed]
        }
        let seedPath = seed.standardizedFileURL.path
        var matches: [URL] = []
        var seenSeed = false
        for case let url as URL in enumerator {
            let ext = url.pathExtension.lowercased()
            guard FontDiscovery.patchableExtensions.contains(ext) else { continue }
            let path = url.standardizedFileURL.path
            if path == seedPath { seenSeed = true; matches.append(url); continue }
            if postScriptName(at: url) == seedKey {
                matches.append(url)
            }
        }
        if !seenSeed { matches.append(seed) }
        return matches
    }

    private static func postScriptName(at url: URL) -> String? {
        guard let cf = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL),
              CFArrayGetCount(cf) > 0 else { return nil }
        let raw = CFArrayGetValueAtIndex(cf, 0)!
        let desc = unsafeBitCast(raw, to: CTFontDescriptor.self)
        let font = CTFontCreateWithFontDescriptor(desc, 12.0, nil)
        return (CTFontCopyPostScriptName(font) as String?)?.lowercased()
    }
}

enum OriginsManifestStore {
    static func load() throws -> OriginsManifest {
        let url = Paths.originsFile
        guard FileManager.default.fileExists(atPath: url.path) else { return OriginsManifest() }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(OriginsManifest.self, from: data)
    }

    static func save(_ manifest: OriginsManifest) throws {
        try FileManager.default.createDirectory(at: Paths.backupDir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest)
        try data.write(to: Paths.originsFile, options: [.atomic])
    }
}
