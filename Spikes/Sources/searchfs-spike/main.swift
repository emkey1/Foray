// S2: does searchfs(2) work on APFS, how fast is it, and what paths does it report (firmlinks)?
//
// usage: searchfs-spike <needle> [volume-mount-point ...]
import CFastFS
import Foundation

let args = CommandLine.arguments
guard args.count >= 2 else {
    print("usage: searchfs-spike <needle> [volume ...]")
    exit(2)
}
let needle = args[1]
var volumes = Array(args.dropFirst(2))
if volumes.isEmpty {
    volumes = (FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: []) ?? []).map(\.path)
}

final class Collector { var paths: [String] = [] }

for vol in volumes {
    let supported = rf_volume_supports_searchfs(vol)
    var fs = statfs()
    statfs(vol, &fs)
    let fsType = withUnsafeBytes(of: fs.f_fstypename) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
    print("\(vol) [\(fsType)] VOL_CAP_INT_SEARCHFS=\(supported)")
    guard supported == 1 else { continue }

    let c = Collector()
    var matches: UInt64 = 0
    let t0 = DispatchTime.now().uptimeNanoseconds
    let rc = rf_searchfs(vol, needle, { p, ctx in
        Unmanaged<Collector>.fromOpaque(ctx!).takeUnretainedValue().paths.append(String(cString: p!))
    }, Unmanaged.passUnretained(c).toOpaque(), &matches)
    let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
    let err = rc == 0 ? "ok" : String(cString: strerror(rc))
    print(String(format: "  searchfs(\"%@\"): %@, %llu matches, %d paths resolved, %.0f ms", needle, err, matches, c.paths.count, ms))
    for p in c.paths.prefix(5) { print("    \(p)") }
}
