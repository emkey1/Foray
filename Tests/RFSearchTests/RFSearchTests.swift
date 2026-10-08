import Foundation
import Synchronization
import Testing
import UniformTypeIdentifiers

@testable import RFFileSystem
@testable import RFModel
@testable import RFSearch

private let inode = Atomic<UInt64>(1)

private func item(_ name: String, size: Int64 = 100, modified: Date = Date(), hidden: Bool = false, dir: Bool = false) -> FileItem {
    let ext = (name as NSString).pathExtension
    return FileItem(
        id: FileID(device: 1, inode: inode.add(1, ordering: .relaxed).newValue), url: URL(fileURLWithPath: "/x/\(name)"),
        name: name, contentType: dir ? .folder : (UTType(filenameExtension: ext) ?? .data),
        flags: (dir ? ItemFlags.directory : []).union(hidden ? .hidden : []), size: dir ? nil : size, modified: modified)
}

private func matches(_ text: String, _ item: FileItem, mode: MatchMode = .names) -> Bool {
    QueryMatcher(SearchQuery(text: text, scope: .thisMac, match: mode)).matches(item)
}

@Suite struct QueryParserTests {
    @Test func tokenizesQuotes() {
        #expect(QueryParser.tokenize(#"report "tax 2025" tag:"Big Deal" x"#) == ["report", "\"tax 2025\"", "tag:\"Big Deal\"", "x"])
    }

    @Test func parsesTermsAndTokens() {
        let node = QueryParser.parse("invoice kind:images,pdf ext:.HEIC -draft")
        #expect(node == .all([
            .term(.name("invoice")), .term(.kind(["images", "pdfs"])), .term(.ext(["heic"])), .not(.term(.name("draft"))),
        ]))
    }

    @Test func orBindsTighterThanImplicitAnd() {
        #expect(QueryParser.parse("a OR b c") == .all([.any([.term(.name("a")), .term(.name("b"))]), .term(.name("c"))]))
        #expect(QueryParser.parse("a OR b OR c") == .all([.any([.term(.name("a")), .term(.name("b")), .term(.name("c"))])]))
    }

    @Test func sizes() {
        #expect(QueryParser.parseSize(">100MB") == .size(min: 100_000_001, max: nil))
        #expect(QueryParser.parseSize("<1KB") == .size(min: nil, max: 999))
        #expect(QueryParser.parseSize("1MB..5MB") == .size(min: 1_000_000, max: 5_000_000))
        #expect(QueryParser.parseSize("2.5g") == .size(min: 2_500_000_000, max: nil))
    }

    @Test func dates() throws {
        let cal = Calendar(identifier: .gregorian)
        let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 8, hour: 12))!
        guard case .date(.modified, let from?, nil) = QueryParser.parseDate(.modified, "<7d", now: now, calendar: cal) else {
            Issue.record("expected an open-ended range"); return
        }
        #expect(cal.dateComponents([.day], from: from, to: now).day == 7)
        guard case .date(.created, let a?, let b?) = QueryParser.parseDate(.created, "2025-10", now: now, calendar: cal) else {
            Issue.record("expected a month range"); return
        }
        #expect(cal.component(.month, from: a) == 10 && cal.component(.month, from: b) == 11)
        #expect(QueryParser.parseDate(.modified, "nonsense", now: now, calendar: cal) == nil)
    }

    @Test func unknownKeysAreNames() {
        #expect(QueryParser.parse("foo:bar") == .all([.term(.name("foo:bar"))]))
    }

    @Test func chipsRewriteKindTokens() {
        let q = SearchQuery(text: "report kind:images", scope: .thisMac)
        #expect(q.kinds == ["images"])
        let q2 = q.settingKinds(["documents", "pdfs"])
        #expect(q2.text == "report kind:documents,pdfs")
        #expect(q2.settingKinds([]).text == "report")
    }
}

@Suite struct QueryMatcherTests {
    @Test func namesAreCaseAndDiacriticInsensitiveSubstrings() {
        #expect(matches("resume", item("My Résumé 2025.pdf")))
        #expect(!matches("resume", item("report.pdf")))
        #expect(matches("my 2025", item("My Résumé 2025.pdf")))  // all terms must match
    }

    @Test func globsMatchWholeNames() {
        #expect(matches("*.png", item("shot.PNG")))
        #expect(!matches("*.png", item("shot.png.txt")))
        #expect(matches("IMG_????.jpg", item("img_0042.jpg")))
    }

    @Test func kindsSizesAndNegation() {
        #expect(matches("kind:images", item("a.heic")))
        #expect(!matches("kind:images", item("a.txt")))
        #expect(matches("size:>1KB", item("big.bin", size: 5_000)))
        #expect(!matches("size:>1KB", item("dir", dir: true)))
        #expect(matches("-draft report", item("report final.txt")))
        #expect(!matches("-draft report", item("report draft.txt")))
        #expect(matches("x OR y", item("y.txt")))
    }

    @Test func regex() {
        #expect(matches(#"/^v\d+\.\d+$/"#, item("v1.10")))
        #expect(!matches(#"/^v\d+$/"#, item("version")))
    }

    @Test func contentTermsNeedSpotlight() {
        #expect(!QueryMatcher(SearchQuery(text: "content:invoice", scope: .thisMac)).matches(item("a.pdf")))
        #expect(QueryMatcher(SearchQuery(text: "content:invoice", scope: .thisMac)).matches(item("a.pdf"), contentMatches: true))
        // Names & Contents: a Spotlight hit may have matched on contents rather than the name.
        #expect(QueryMatcher(SearchQuery(text: "invoice", scope: .thisMac, match: .namesAndContents))
            .matches(item("scan.pdf"), contentMatches: true))
    }
}

@Suite struct SpotlightQueryTests {
    @Test func translatesTerms() throws {
        let s = try #require(SpotlightQuery.string(for: SearchQuery(text: "report -draft ext:pdf size:>1MB", scope: .thisMac)))
        #expect(s.contains(#"kMDItemFSName == "*report*"cd"#))
        #expect(s.contains(#"!(kMDItemFSName == "*draft*"cd)"#))
        #expect(s.contains(#"kMDItemFSName == "*.pdf"c"#))
        #expect(s.contains("kMDItemFSSize >= 1000001"))
        #expect(NSPredicate(fromMetadataQueryString: s) != nil)
    }

    @Test func kindsBecomeContentTypeTree() throws {
        let s = try #require(SpotlightQuery.string(for: SearchQuery(text: "kind:code", scope: .thisMac)))
        #expect(s.contains(#"kMDItemContentTypeTree == "public.source-code""#))
        #expect(s.contains(#"kMDItemContentTypeTree != "public.image""#))
        #expect(NSPredicate(fromMetadataQueryString: s) != nil)
    }

    @Test func everyBuiltInKindIsValidSpotlight() throws {
        for c in KindCategory.builtIns {
            let s = try #require(SpotlightQuery.string(for: SearchQuery(text: "kind:\(c.id)", scope: .thisMac)))
            #expect(NSPredicate(fromMetadataQueryString: s) != nil, "\(c.id): \(s)")
        }
    }

    @Test func escapesQuotes() throws {
        let s = try #require(SpotlightQuery.string(for: SearchQuery(text: #"say\"hi"#, scope: .thisMac)))
        #expect(NSPredicate(fromMetadataQueryString: s) != nil)
    }

    @Test func regexesCantBeExpressed() {
        #expect(SpotlightQuery.string(for: SearchQuery(text: "/a+/", scope: .thisMac)) == nil)
    }
}

/// End-to-end searches over a temporary tree (not indexed by Spotlight, so these exercise the crawl).
@Suite struct SearchEngineTests {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("rf-search-\(UUID().uuidString)")
        let fm = FileManager.default
        for dir in ["a/b/c", "Photos.app/Contents", ".git/objects", "other"] {
            try fm.createDirectory(at: root.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        for path in ["a/report.pdf", "a/b/report final.txt", "a/b/c/deep report.md", "a/b/c/pic.heic", "a/notes.txt",
                     "Photos.app/Contents/report-inside-package.txt", ".git/objects/report.hidden", "other/.report-dot.txt",
                     "other/Report.PDF"] {
            fm.createFile(atPath: root.appendingPathComponent(path).path, contents: Data(repeating: 65, count: 10))
        }
    }

    private func results(_ text: String, scope: SearchScope? = nil) async -> [String] {
        var last = SearchStatus()
        for await status in SearchEngine.run(SearchQuery(text: text, scope: scope ?? .folder(root, recursive: true))) {
            last = status
            if !status.crawlRunning && !status.spotlightRunning { break }
        }
        return last.items.map { $0.url.path.replacingOccurrences(of: root.path + "/", with: "") }.sorted()
    }

    @Test func findsMatchesInSubfoldersButNotHiddenOrPackageContents() async {
        let found = await results("report")
        #expect(found == ["a/b/c/deep report.md", "a/b/report final.txt", "a/report.pdf", "other/Report.PDF"], "\(found)")
    }

    @Test func hiddenOnlyWhenAsked() async {
        let found = await results("report hidden:yes")
        #expect(found.contains(".git/objects/report.hidden"))
        #expect(found.contains("other/.report-dot.txt"))
    }

    @Test func kindFilter() async {
        #expect(await results("report kind:pdfs") == ["a/report.pdf", "other/Report.PDF"])
        #expect(await results("kind:images") == ["a/b/c/pic.heic"])
    }

    @Test func topLevelOnlyFiltersTheFolder() async {
        #expect(await results("report", scope: .folder(root.appendingPathComponent("a"), recursive: false)) == ["a/report.pdf"])
    }

    @Test func regexCrawls() async {
        #expect(await results(#"/^report\.(pdf|PDF)$/"#) == ["a/report.pdf", "other/Report.PDF"])
    }

    @Test func walkerSkipsUnreadableFolders() async throws {
        let locked = root.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: locked.appendingPathComponent("report-secret.txt").path, contents: nil)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        var last = SearchStatus()
        for await s in SearchEngine.run(SearchQuery(text: "report", scope: .folder(root, recursive: true))) {
            last = s
            if !s.isRunning { break }
        }
        #expect(last.foldersSkipped == 1)
        #expect(!last.items.contains { $0.name == "report-secret.txt" })
    }
}

/// Spotlight against the project folder, which lives in ~/Documents and is indexed.
@Suite(.disabled(if: ProcessInfo.processInfo.environment["RF_SPOTLIGHT_TESTS"] == nil))
struct SpotlightIntegrationTests {
    @Test func findsDesignDocViaSpotlight() async {
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var found: [String] = []
        for await s in SearchEngine.run(SearchQuery(text: "DESIGN.md", scope: .folder(project, recursive: true))) {
            found = s.items.map(\.name)
            if !s.crawlRunning && !s.spotlightRunning { break }
        }
        #expect(found.contains("DESIGN.md"))
    }
}
