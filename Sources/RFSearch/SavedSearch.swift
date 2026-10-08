import Foundation
import RFModel

/// Smart folders: Finder's `.savedSearch` files (a property list around a Spotlight query).
/// Foray opens Finder's, and saves its own searches in the same format so Finder can open
/// them too, adding its search text so they reopen as editable searches (DESIGN.md §4.6).
public enum SavedSearch {
    public static let fileExtension = "savedSearch"
    public static var defaultFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Saved Searches", isDirectory: true)
    }

    public enum SaveError: Error, LocalizedError {
        case notExpressible
        public var errorDescription: String? {
            "Searches that use regular expressions can't be saved as smart folders: Spotlight can't run them."
        }
    }

    public static func read(_ url: URL) -> SearchQuery? {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        let name = url.deletingPathExtension().lastPathComponent
        // Ours: the original search, editable.
        // (Smart folders saved while the app was called RealFinder use the old key.)
        if let mine = (plist["ForaySearch"] ?? plist["RealFinderSearch"]) as? [String: Any], let text = mine["Text"] as? String {
            let scope: SearchScope = (mine["Folder"] as? String).map { .folder(URL(fileURLWithPath: $0, isDirectory: true), recursive: true) } ?? .thisMac
            let match = (mine["Match"] as? String).flatMap(MatchMode.init) ?? .names
            return SearchQuery(text: text, scope: scope, match: match)
        }
        let dict = plist["RawQueryDict"] as? [String: Any]
        guard let raw = (plist["RawQuery"] as? String) ?? (dict?["RawQuery"] as? String), !raw.isEmpty else { return nil }
        return SearchQuery(text: name, scope: scope(from: dict?["SearchScopes"] as? [Any] ?? []), rawSpotlight: raw)
    }

    static func scope(from scopes: [Any]) -> SearchScope {
        for s in scopes {
            guard let s = s as? String else { continue }
            if s == "kMDQueryScopeHome" { return .folder(FileManager.default.homeDirectoryForCurrentUser, recursive: true) }
            if s.hasPrefix("/") { return .folder(URL(fileURLWithPath: s, isDirectory: true), recursive: true) }
        }
        return .thisMac
    }

    public static func write(_ query: SearchQuery, to url: URL) throws {
        let raw: String
        if let r = query.rawSpotlight {
            raw = r
        } else if let r = SpotlightQuery.string(for: query) {
            raw = r
        } else {
            throw SaveError.notExpressible
        }
        let scopes: [String] = query.scope.folderURL.map { [$0.path] } ?? ["kMDQueryScopeComputer"]
        var plist: [String: Any] = [
            "CompatibleVersion": 1,
            "RawQuery": raw,
            "RawQueryDict": ["RawQuery": raw, "SearchScopes": scopes, "FinderFilesOnly": true, "UserFilesOnly": true] as [String: Any],
        ]
        if query.rawSpotlight == nil {
            var mine: [String: Any] = ["Text": query.text, "Match": query.match.rawValue]
            if let folder = query.scope.folderURL { mine["Folder"] = folder.path }
            plist["ForaySearch"] = mine
        }
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: url, options: .atomic)
    }
}
