import Foundation

/// Big-endian binary reader for OpenType tables. Position-tracked so
/// table parsers can read sequential fields naturally.
struct BinaryReader {
    let data: Data
    private(set) var offset: Int

    init(_ data: Data, offset: Int = 0) {
        self.data = data
        self.offset = offset
    }

    var remaining: Int { data.count - offset }

    mutating func seek(_ pos: Int) {
        precondition(pos >= 0 && pos <= data.count, "Reader seek out of range")
        offset = pos
    }

    mutating func skip(_ n: Int) {
        precondition(offset + n <= data.count, "Reader skip past end")
        offset += n
    }

    mutating func readUInt8() -> UInt8 {
        let v = data[data.index(data.startIndex, offsetBy: offset)]
        offset += 1
        return v
    }

    mutating func readUInt16() -> UInt16 {
        let hi = UInt16(readUInt8())
        let lo = UInt16(readUInt8())
        return (hi << 8) | lo
    }

    mutating func readInt16() -> Int16 {
        Int16(bitPattern: readUInt16())
    }

    mutating func readUInt32() -> UInt32 {
        let b0 = UInt32(readUInt8())
        let b1 = UInt32(readUInt8())
        let b2 = UInt32(readUInt8())
        let b3 = UInt32(readUInt8())
        return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
    }

    mutating func readBytes(_ n: Int) -> Data {
        precondition(offset + n <= data.count, "Reader run off end")
        let slice = data.subdata(in: offset..<(offset + n))
        offset += n
        return slice
    }

    mutating func readTag() -> String {
        let bytes = readBytes(4)
        return String(data: bytes, encoding: .ascii) ?? "????"
    }
}

struct BinaryWriter {
    private(set) var data = Data()

    mutating func writeUInt8(_ v: UInt8) { data.append(v) }

    mutating func writeUInt16(_ v: UInt16) {
        data.append(UInt8((v >> 8) & 0xFF))
        data.append(UInt8(v & 0xFF))
    }

    mutating func writeUInt32(_ v: UInt32) {
        data.append(UInt8((v >> 24) & 0xFF))
        data.append(UInt8((v >> 16) & 0xFF))
        data.append(UInt8((v >> 8) & 0xFF))
        data.append(UInt8(v & 0xFF))
    }

    mutating func writeTag(_ s: String) {
        let padded = s.padding(toLength: 4, withPad: " ", startingAt: 0)
        data.append(contentsOf: padded.utf8.prefix(4))
    }

    mutating func writeBytes(_ d: Data) { data.append(d) }
}
