import Foundation
import CoreText
import CoreGraphics
import SwiftUI

/// Builds a SwiftUI `Font` directly from a file's bytes, bypassing
/// CoreText's family-name resolution cache.
///
/// Why this exists: `.font(.custom("Family"))` goes through CoreText's
/// in-process descriptor / font-instance cache, which is keyed by font
/// identity (PSName/family) — not by file mtime. After we patch a font in
/// place, that cache keeps serving the pre-patch `CTFont` until process
/// restart. `CTFontManagerUnregister`/`Register` (in either `.user` or
/// `.process` scope) does not displace the cached instance.
///
/// The escape hatch is to hand CoreText the file's *bytes* directly:
/// `Data → CGDataProvider → CGFont → CTFontCreateWithGraphicsFont`. The
/// resulting `CTFont` is keyed by the `CGFont` object you pass in, not by
/// any name lookup, so the post-patch bytes show up immediately.
///
/// Cache key is `(inode, mtime)` so it correctly invalidates whether the
/// patcher rewrote in place (mtime bumps, inode unchanged) or wrote a
/// tempfile and renamed (inode bumps too).
@MainActor
enum DataFontCache {
    private static let cache: NSCache<NSString, CGFont> = {
        let c = NSCache<NSString, CGFont>()
        // Roughly two screens worth of tiles in the lazy grid.
        c.countLimit = 512
        return c
    }()

    /// Returns a SwiftUI Font built from `url`'s current bytes, or nil if
    /// the file can't be parsed. Callers should fall back to
    /// `.custom(familyName)` on nil.
    static func font(at url: URL, size: CGFloat) -> Font? {
        guard let cg = cgFont(at: url) else { return nil }
        let ct = CTFontCreateWithGraphicsFont(cg, size, nil, nil)
        return Font(ct)
    }

    private static func cgFont(at url: URL) -> CGFont? {
        if let key = cacheKey(for: url),
           let cached = cache.object(forKey: key) {
            return cached
        }
        guard let loaded = load(at: url) else { return nil }
        if let key = cacheKey(for: url) {
            cache.setObject(loaded, forKey: key)
        }
        return loaded
    }

    private static func load(at url: URL) -> CGFont? {
        // Plain (un-mapped) read on purpose. Memory-mapping the same path
        // across an in-place patch can serve stale pages because the inode
        // didn't change. The font files we care about are O(100KB) so the
        // cost of a real read is fine and the cache makes it a one-shot
        // per (inode, mtime).
        guard let data = try? Data(contentsOf: url),
              let provider = CGDataProvider(data: data as CFData),
              let cgFont = CGFont(provider) else {
            return nil
        }
        return cgFont
    }

    private static func cacheKey(for url: URL) -> NSString? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return nil
        }
        guard let inode = attrs[.systemFileNumber] as? NSNumber else { return nil }
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(inode.uint64Value)@\(mtime)" as NSString
    }
}
