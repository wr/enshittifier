import Foundation

/// Read-only name-table inspector — exploratory scaffolding paralleling
/// `CmapTablePatcher`. Not used by the production path; the shipped
/// patcher is the bundled Python engine. The Swift alias-write side
/// (add nameID 1 + nameID 16 records on alternate English language IDs,
/// mirroring `add_family_aliases` in `engine/enshittifier.py`) isn't
/// implemented.
enum NameTablePatcher {
    struct NameRecord {
        let platformID: UInt16
        let encodingID: UInt16
        let languageID: UInt16
        let nameID: UInt16
        let value: String
    }

    static func read(in fileData: Data) throws -> [NameRecord] {
        let font = try OpenTypeFile(data: fileData)
        guard let name = font.tableData(named: "name") else {
            throw Failure.tableMissing
        }

        var r = BinaryReader(name)
        let format = r.readUInt16()
        let count = Int(r.readUInt16())
        let stringOffset = Int(r.readUInt16())

        var records: [NameRecord] = []
        for _ in 0..<count {
            let platformID = r.readUInt16()
            let encodingID = r.readUInt16()
            let languageID = r.readUInt16()
            let nameID = r.readUInt16()
            let length = Int(r.readUInt16())
            let offset = Int(r.readUInt16())

            let start = stringOffset + offset
            let end = start + length
            guard end <= name.count else { continue }
            let bytes = name.subdata(in: start..<end)

            let value: String
            if platformID == 3 || (platformID == 0) {
                // Windows / Unicode → UTF-16 big-endian
                value = String(data: bytes, encoding: .utf16BigEndian) ?? ""
            } else {
                value = String(data: bytes, encoding: .ascii) ?? ""
            }
            records.append(NameRecord(
                platformID: platformID,
                encodingID: encodingID,
                languageID: languageID,
                nameID: nameID,
                value: value
            ))
        }

        // Format 1 has language tag records after the name records; not
        // needed by the read-only path.
        _ = format

        return records
    }

    static func addSpacelessAlias(in data: Data) throws -> Data {
        _ = try read(in: data)
        throw Failure.notImplemented(
            "Swift name-table write path is not implemented; use PythonPatcher."
        )
    }

    enum Failure: LocalizedError {
        case tableMissing
        case notImplemented(String)

        var errorDescription: String? {
            switch self {
            case .tableMissing: return "Font has no 'name' table"
            case .notImplemented(let m): return m
            }
        }
    }
}
