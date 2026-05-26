import Foundation

/// Phase 1: read-only cmap inspector.
///
/// The real patch (append a format-12 subtable mapping U+1F4A9 → glyph "poop")
/// requires writing a new cmap table, recomputing checksums, and either
/// rewriting the table directory in place or appending the table at the end
/// of the file with an updated offset. That work, plus correct parsing of
/// the source's existing format-4 / format-6 / format-12 subtables, lands
/// in a follow-up Linear issue (Phase 2 patcher port).
///
/// For now this file exists so the Swift project structure is in place and
/// the bones of cmap parsing are ready for the next phase to build on.
enum CmapTablePatcher {
    struct CmapSummary {
        let numSubtables: Int
        let subtableFormats: [UInt16]
    }

    /// Read-only: return what we know about the cmap table.
    static func summarize(in fileData: Data) throws -> CmapSummary {
        let font = try OpenTypeFile(data: fileData)
        guard let cmap = font.tableData(named: "cmap") else {
            throw Failure.tableMissing
        }

        var r = BinaryReader(cmap)
        _ = r.readUInt16()  // version (always 0)
        let numSubtables = Int(r.readUInt16())

        var subtableOffsets: [UInt32] = []
        for _ in 0..<numSubtables {
            _ = r.readUInt16()  // platformID
            _ = r.readUInt16()  // encodingID
            subtableOffsets.append(r.readUInt32())
        }

        var formats: [UInt16] = []
        for off in subtableOffsets {
            let absolute = Int(off)
            guard absolute + 2 <= cmap.count else { continue }
            var sub = BinaryReader(cmap, offset: absolute)
            formats.append(sub.readUInt16())
        }

        return CmapSummary(numSubtables: numSubtables, subtableFormats: formats)
    }

    /// Public stub for the Phase 1 native patch path. Throws to signal
    /// that the real write isn't implemented yet — callers should fall
    /// back to the Python path.
    static func addPoopMapping(in data: Data) throws -> Data {
        // Validate that we can at least parse the source's cmap; this
        // catches malformed fonts early and exercises the read path.
        _ = try summarize(in: data)
        throw Failure.notImplemented(
            "Swift cmap write path lands in Phase 2. Falling back to Python."
        )
    }

    enum Failure: LocalizedError {
        case tableMissing
        case notImplemented(String)

        var errorDescription: String? {
            switch self {
            case .tableMissing: return "Font has no 'cmap' table"
            case .notImplemented(let m): return m
            }
        }
    }
}
