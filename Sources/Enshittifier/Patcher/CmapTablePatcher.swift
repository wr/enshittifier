import Foundation

/// Read-only cmap inspector — exploratory Swift scaffolding for a possible
/// future native port of the patcher. Not used by the production path;
/// the shipped patcher is the bundled Python engine. The Swift write side
/// (append a format-12 subtable mapping U+1F4A9 → glyph "poop", recompute
/// checksums, lay the table back in) isn't implemented.
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

    /// Throws — Swift-side cmap writing is not implemented; callers should
    /// route through the Python engine (`PythonPatcher`).
    static func addPoopMapping(in data: Data) throws -> Data {
        // Validate that we can at least parse the source's cmap; this
        // catches malformed fonts early and exercises the read path.
        _ = try summarize(in: data)
        throw Failure.notImplemented(
            "Swift cmap write path is not implemented; use PythonPatcher."
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
