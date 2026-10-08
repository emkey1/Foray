import Foundation

/// Precomputed sort key that reproduces Finder's name order (`localizedStandardCompare`) with byte
/// comparisons. `localizedStandardCompare` costs ~840 ms per 100k names and serializes internally;
/// this key sorts 100k names in ~250 ms including key construction (M0 spike S1b/c, DESIGN.md §5.13).
///
/// Layout, after folding case, diacritics and width:
/// - ASCII controls 0x01, ASCII whitespace/punctuation 0x02–0x23 in ICU root-collation order,
/// - digit runs 0x40 + length + digits (leading zeros dropped), so byte order is numeric order,
/// - ASCII letters 0x60–0x79.
/// Names that still contain non-ASCII characters after folding (non-Latin scripts, ø, •, ©, –,
/// emoji) aren't `exact`: ICU's ordering of those can't be reproduced by scalar values, so they
/// compare with `localizedStandardCompare`. Equal keys (names differing only in case, accents or
/// leading zeros) also fall back to it, which supplies Finder's tie-breaks.
public struct NaturalSortKey: Hashable, Sendable, Comparable {
    public let bytes: [UInt8]
    public let exact: Bool
    public let original: String

    public init(_ name: String) {
        original = name
        let folded = name.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        var key: [UInt8] = []
        key.reserveCapacity(folded.utf8.count + 8)
        var exact = true
        var digits: [UInt8] = []

        func flushDigits() {
            guard !digits.isEmpty else { return }
            let trimmed = digits.drop(while: { $0 == 0x30 })
            key.append(0x40)
            key.append(UInt8(min(trimmed.count, 255)))
            key.append(contentsOf: trimmed)
            digits.removeAll(keepingCapacity: true)
        }

        for scalar in folded.unicodeScalars {
            let v = scalar.value
            if v < 0x80 {
                if v >= 0x30 && v <= 0x39 {
                    digits.append(UInt8(v))
                    continue
                }
                flushDigits()
                key.append(Self.asciiWeight[Int(v)])
            } else {
                flushDigits()
                exact = false
                key.append(0x7F)
                key.append(UInt8((v >> 16) & 0xFF))
                key.append(UInt8((v >> 8) & 0xFF))
                key.append(UInt8(v & 0xFF))
            }
        }
        flushDigits()
        self.bytes = key
        self.exact = exact
    }

    public static func < (a: NaturalSortKey, b: NaturalSortKey) -> Bool { a.compare(b) < 0 }

    /// Three-way comparison: negative, zero or positive. One memcmp for exact keys.
    public func compare(_ other: NaturalSortKey) -> Int {
        if exact && other.exact {
            let c = Self.compareBytes(bytes, other.bytes)
            if c != 0 { return c }
        }
        switch original.localizedStandardCompare(other.original) {
        case .orderedAscending: return -1
        case .orderedDescending: return 1
        case .orderedSame: return 0
        }
    }

    private static func compareBytes(_ a: [UInt8], _ b: [UInt8]) -> Int {
        a.withUnsafeBufferPointer { pa in
            b.withUnsafeBufferPointer { pb in
                let n = min(pa.count, pb.count)
                if n > 0, let x = pa.baseAddress, let y = pb.baseAddress {
                    let r = memcmp(x, y, n)
                    if r != 0 { return Int(r) }
                }
                return pa.count - pb.count
            }
        }
    }

    /// ICU root collation order for ASCII whitespace and punctuation (all 32 printable ASCII
    /// punctuation characters plus space and tab).
    private static let punctuationOrder = Array(" \t_-,;:!?.'\"()[]{}@*/\\&#%`^+<=>|~$".utf8)

    private static let asciiWeight: [UInt8] = {
        var w = [UInt8](repeating: 0x01, count: 128)
        for (i, b) in punctuationOrder.enumerated() { w[Int(b)] = UInt8(0x02 + i) }
        for b in UInt8(ascii: "a")...UInt8(ascii: "z") { w[Int(b)] = 0x60 + (b - UInt8(ascii: "a")) }
        // Folding lowercases, but keep uppercase mapped too in case folding is skipped for some input.
        for b in UInt8(ascii: "A")...UInt8(ascii: "Z") { w[Int(b)] = 0x60 + (b - UInt8(ascii: "A")) }
        return w
    }()
}
