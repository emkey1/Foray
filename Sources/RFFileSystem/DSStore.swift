import Foundation

/// Read-only parser for Finder's `.DS_Store` files (a B-tree inside a buddy allocator).
/// A private format: isolated here, used only for Put Back records, never written (DESIGN.md S10).
public enum DSStore {
    public enum Value: Hashable, Sendable {
        case bool(Bool)
        case long(UInt32)
        case type(String)
        case blob(Data)
        case ustr(String)
        case date(UInt64)
    }

    public struct Record: Hashable, Sendable {
        /// The file the record describes (a name in the store's folder).
        public let name: String
        /// Four-character code, e.g. `ptbL`.
        public let code: String
        public let value: Value
    }

    public struct Malformed: Error {}

    public static func records(at url: URL) -> [Record] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? records(in: data)) ?? []
    }

    public static func records(in data: Data) throws -> [Record] {
        var r = Reader(data: data)
        guard try r.u32(at: 0) == 1, try r.fourCC(at: 4) == "Bud1" else { throw Malformed() }
        let infoOffset = Int(try r.u32(at: 8))
        // The allocator's info block: block addresses, then a table of contents naming the B-tree.
        r.pos = infoOffset + 4
        let blockCount = Int(try r.u32())
        _ = try r.u32()
        var addresses: [UInt32] = []
        for _ in 0..<blockCount { addresses.append(try r.u32()) }
        r.pos += ((256 - blockCount % 256) % 256) * 4   // padded to multiples of 256 entries
        let tocCount = Int(try r.u32())
        var dsdb: Int?
        for _ in 0..<tocCount {
            let len = Int(try r.u8())
            let name = String(decoding: try r.bytes(len), as: UTF8.self)
            let id = Int(try r.u32())
            if name == "DSDB" { dsdb = id }
        }
        guard let dsdb else { throw Malformed() }

        func blockOffset(_ id: Int) throws -> Int {
            guard id < addresses.count else { throw Malformed() }
            return Int(addresses[id] & ~0x1f) + 4
        }
        r.pos = try blockOffset(dsdb)
        let root = Int(try r.u32())

        var out: [Record] = []
        var visited = Set<Int>()
        func walk(_ node: Int) throws {
            guard visited.insert(node).inserted, visited.count < 100_000 else { throw Malformed() }
            r.pos = try blockOffset(node)
            let rightmost = Int(try r.u32())
            let count = Int(try r.u32())
            if rightmost == 0 {
                for _ in 0..<count { out.append(try r.record()) }
            } else {
                for _ in 0..<count {
                    let child = Int(try r.u32())
                    let saved = r.pos
                    try walk(child)
                    r.pos = saved
                    out.append(try r.record())
                }
                try walk(rightmost)
            }
        }
        try walk(root)
        return out
    }

    private struct Reader {
        let data: Data
        var pos = 0

        func u32(at offset: Int) throws -> UInt32 {
            guard offset >= 0, offset + 4 <= data.count else { throw Malformed() }
            let b = data.startIndex + offset
            return UInt32(data[b]) << 24 | UInt32(data[b + 1]) << 16 | UInt32(data[b + 2]) << 8 | UInt32(data[b + 3])
        }

        func fourCC(at offset: Int) throws -> String {
            guard offset >= 0, offset + 4 <= data.count else { throw Malformed() }
            return String(decoding: data[(data.startIndex + offset)..<(data.startIndex + offset + 4)], as: UTF8.self)
        }

        mutating func u32() throws -> UInt32 {
            defer { pos += 4 }
            return try u32(at: pos)
        }

        mutating func u8() throws -> UInt8 {
            guard pos >= 0, pos < data.count else { throw Malformed() }
            defer { pos += 1 }
            return data[data.startIndex + pos]
        }

        mutating func bytes(_ n: Int) throws -> Data {
            guard n >= 0, pos >= 0, pos + n <= data.count else { throw Malformed() }
            defer { pos += n }
            return data[(data.startIndex + pos)..<(data.startIndex + pos + n)]
        }

        mutating func utf16(_ units: Int) throws -> String {
            let raw = try bytes(units * 2)
            var scalars: [UInt16] = []
            scalars.reserveCapacity(units)
            var i = raw.startIndex
            while i < raw.endIndex {
                scalars.append(UInt16(raw[i]) << 8 | UInt16(raw[i + 1]))
                i += 2
            }
            return String(decoding: scalars, as: UTF16.self)
        }

        mutating func record() throws -> Record {
            let name = try utf16(Int(try u32()))
            let code = String(decoding: try bytes(4), as: UTF8.self)
            let type = String(decoding: try bytes(4), as: UTF8.self)
            let value: Value
            switch type {
            case "bool": value = .bool(try u8() != 0)
            case "long", "shor": value = .long(try u32())
            case "type": value = .type(String(decoding: try bytes(4), as: UTF8.self))
            case "comp", "dutc": value = .date(UInt64(try u32()) << 32 | UInt64(try u32()))
            case "blob": value = .blob(try bytes(Int(try u32())))
            case "ustr": value = .ustr(try utf16(Int(try u32())))
            default: throw Malformed()
            }
            return Record(name: name, code: code, value: value)
        }
    }
}
