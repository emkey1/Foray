// §5.13 follow-up to S1: localizedStandardCompare sorts 100k names in ~840 ms (budget 300 ms).
// Candidates:
//   A. parallel chunk sort + k-way merge, same comparator (exact Finder order)
//   B. precomputed natural sort keys compared as bytes (approximate; measure disagreement with A)
import Foundation

func time<T>(_ label: String, runs: Int = 3, _ body: () -> T) -> T {
    var best = Double.infinity
    var out: T!
    for _ in 0..<runs {
        let t0 = DispatchTime.now().uptimeNanoseconds
        out = body()
        best = min(best, Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
    }
    print(String(format: "  %-52@ %7.1f ms", label as NSString, best))
    return out
}

let finderOrder: @Sendable (String, String) -> Bool = { $0.localizedStandardCompare($1) == .orderedAscending }

func parallelSort(_ a: [String], chunks: Int, by less: @escaping @Sendable (String, String) -> Bool) -> [String] {
    let size = (a.count + chunks - 1) / chunks
    nonisolated(unsafe) var parts = [[String]](repeating: [], count: chunks)
    DispatchQueue.concurrentPerform(iterations: chunks) { i in
        let lo = i * size, hi = min(a.count, lo + size)
        if lo < hi { parts[i] = a[lo..<hi].sorted(by: less) }
    }
    // Pairwise merge rounds (also parallel).
    while parts.count > 1 {
        let pairs = parts.count / 2
        nonisolated(unsafe) var merged = [[String]](repeating: [], count: pairs + parts.count % 2)
        let current = parts
        DispatchQueue.concurrentPerform(iterations: pairs) { p in
            let x = current[2 * p], y = current[2 * p + 1]
            var out: [String] = []
            out.reserveCapacity(x.count + y.count)
            var i = 0, j = 0
            while i < x.count && j < y.count {
                if less(y[j], x[i]) { out.append(y[j]); j += 1 } else { out.append(x[i]); i += 1 }
            }
            out.append(contentsOf: x[i...]); out.append(contentsOf: y[j...])
            merged[p] = out
        }
        if parts.count % 2 == 1 { merged[pairs] = current.last! }
        parts = merged
    }
    return parts.first ?? []
}

/// ICU root-collation order for ASCII punctuation/symbols (whitespace first, then these, then
/// digits, then letters). Index in this string + 0x02 is the byte weight.
let punctuationOrder = Array(" \t_-,;:!?.'\"()[]{}@*/\\&#%`^+<=>|~$".utf8)
let asciiWeight: [UInt8] = {
    var w = [UInt8](repeating: 0, count: 128)
    for (i, b) in punctuationOrder.enumerated() { w[Int(b)] = UInt8(0x02 + i) }   // 0x02...0x2x
    for b in UInt8(ascii: "a")...UInt8(ascii: "z") { w[Int(b)] = 0x60 + (b - UInt8(ascii: "a")) }
    for b in 0..<128 where w[b] == 0 { w[b] = 0x50 }   // other controls: after punctuation
    return w
}()

/// Natural key: case/diacritic-folded text with ICU-like punctuation weights; each digit run is
/// encoded as (marker, length, digits) so byte order == numeric order. Non-ASCII bytes keep
/// their UTF-8 value (>= 0x80, i.e. after ASCII letters). Ties are broken by the real comparator.
func naturalKey(_ s: String) -> [UInt8] {
    let folded = s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    var key: [UInt8] = []
    key.reserveCapacity(folded.utf8.count + 8)
    var digits: [UInt8] = []
    func flush() {
        guard !digits.isEmpty else { return }
        let trimmed = digits.drop(while: { $0 == 0x30 })
        key.append(0x40)  // after punctuation, before letters
        key.append(UInt8(min(trimmed.count, 255)))
        key.append(contentsOf: trimmed)
        digits.removeAll(keepingCapacity: true)
    }
    for b in folded.utf8 {
        if b >= 0x30 && b <= 0x39 { digits.append(b) } else { flush(); key.append(b < 0x80 ? asciiWeight[Int(b)] : b) }
    }
    flush()
    return key
}

struct Keyed { let key: [UInt8]; let name: String }
func keyedLess(_ a: Keyed, _ b: Keyed) -> Bool {
    if a.key == b.key { return finderOrder(a.name, b.name) }   // rare: case/accent-only differences
    return a.key.lexicographicallyPrecedes(b.key)
}

let cores = ProcessInfo.processInfo.activeProcessorCount
print("sortbench (\(cores) cores)")
let words = ["Report", "report", "Résumé", "resume", "IMG_", "img ", "Screenshot 2026-10-0", "Invoice #", "file", "Ünïcode", "_draft", "(copy)", "Zeta", "alpha"]
for count in [10_000, 100_000] {
    var rng = SystemRandomNumberGenerator()
    let names = (0..<count).map { i in "\(words[Int.random(in: 0..<words.count, using: &rng)])\(Int.random(in: 0..<5000, using: &rng)) \(i % 3 == 0 ? "copy" : "v\(i % 11)").txt" }
    print("\(count) names:")
    let reference = time("serial localizedStandardCompare") { names.sorted(by: finderOrder) }
    let parallel = time("A. parallel (\(cores) chunks) localizedStandardCompare") { parallelSort(names, chunks: cores, by: finderOrder) }
    precondition(parallel == reference, "parallel sort must match exactly")
    let keyed = time("B. precomputed natural keys (incl. key build)") { () -> [String] in
        names.map { Keyed(key: naturalKey($0), name: $0) }.sorted(by: keyedLess).map(\.name)
    }
    // Disagreement: fraction of adjacent pairs in B's order that Finder's comparator would invert.
    let inversions = zip(keyed, keyed.dropFirst()).filter { finderOrder($1, $0) }.count
    print(String(format: "    B adjacent-pair disagreements with Finder order: %d (%.2f%%)", inversions, 100 * Double(inversions) / Double(count)))
}

if CommandLine.arguments.contains("--examples") {
    let sample = (0..<20_000).map { i in "\(words[i % words.count])\(i % 37) \(i % 3 == 0 ? "copy" : "v\(i % 11)").txt" }
    let keyed = sample.map { Keyed(key: naturalKey($0), name: $0) }.sorted(by: keyedLess).map(\.name)
    var seen = Set<String>()
    for (a, b) in zip(keyed, keyed.dropFirst()) where finderOrder(b, a) {
        let sig = "\(a.prefix(4))|\(b.prefix(4))"
        if seen.insert(sig).inserted { print("  keys say \"\(a)\" < \"\(b)\", Finder says opposite") }
        if seen.count > 12 { break }
    }
}

if let i = CommandLine.arguments.firstIndex(of: "--corpus"), i + 1 < CommandLine.arguments.count {
    let corpus = try! String(contentsOfFile: CommandLine.arguments[i + 1], encoding: .utf8)
        .split(separator: "\n").map(String.init)
    print("real corpus: \(corpus.count) names")
    let reference = time("serial localizedStandardCompare") { corpus.sorted(by: finderOrder) }
    let keyed = time("B. precomputed natural keys") { corpus.map { Keyed(key: naturalKey($0), name: $0) }.sorted(by: keyedLess).map(\.name) }
    let bad = zip(keyed, keyed.dropFirst()).filter { finderOrder($1, $0) }
    print("  disagreements: \(bad.count); identical order: \(keyed == reference)")
    for (a, b) in bad.prefix(15) { print("    keys: \"\(a)\" < \"\(b)\"") }
}
