// S1: directory enumeration speed. FileManager (+prefetched keys) vs getattrlistbulk.
// Also times natural-order sorting (§5.13 budget: re-sort 100k < 300 ms).
//
// usage: enumbench <work-dir> [extra-dir-to-measure ...]
import CFastFS
import Foundation
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count >= 2 else {
    print("usage: enumbench <work-dir> [extra-dir ...]")
    exit(2)
}
let work = URL(fileURLWithPath: args[1], isDirectory: true)

func makeTree(_ count: Int) -> URL {
    let dir = work.appendingPathComponent("flat-\(count)", isDirectory: true)
    if FileManager.default.fileExists(atPath: dir.path) { return dir }
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let exts = ["txt", "jpg", "png", "pdf", "swift", "zip", "mov", "md", "json", ""]
    let payload = Data(repeating: 0x41, count: 64)
    for i in 0..<count {
        let ext = exts[i % exts.count]
        let name = "file \(i)" + (ext.isEmpty ? "" : ".\(ext)")
        if i % 50 == 0 {
            try! FileManager.default.createDirectory(at: dir.appendingPathComponent("folder \(i)"), withIntermediateDirectories: false)
        } else {
            FileManager.default.createFile(atPath: dir.appendingPathComponent(name).path, contents: payload)
        }
    }
    return dir
}

func time(_ label: String, runs: Int = 5, _ body: () -> Int) {
    var samples: [Double] = []
    var n = 0
    for _ in 0..<runs {
        let t0 = DispatchTime.now().uptimeNanoseconds
        n = body()
        samples.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
    }
    samples.sort()
    let median = samples[samples.count / 2]
    print(String(format: "  %-44@ %8.1f ms median  (min %.1f, n=%d)", label as NSString, median, samples[0], n))
}

let minimalKeys: [URLResourceKey] = [.nameKey, .isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
let fullKeys: [URLResourceKey] = [
    .nameKey, .localizedNameKey, .isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .isAliasFileKey,
    .isHiddenKey, .fileSizeKey, .totalFileAllocatedSizeKey, .contentModificationDateKey, .creationDateKey,
    .addedToDirectoryDateKey, .contentTypeKey, .fileResourceIdentifierKey, .hasHiddenExtensionKey, .tagNamesKey,
]

final class Sink { var count = 0; var types: [String: UTType] = [:]; var withType = false }

func bulk(_ dir: URL, withType: Bool) -> Int {
    let sink = Sink()
    sink.withType = withType
    let rc = rf_enumerate(dir.path, { entryPtr, ctx in
        let sink = Unmanaged<Sink>.fromOpaque(ctx!).takeUnretainedValue()
        let e = entryPtr!.pointee
        let name = String(cString: e.name)
        if sink.withType {
            // Production equivalent of .contentTypeKey: extension -> UTType, memoized.
            let ext = (name as NSString).pathExtension.lowercased()
            if sink.types[ext] == nil {
                sink.types[ext] = e.objtype == 2 /* VDIR */ ? .folder : (UTType(filenameExtension: ext) ?? .data)
            }
        }
        sink.count += 1
    }, Unmanaged.passUnretained(sink).toOpaque())
    precondition(rc == 0, "rf_enumerate failed: \(String(cString: strerror(rc)))")
    return sink.count
}

func fm(_ dir: URL, keys: [URLResourceKey]) -> Int {
    let urls = try! FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: [])
    var n = 0
    for u in urls {
        // Touch the values so lazily-computed keys are actually paid for.
        let v = try? u.resourceValues(forKeys: Set(keys))
        if v?.name != nil { n += 1 }
    }
    return n
}

print("S1 — enumeration (\(ProcessInfo.processInfo.hostName))")
var dirs = [1_000, 10_000, 100_000].map(makeTree)
dirs += args.dropFirst(2).map { URL(fileURLWithPath: $0, isDirectory: true) }

for dir in dirs {
    print("\(dir.path):")
    time("getattrlistbulk (names+attrs)") { bulk(dir, withType: false) }
    time("getattrlistbulk + UTType (memoized by ext)") { bulk(dir, withType: true) }
    time("FileManager, minimal keys") { fm(dir, keys: minimalKeys) }
    time("FileManager, full FileItem keys") { fm(dir, keys: fullKeys) }
}

print("\nNatural-order sort (localizedStandardCompare):")
for count in [10_000, 100_000] {
    var names: [String] = []
    names.reserveCapacity(count)
    for i in 0..<count { names.append("File \(Int.random(in: 0..<count)) copy \(i % 7).txt") }
    time("sort \(count) names", runs: 3) {
        let sorted = names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return sorted.count
    }
    // Alternative: precomputed keys. Fold case/diacritics once; digits still need natural handling.
    time("sort \(count) names, folded keys + numeric compare", runs: 3) {
        let keyed = names.map { ($0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil), $0) }
        let sorted = keyed.sorted { $0.0.compare($1.0, options: [.numeric, .literal]) == .orderedAscending }
        return sorted.count
    }
}
