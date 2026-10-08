import Foundation

/// Finder aliases and symbolic links (DESIGN.md §4.4).
public enum Aliases {
    public enum Resolution: Equatable, Sendable {
        case target(URL)
        /// The original can't be found.
        case broken
        /// Not an alias or symlink.
        case notAnAlias
    }

    public static func resolve(_ url: URL) -> Resolution {
        let v = try? url.resourceValues(forKeys: [.isAliasFileKey, .isSymbolicLinkKey])
        if v?.isSymbolicLink == true {
            let target = url.resolvingSymlinksInPath()
            return FileManager.default.fileExists(atPath: target.path) ? .target(target) : .broken
        }
        guard v?.isAliasFile == true else { return .notAnAlias }
        guard let target = try? URL(resolvingAliasFileAt: url, options: [.withoutUI]),
              FileManager.default.fileExists(atPath: target.path) else { return .broken }
        return .target(target)
    }

    /// Writes an alias file at `alias` pointing to `original` (what Finder's Make Alias creates).
    public static func make(to original: URL, at alias: URL) throws {
        let data = try original.bookmarkData(options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil)
        try URL.writeBookmarkData(data, to: alias)
    }

    /// Finder's name: "report.pdf alias", then "report.pdf alias 2".
    public static func name(for original: String, isTaken: (String) -> Bool) -> String {
        let first = "\(original) alias"
        if !isTaken(first) { return first }
        var n = 2
        while isTaken("\(first) \(n)") { n += 1 }
        return "\(first) \(n)"
    }
}
