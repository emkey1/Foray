import Foundation

/// Finder tags (DESIGN.md §5.8). Reading costs ~17 µs per file (M0 S1d), so callers read lazily.
public enum Tags {
    static let attribute = "com.apple.metadata:_kMDItemUserTags"

    /// Tag names, without the "\n<color>" suffix the xattr stores.
    public static func names(at url: URL) -> [String] {
        let size = getxattr(url.path, attribute, nil, 0, 0, XATTR_NOFOLLOW)
        guard size > 0 else { return [] }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { getxattr(url.path, attribute, $0.baseAddress, size, 0, XATTR_NOFOLLOW) }
        guard read > 0, let list = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String] else { return [] }
        return list.map { $0.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? $0 }
    }
}
