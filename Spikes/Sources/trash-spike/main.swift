// S4: does FileManager.trashItem record "Put Back" information, and where?
// Trashes one scratch file it creates, then inspects the trashed copy's xattrs and the Trash's
// .DS_Store (Finder keeps put-back records there as "ptbL"/"ptbN" entries).
// Reading ~/.Trash requires Full Disk Access for the process running this tool.
// Cleans up by deleting only the file it trashed.
//
// usage: trash-spike <scratch-dir>
import Foundation

let dir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : NSTemporaryDirectory())
let name = "rf-putback-spike-\(UUID().uuidString.prefix(8)).txt"
let file = dir.appendingPathComponent(name)

let trashDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
let dsStore = trashDir.appendingPathComponent(".DS_Store")

func mtime(_ url: URL) -> Date? { try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date }
func xattrs(_ url: URL) -> [String] {
    let size = listxattr(url.path, nil, 0, XATTR_NOFOLLOW)
    guard size > 0 else { return [] }
    var buf = [CChar](repeating: 0, count: size)
    listxattr(url.path, &buf, size, XATTR_NOFOLLOW)
    return buf.withUnsafeBufferPointer { p in
        String(decoding: p.map { UInt8(bitPattern: $0) }, as: UTF8.self).split(separator: "\0").map(String.init)
    }
}

do {
    _ = try FileManager.default.contentsOfDirectory(atPath: trashDir.path)
    print("~/.Trash readable: yes")
} catch {
    print("~/.Trash readable: NO (\(error.localizedDescription)) — grant Full Disk Access to the terminal running this and rerun")
    exit(1)
}

FileManager.default.createFile(atPath: file.path, contents: Data("put back test".utf8))
let dsBefore = mtime(dsStore)
var resulting: NSURL?
try FileManager.default.trashItem(at: file, resultingItemURL: &resulting)
guard let trashed = resulting as URL? else { print("no resulting URL"); exit(1) }
Thread.sleep(forTimeInterval: 1)
print("trashed to: \(trashed.path)")
print("xattrs on trashed item: \(xattrs(trashed))")
print(".DS_Store mtime before: \(dsBefore.map { "\($0)" } ?? "none")  after: \(mtime(dsStore).map { "\($0)" } ?? "none")")

if let ds = try? Data(contentsOf: dsStore) {
    // DS_Store record names are UTF-16BE; look for our filename followed by a ptbL/ptbN code.
    let needle = name.data(using: .utf16BigEndian)!
    if let r = ds.range(of: needle) {
        let after = ds[r.upperBound..<min(ds.endIndex, r.upperBound + 4)]
        print("filename found in .DS_Store, followed by record code '\(String(decoding: after, as: UTF8.self))'")
    } else {
        print("filename NOT found in .DS_Store → trashItem did not record put-back info there")
    }
}

try? FileManager.default.removeItem(at: trashed)
print("cleaned up trashed test file")
