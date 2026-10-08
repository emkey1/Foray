import Foundation
import Testing

@testable import RFModel
@testable import RFSearch

struct SavedSearchTests {
    let dir: URL = {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("rf-saved-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    @Test func ourSearchesRoundTripAndCarryARawQueryForFinder() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let folder = URL(fileURLWithPath: "/Users/someone/Projects", isDirectory: true)
        let q = SearchQuery(text: "report kind:pdf size:>1MB", scope: .folder(folder, recursive: true), match: .namesAndContents)
        let url = dir.appendingPathComponent("Reports.savedSearch")
        try SavedSearch.write(q, to: url)

        let back = try #require(SavedSearch.read(url))
        #expect(back.text == q.text && back.match == .namesAndContents && back.scope.folderURL?.path == folder.path)
        #expect(back.rawSpotlight == nil)   // reopens as an editable search

        let plist = try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
        let raw = try #require(plist["RawQuery"] as? String)
        #expect(raw.contains("kMDItemFSName") && raw.contains("kMDItemFSSize"))
        #expect(((plist["RawQueryDict"] as? [String: Any])?["SearchScopes"] as? [String]) == [folder.path])
    }

    @Test func readsFinderSmartFolders() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let plist: [String: Any] = [
            "CompatibleVersion": 1,
            "RawQuery": "(kMDItemContentTypeTree = \"public.image\"cd) && (kMDItemFSSize > 1000000)",
            "RawQueryDict": ["RawQuery": "(kMDItemContentTypeTree = \"public.image\"cd)", "SearchScopes": ["kMDQueryScopeHome"]] as [String: Any],
            "SearchCriteria": ["FXScopeArrayOfPaths": ["kMDQueryScopeHome"]] as [String: Any],
        ]
        let url = dir.appendingPathComponent("Big Images.savedSearch")
        try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0).write(to: url)
        let q = try #require(SavedSearch.read(url))
        #expect(q.text == "Big Images")
        #expect(q.rawSpotlight?.contains("public.image") == true)
        #expect(q.scope.folderURL == FileManager.default.homeDirectoryForCurrentUser)
        #expect(!q.isEmpty)
        #expect(Location.search(q).fallbackTitle == "Big Images")
        // Saving it again keeps Finder's query.
        let copy = dir.appendingPathComponent("copy.savedSearch")
        try SavedSearch.write(q, to: copy)
        #expect(SavedSearch.read(copy)?.rawSpotlight == q.rawSpotlight)
        #expect(SavedSearch.read(dir.appendingPathComponent("missing.savedSearch")) == nil)
    }

    @Test func regexSearchesCantBeSaved() {
        defer { try? FileManager.default.removeItem(at: dir) }
        let q = SearchQuery(text: "/^IMG_\\d+$/", scope: .thisMac)
        #expect(throws: SavedSearch.SaveError.self) { try SavedSearch.write(q, to: dir.appendingPathComponent("r.savedSearch")) }
    }

    @Test func olderSavedQueriesStillDecode() throws {
        let json = #"{"text":"x","scope":{"thisMac":{}},"match":"names"}"#
        let q = try JSONDecoder().decode(SearchQuery.self, from: Data(json.utf8))
        #expect(q.text == "x" && q.rawSpotlight == nil)
    }

    /// Opt-in: RF_SPOTLIGHT_TESTS=1 (reads the Spotlight index).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["RF_SPOTLIGHT_TESTS"] != nil))
    func runsARawQuery() async {
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let q = SearchQuery(text: "Design", scope: .folder(project, recursive: true), rawSpotlight: "kMDItemFSName == \"DESIGN.md\"")
        var names: [String] = []
        for await s in SearchEngine.run(q) {
            names = s.items.map(\.name)
            if !s.spotlightRunning { break }
        }
        #expect(names == ["DESIGN.md"])
    }
}
