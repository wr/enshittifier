import Foundation

/// Read-only sfnt header + table directory parser.
///
/// An sfnt-wrapped font (TTF, OTF) starts with:
///   uint32 sfntVersion
///   uint16 numTables
///   uint16 searchRange / entrySelector / rangeShift   (hints, ignored on read)
/// then numTables * TableRecord (16 bytes each):
///   uint32 tag (4 ASCII chars)
///   uint32 checksum
///   uint32 offset
///   uint32 length
struct OpenTypeFile {
    struct TableRecord {
        let tag: String
        let checksum: UInt32
        let offset: UInt32
        let length: UInt32
    }

    let data: Data
    let sfntVersion: UInt32
    let tables: [TableRecord]

    init(data: Data) throws {
        self.data = data
        var r = BinaryReader(data)

        guard data.count >= 12 else { throw Failure.tooShort }

        let version = r.readUInt32()
        self.sfntVersion = version
        switch version {
        case 0x00010000, 0x4F54544F, 0x74727565, 0x74797031:
            break  // TrueType / OpenType / Apple TrueType / Type 1
        default:
            throw Failure.unrecognizedSfnt(version)
        }

        let numTables = Int(r.readUInt16())
        _ = r.readUInt16()  // searchRange
        _ = r.readUInt16()  // entrySelector
        _ = r.readUInt16()  // rangeShift

        var records: [TableRecord] = []
        records.reserveCapacity(numTables)
        for _ in 0..<numTables {
            let tag = r.readTag()
            let checksum = r.readUInt32()
            let offset = r.readUInt32()
            let length = r.readUInt32()
            records.append(TableRecord(tag: tag, checksum: checksum, offset: offset, length: length))
        }
        self.tables = records
    }

    func table(named tag: String) -> TableRecord? {
        tables.first { $0.tag == tag }
    }

    func tableData(named tag: String) -> Data? {
        guard let t = table(named: tag) else { return nil }
        let start = Int(t.offset)
        let end = start + Int(t.length)
        guard end <= data.count else { return nil }
        return data.subdata(in: start..<end)
    }

    enum Failure: LocalizedError {
        case tooShort
        case unrecognizedSfnt(UInt32)

        var errorDescription: String? {
            switch self {
            case .tooShort: return "File is too short to be a font"
            case .unrecognizedSfnt(let v): return String(format: "Unrecognized sfnt version: 0x%08X", v)
            }
        }
    }
}
