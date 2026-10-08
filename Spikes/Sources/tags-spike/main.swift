// S5: tags. Round-trips tags on a scratch file through the public API and the raw xattr,
// and reports where Finder's tag catalog lives. Uses only the standard color tags, so the
// user's tag catalog isn't changed.
//
// usage: tags-spike <scratch-dir>
import Foundation

let dir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : NSTemporaryDirectory())
let file = dir.appendingPathComponent("rf-tags-spike.txt")
FileManager.default.createFile(atPath: file.path, contents: Data("tags".utf8))
defer { try? FileManager.default.removeItem(at: file) }

let xattrName = "com.apple.metadata:_kMDItemUserTags"

func rawTags(_ url: URL) -> [String] {
    let size = getxattr(url.path, xattrName, nil, 0, 0, 0)
    guard size > 0 else { return [] }
    var data = Data(count: size)
    _ = data.withUnsafeMutableBytes { getxattr(url.path, xattrName, $0.baseAddress, size, 0, 0) }
    let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
    return plist as? [String] ?? []
}

func apiTags(_ url: URL) -> [String] {
    var u = url
    u.removeAllCachedResourceValues()
    return (try? u.resourceValues(forKeys: [.tagNamesKey]).tagNames) ?? []
}

// 1. Write through the public API.
try (file as NSURL).setResourceValue(["Red", "Blue"], forKey: .tagNamesKey)
print("1. set via API [Red, Blue]")
print("   API reads:  \(apiTags(file))")
print("   xattr has:  \(rawTags(file).map { $0.replacingOccurrences(of: "\n", with: "\\n") })")

// 2. Write the raw xattr with explicit color indices (what we'd do to set a color for a tag
//    the system doesn't know). "Green" with a deliberately wrong color index (1 = gray).
let entries = ["Green\n1", "Red\n6"]
let data = try PropertyListSerialization.data(fromPropertyList: entries, format: .binary, options: 0)
_ = data.withUnsafeBytes { setxattr(file.path, xattrName, $0.baseAddress, data.count, 0, 0) }
print("2. set raw xattr \(entries.map { $0.replacingOccurrences(of: "\n", with: "\\n") })")
print("   API reads:  \(apiTags(file))")
print("   labelNumber: \((try? file.resourceValues(forKeys: [.labelNumberKey]).labelNumber).map(String.init) ?? "nil")")

// 3. Where does the catalog live?
let finder = UserDefaults(suiteName: "com.apple.finder")
print("3. com.apple.finder FavoriteTagNames = \(finder?.array(forKey: "FavoriteTagNames") ?? [])")
print("   com.apple.finder TagsCloudSerialNumber = \(finder?.object(forKey: "TagsCloudSerialNumber") ?? "nil")")
