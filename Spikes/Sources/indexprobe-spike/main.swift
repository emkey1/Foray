// S3: how do we tell whether a folder is covered by the Spotlight index?
// Probe A: `mdutil -s <volume>` (volume-level only).
// Probe B: a synchronous MDQuery for the folder's own name, scoped to its parent. If Spotlight
//          returns the folder itself, its location is indexed.
// Probe C: freshness: create a uniquely named file inside the folder and time how long until
//          Spotlight returns it (index lag).
//
// usage: indexprobe-spike <folder> [folder ...]
import CoreServices
import Foundation

func mdutilStatus(_ path: String) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/mdutil")
    p.arguments = ["-s", path]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    try? p.run()
    p.waitUntilExit()
    let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    return out.split(separator: "\n").dropFirst().joined(separator: " ").trimmingCharacters(in: .whitespaces)
}

func spotlightFinds(name: String, in scope: URL, expecting path: String) -> (Bool, Double) {
    let escaped = name.replacingOccurrences(of: "\"", with: "\\\"")
    let q = MDQueryCreate(kCFAllocatorDefault, "kMDItemFSName == \"\(escaped)\"" as CFString, nil, nil)!
    MDQuerySetSearchScope(q, [scope.path] as CFArray, 0)
    let t0 = DispatchTime.now().uptimeNanoseconds
    MDQueryExecute(q, CFOptionFlags(kMDQuerySynchronous.rawValue))
    let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
    var found = false
    for i in 0..<MDQueryGetResultCount(q) {
        let item = Unmanaged<MDItem>.fromOpaque(MDQueryGetResultAtIndex(q, i)!).takeUnretainedValue()
        if let p = MDItemCopyAttribute(item, kMDItemPath) as? String, p == path { found = true }
    }
    return (found, ms)
}

for arg in CommandLine.arguments.dropFirst() {
    let folder = URL(fileURLWithPath: arg).standardizedFileURL.resolvingSymlinksInPath()
    var sfs = statfs()
    statfs(folder.path, &sfs)
    let mount = withUnsafeBytes(of: sfs.f_mntonname) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
    print("\(folder.path)")
    print("  A mdutil(\(mount)): \(mdutilStatus(mount))")

    let (found, ms) = spotlightFinds(name: folder.lastPathComponent, in: folder.deletingLastPathComponent(), expecting: folder.path)
    print(String(format: "  B folder visible to Spotlight: %@ (%.0f ms)", found ? "yes" : "no", ms))

    // Probe D: does Spotlight return *anything* inside the folder? (cheap: max 1 result)
    let any = MDQueryCreate(kCFAllocatorDefault, "kMDItemFSName == \"*\"" as CFString, nil, nil)!
    MDQuerySetSearchScope(any, [folder.path] as CFArray, 0)
    MDQuerySetMaxCount(any, 1)
    let d0 = DispatchTime.now().uptimeNanoseconds
    MDQueryExecute(any, CFOptionFlags(kMDQuerySynchronous.rawValue))
    let hasChildren = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path).count) ?? 0) > 0
    print(String(format: "  D any indexed item inside: %@ (%.0f ms; folder non-empty: %@)",
                 MDQueryGetResultCount(any) > 0 ? "yes" : "no",
                 Double(DispatchTime.now().uptimeNanoseconds - d0) / 1e6, hasChildren ? "yes" : "no"))

    let probeName = "rf-indexprobe-\(UUID().uuidString).txt"
    let probe = folder.appendingPathComponent(probeName)
    guard FileManager.default.createFile(atPath: probe.path, contents: Data("probe".utf8)) else {
        print("  C (can't write here; skipped)")
        continue
    }
    defer { try? FileManager.default.removeItem(at: probe) }
    let start = Date()
    var lag: Double?
    while Date().timeIntervalSince(start) < 15 {
        if spotlightFinds(name: probeName, in: folder, expecting: probe.path).0 {
            lag = Date().timeIntervalSince(start)
            break
        }
        Thread.sleep(forTimeInterval: 0.25)
    }
    print("  C new file indexed after: \(lag.map { String(format: "%.2f s", $0) } ?? "not within 15 s")")
}
