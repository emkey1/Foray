// S7: do thumbnail requests download dataless (cloud placeholder) files?
// For each path: report SF_DATALESS, request a QLThumbnailGenerator thumbnail, report again.
// WARNING: if the answer is "yes", running this on a dataless file downloads it.
//
// usage: thumb-spike [--icon-only] <file> [file ...]
import AppKit
import QuickLookThumbnailing

let SF_DATALESS: UInt32 = 0x4000_0000

func isDataless(_ path: String) -> Bool? {
    var st = stat()
    guard lstat(path, &st) == 0 else { return nil }
    return st.st_flags & SF_DATALESS != 0
}

var args = Array(CommandLine.arguments.dropFirst())
let iconOnly = args.first == "--icon-only"
if iconOnly { args.removeFirst() }
let types: QLThumbnailGenerator.Request.RepresentationTypes = iconOnly ? [.icon] : [.thumbnail]

for path in args {
    let before = isDataless(path)
    let req = QLThumbnailGenerator.Request(fileAt: URL(fileURLWithPath: path), size: CGSize(width: 128, height: 128),
                                           scale: 2, representationTypes: types)
    let sem = DispatchSemaphore(value: 0)
    let t0 = Date()
    var outcome = ""
    QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { rep, error in
        outcome = rep.map { "type=\($0.type.rawValue)" } ?? "error: \(error?.localizedDescription ?? "?")"
        sem.signal()
    }
    _ = sem.wait(timeout: .now() + 30)
    let ms = Date().timeIntervalSince(t0) * 1000
    print(String(format: "%@\n  dataless before=%@ after=%@  %@  (%.0f ms)", path,
                 before.map { "\($0)" } ?? "?", isDataless(path).map { "\($0)" } ?? "?", outcome, ms))
}
