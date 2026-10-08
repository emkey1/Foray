import Foundation
import RFModel

/// Finder tags (DESIGN.md §5.8). Reading costs ~17 µs per file (M0 S1d), so callers read lazily and
/// off the main thread. Writing goes through the public API, which also keeps the FinderInfo label
/// color in sync (writing the raw xattr doesn't; M0 S5).
public enum Tags {
    static let attribute = "com.apple.metadata:_kMDItemUserTags"

    /// Tags with their colors, in the order stored.
    public static func read(at url: URL) -> [Tag] {
        let size = getxattr(url.path, attribute, nil, 0, 0, XATTR_NOFOLLOW)
        guard size > 0 else { return [] }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { getxattr(url.path, attribute, $0.baseAddress, size, 0, XATTR_NOFOLLOW) }
        guard read > 0, let list = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String] else { return [] }
        return list.map { entry in
            let parts = entry.split(separator: "\n", maxSplits: 1)
            let name = parts.first.map(String.init) ?? entry
            let color = parts.count > 1 ? Int(parts[1]).flatMap(TagColor.init(rawValue:)) : nil
            return Tag(name, color: color ?? Tag.defaultColor(for: name))
        }
    }

    /// Tag names only.
    public static func names(at url: URL) -> [String] { read(at: url).map(\.name) }

    /// Replaces an item's tags. Returns 0 or an errno-like code.
    public static func write(_ names: [String], to url: URL) -> Int32 {
        do {
            try (url as NSURL).setResourceValue(names, forKey: .tagNamesKey)
            return 0
        } catch {
            let ns = error as NSError
            if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError, underlying.domain == NSPOSIXErrorDomain {
                return Int32(underlying.code)
            }
            return ns.code == NSFileWriteNoPermissionError ? EACCES : EIO
        }
    }

    /// Finder's sidebar tags (its "favorite" tags), readable from Finder's preferences.
    public static func finderFavorites() -> [Tag] {
        let names = (UserDefaults(suiteName: "com.apple.finder")?.array(forKey: "FavoriteTagNames") as? [String]) ?? []
        let favorites = names.filter { !$0.isEmpty }.map { Tag($0, color: Tag.defaultColor(for: $0)) }
        return favorites.isEmpty ? Tag.standard : favorites
    }
}
